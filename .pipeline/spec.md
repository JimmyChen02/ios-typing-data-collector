# Spec: Collect a real, trainable HandyTrak dataset (multi-frame capture)

## Goal

The advisor requires training on our OWN dataset. The current `HandCaptureView`
captures exactly ONE still per session via `UIImagePickerController` — far too
sparse to train a per-user CNN. This increment replaces the single-still capture
with a multi-frame burst so each (participant, holding-hand) condition yields
hundreds of labeled frames, and ships a written collection protocol plus the
exact training command.

**Scope guard (hard constraints):**
- The Python training logic and the manifest CSV schema MUST stay unchanged.
  The manifest already supports many rows per participant; the trainer already
  groups by participant and splits each condition by time order
  (`study_session_index`, then `captured_at_iso`, then `image_relative_path` —
  see `scripts/hand_dataset.py:198` and `scripts/train_hand_classifier.py:480`).
- Reuse `HandImageStore` (one JPEG per frame) and the existing `HandSample`
  `@Model` (one row per frame). Do NOT invent new storage or schema columns.
- No on-device inference. Capture only.
- Keep front camera, keep the self-report label, keep non-blocking / skippable.

---

## OPEN QUESTIONS (human decisions — defaults chosen, override if desired)

1. **Capture mechanism: AVFoundation burst vs. timer-driven UIImagePicker stills.**
   DEFAULT CHOSEN: **AVFoundation `AVCaptureSession` front-camera burst** at
   ~2 Hz. Rationale: paper-faithful (HandyTrak samples ~2 Hz), and
   `UIImagePickerController` cannot capture an automated multi-frame stream
   (it is one-tap-one-still and shows full-screen camera chrome). A custom
   `AVCaptureSession` + `AVCapturePhotoOutput` (or `AVCaptureVideoDataOutput`)
   is the only maintainable way to get an unattended timed burst. This spec
   uses `AVCaptureVideoDataOutput` with a frame-rate gate (simplest reliable
   2 Hz source; no per-frame shutter latency).

2. **Frames / seconds per condition.** DEFAULT CHOSEN: **20 seconds at 2 Hz =
   ~40 frames per condition.** Matches the synthetic demo's per-condition shape
   (`scripts/hand_dataset.py` demo = 20 frames/condition) and gives the
   sliding-window(30) + majority-vote evaluator enough frames for a real
   80/20 time split. Expose as a constant `framesPerCondition` /
   `captureSeconds` so it is one-line tunable.

3. **One guided 3-condition flow vs. one-condition-per-session.** DEFAULT
   CHOSEN: **one guided flow that captures left → right → both back-to-back**
   inside the single `HandCaptureView` sheet. Rationale: a participant must
   produce all 3 labels to train a 3-class HandyNet head, and re-running the
   whole typing study 3x just to vary the label is wasteful. The guided flow
   keeps the existing single-sheet presentation and writes the correct
   `holding_hand` per frame.

---

## Files

### 1. NEW: `TypingResearch/Services/HandBurstCapture.swift`

An `AVCaptureSession`-backed front-camera frame source. Owns the session,
delivers `UIImage` frames to a callback at a throttled ~2 Hz, never crashes on
permission/hardware failure (mirrors `HandImageStore`'s "return nil, don't
crash" discipline).

```swift
import AVFoundation
import UIKit

/// Front-camera burst frame source for holding-hand data collection.
/// Delivers ~`targetFPS` UIImage frames on the main queue via `onFrame`.
/// Safe to construct on Simulator / when permission is denied — it simply
/// never emits frames and `start()` reports failure via `onUnavailable`.
@MainActor
final class HandBurstCapture: NSObject {
    /// Target sampling rate (HandyTrak ≈ 2 Hz).
    var targetFPS: Double = 2.0

    /// Called on the main actor for each captured frame.
    var onFrame: ((UIImage) -> Void)?

    /// Called on the main actor if the camera could not be configured
    /// (no permission, no front camera, simulator).
    var onUnavailable: (() -> Void)?

    /// Requests camera authorization if needed, configures a front-camera
    /// `AVCaptureSession` with an `AVCaptureVideoDataOutput`, and begins
    /// running. Idempotent. Calls `onUnavailable` and returns if setup fails.
    func start()

    /// Stops the session and releases the output delegate. Idempotent.
    func stop()
}
```

Implementation notes for the Coder:
- Use `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)`.
- Output: `AVCaptureVideoDataOutput`, `alwaysDiscardsLateVideoFrames = true`,
  delegate on a private serial `DispatchQueue`. Throttle to `targetFPS` by
  tracking last-emitted timestamp (`CMSampleBufferGetPresentationTimeStamp`)
  and dropping frames that arrive sooner than `1/targetFPS`.
- Convert `CMSampleBuffer` → `CVPixelBuffer` → `CIImage` → `CGImage` →
  `UIImage`. Apply `.upMirrored`/orientation so the saved JPEG is upright
  (front camera is mirrored). A square-ish or full frame is fine; the Python
  side resizes to 224×224, so do NOT crop here.
- Authorization: check `AVCaptureDevice.authorizationStatus(for: .video)`;
  if `.notDetermined`, call `requestAccess` and continue in the completion;
  if `.denied`/`.restricted`, call `onUnavailable`.
- Hop frame delivery to `@MainActor` (the class is `@MainActor`; the AV
  delegate fires on the serial queue, so wrap the `onFrame` call in
  `Task { @MainActor in ... }` or `DispatchQueue.main.async`).
- `stop()` must `session.stopRunning()` off the main thread (AVFoundation
  `stopRunning` can block) — dispatch to a background queue, but flip any
  published `isRunning` state back on main.

### 2. REWRITE: `TypingResearch/Views/HandCaptureView.swift`

Replace the single-still UIImagePicker flow with a guided 3-condition burst.
Keep the same init signature (callers in `SessionView.swift` are unchanged):

```swift
init(
    participant: Participant,
    sessionId: UUID?,
    studyId: UUID,
    studySessionIndex: Int,
    onComplete: @escaping ([HandSample]?) -> Void   // CHANGED: was (HandSample?)
)
```

> NOTE: `onComplete` now returns `[HandSample]?` (the full set of frames across
> all 3 conditions) instead of a single `HandSample?`. Skip still passes `nil`.
> See SessionView change below — the closure must be updated to match.

State machine inside the view (`@State private var phase`):

```
enum Phase { case intro, capturing(HoldingHand), reviewing, done }
```

Guided order: `intro → capturing(.left) → capturing(.right) → capturing(.both) → reviewing`.

Behavior:
- **intro**: explanatory text (reuse the existing copy) + a live camera
  preview is NOT required; a "Start Capture" button. Also keep a "Skip"
  button (→ `onComplete(nil)`).
- **capturing(hand)**: show which hand to hold ("Hold the phone with your
  **LEFT** hand"), a countdown of `captureSeconds` (default 20), and a frame
  counter ("collected N frames"). Drive `HandBurstCapture`:
  - On entry: set `holdingHand = hand`, `capture.onFrame = { saveFrame($0, hand) }`,
    `capture.start()`. Start a `captureSeconds` countdown (Timer or
    `Task.sleep`).
  - Each delivered frame → `saveFrame(image, hand)` (see below).
  - When countdown hits 0: `capture.stop()`, advance to the next hand, or to
    `reviewing` after `.both`.
  - `capture.onUnavailable` → set an `unavailable` flag; show "Camera
    unavailable — Skip" and allow `onComplete(nil)`. Do NOT crash, do NOT
    fall back to photo library (burst from library is meaningless).
- **reviewing**: summarize counts per condition
  ("Left: 38 · Right: 41 · Both: 39"), a "Save & Continue" button
  (→ `onComplete(collected)`) and a "Discard" button (→ `onComplete(nil)`).

`saveFrame` (one JPEG + one HandSample row PER FRAME — reuse existing store):

```swift
private func saveFrame(_ image: UIImage, _ hand: HoldingHand) {
    let id = UUID()
    var rel = ""; var w = 0; var h = 0
    if let r = HandImageStore.shared.saveImage(image, id: id) {
        rel = r.relativePath; w = r.pixelWidth; h = r.pixelHeight
    }
    let sample = HandSample(
        participantId: participant.id,
        sessionId: sessionId,
        studyId: studyId,
        studySessionIndex: frameIndex,   // SEE TIME-ORDER NOTE BELOW
        capturedAt: Date(),
        holdingHand: hand,
        imageRelativePath: rel,
        imagePixelWidth: w,
        imagePixelHeight: h,
        cameraPosition: "front",
        deviceModel: participant.deviceModel,
        systemVersion: participant.systemVersion,
        notes: ""
    )
    modelContext.insert(sample)
    collected.append(sample)
    frameIndex += 1
}
```

**TIME-ORDER NOTE (critical for trainability):** the Python trainer sorts each
condition's frames by `(study_session_index, captured_at_iso, image_relative_path)`
(`scripts/hand_dataset.py:198`). Within a burst, `capturedAt = Date()` already
increases monotonically per frame, so `captured_at_iso` alone gives correct
time order. To be robust against equal-millisecond timestamps, ALSO set
`studySessionIndex = frameIndex` — a per-frame monotonically increasing counter
(0,1,2,…) reset to 0 at the start of each condition. This guarantees a stable,
strictly-increasing primary sort key and a clean 80/20 time split. Do NOT use
the session's `completedStudySessions` here; the trainer treats
`study_session_index` purely as the within-condition frame order.

- Remove `CameraPicker` (UIImagePickerController), `usePhotoLibrary`,
  `showCameraPicker`, `capturedImage`, `openCamera()`, the old `save()`/`skip()`.
- Keep `@Environment(\.modelContext)` and the same stored `let` properties.

### 3. EDIT: `TypingResearch/Views/SessionView.swift`

In `BetweenSessionView.body`, the `.sheet(isPresented: $showHandCapture)`
closure (lines ~624–639) currently does:

```swift
HandCaptureView(...) { sample in
    if let sample {
        sessionManager.recordHandSample(sample)
    }
    showHandCapture = false
    sessionManager.continueToNextSession()
}
```

Change the trailing closure to accept the array:

```swift
HandCaptureView(...) { samples in
    if let samples {
        for sample in samples {
            sessionManager.recordHandSample(sample)
        }
    }
    showHandCapture = false
    sessionManager.continueToNextSession()
}
```

No other change in this file. `SummaryView.exportHandData()` (line ~536)
already iterates `sessionManager.pendingHandSamples` and ships the manifest +
`HandImageStore.shared.allImageURLs()` — it works unchanged with many rows.

### 4. NO CHANGE: `SessionManager.swift`

`recordHandSample(_:)` (line 392) appends to `pendingHandSamples`. Calling it
in a loop is correct. `reset()` / new-participant path already clears
`pendingHandSamples` and `HandImageStore.shared.deleteAll()` is already wired in
`SummaryView` (line 91). Nothing to change.

### 5. NO CHANGE: Python pipeline

`scripts/train_hand_classifier.py`, `scripts/hand_dataset.py`,
`scripts/DataExporter` manifest (14-col schema) all consume the multi-row
manifest as-is. Confirmed: schema columns and sort contract already match.

### 6. NEW: `docs/HAND_DATA_COLLECTION.md` (collection protocol)

A short researcher-facing guide. Content to include:

- **Conditions:** capture all three holding-hand conditions per participant —
  `left`, `right`, `both` — in that guided order.
- **Duration / frames:** ~20 s per condition at ~2 Hz ≈ ~40 frames/condition,
  ≈120 frames/participant. Tunable via `captureSeconds` in `HandCaptureView`.
- **Participants:** collect at least 1 participant to train a per-user model
  (the pipeline trains per user); for a defensible result, aim for ≥3–5
  participants. Each participant = one run of the typing study to the
  between-session screen, then the guided 3-condition capture.
- **Lighting / pose (HandyTrak notes):** even, front-facing light; plain
  background helps the FCN-ResNet101 person segmentation; hold the phone at a
  natural typing distance/height; keep the upper body in frame; vary nothing
  mid-condition (one hand the whole 20 s).
- **Export:** on the Summary screen tap "Hand Manifest CSV + Images"; AirDrop /
  share the CSV plus the `hand_images/` JPEGs to the Mac. Put the CSV next to a
  folder containing `hand_images/`.
- **Train (exact command):**

  ```bash
  .venv-ml/bin/python scripts/train_hand_classifier.py \
      <manifest.csv> --images-root <dir-containing-hand_images> \
      --out models/ --mode both
  ```

  where `<dir-containing-hand_images>` is the parent folder so that
  `hand_images/<uuid>.jpg` resolves (paths in the manifest are relative to
  `--images-root`).
- **Read results:** the run prints a `[PAPER-FAITHFUL]` banner and a per-user
  table, then writes `models/summary.json`. Each row has
  `participant`, `n_train`, `n_eval`, `handynet_frame_acc`,
  `handynet_windowed_acc`, `centroid_frame_acc`. The
  `handynet_windowed_acc` (sliding-window-30 + majority vote) is the headline
  HandyTrak metric; `centroid_*` is the zero-training sanity baseline.

---

## Edge cases the implementation MUST handle

1. **Permission denied / Simulator / no front camera** → `HandBurstCapture`
   calls `onUnavailable`; the view shows a Skip path and calls
   `onComplete(nil)`. No crash, no UIImagePicker fallback.
2. **`saveImage` returns nil** (JPEG/disk failure) → still insert a label-only
   `HandSample` (empty `imageRelativePath`), exactly as the current `save()`
   does. Frame counter still advances.
3. **User backgrounds the app / dismisses the sheet mid-burst** → `stop()` the
   session in `onDisappear`; whatever frames were already saved remain valid
   (each is an independent row + JPEG). If dismissed before `reviewing`, treat
   as Skip (`onComplete(nil)`) so partial buggy data isn't silently kept —
   OR keep collected frames; DEFAULT: keep nothing on early sheet-dismiss to
   avoid lopsided per-condition counts. Always `stop()` the capture.
4. **Frame throttle** must hold ~2 Hz even if the camera delivers 30 fps; drop
   excess frames by timestamp, do not save 30/s (would blow up disk + skew the
   time split).
5. **Orientation/mirroring** — saved JPEGs must be upright and non-mirrored so
   the silhouette left/right is consistent across frames (the centroid baseline
   depends on horizontal position).
6. **`studySessionIndex` resets to 0 at the start of each condition** so each
   (participant, label) block is independently time-ordered 0..N — matches the
   demo manifest layout the trainer expects.

## Permissions

- `NSCameraUsageDescription` is already in `project.pbxproj` (lines 379, 410)
  as `INFOPLIST_KEY_NSCameraUsageDescription`. AVFoundation front-camera
  capture uses the SAME key — **no new Info.plist/pbxproj key is required.**
- `NSPhotoLibraryUsageDescription` (lines 381, 412) is now unused by this flow
  but harmless; leave it (the build setting can stay).
- `AVCaptureVideoDataOutput` does NOT require microphone permission (no audio).
