# Changes — Multi-frame HandyTrak burst capture

## Files created or modified

### NEW: `TypingResearch/Services/HandBurstCapture.swift`
AVFoundation front-camera burst controller. Owns an `AVCaptureSession` +
`AVCaptureVideoDataOutput`, throttles frames to `targetFPS` (default 2 Hz)
via CMTime comparison on the serial session queue, converts each kept buffer
to a `.upMirrored` `UIImage` (correct L/R orientation for centroid baseline),
and delivers frames to `onFrame` on the main actor. Requests/observes camera
authorization gracefully; calls `onUnavailable` on permission denied, no
front camera, or Simulator. `stop()` calls `session.stopRunning()` off the
main thread. `nonisolated(unsafe)` guards the timestamp ivar accessed only
from the serial session queue.

### REWRITE: `TypingResearch/Views/HandCaptureView.swift`
Replaced the single-still `UIImagePickerController` flow with a guided
3-condition burst (left → right → both). `captureSeconds = 60` and
`targetFPS = 2.0` are named top-level constants (one-line tunable). State
machine (`Phase` enum: intro / capturing(HoldingHand) / reviewing / done)
drives the flow. Each condition runs `HandBurstCapture` for 60 s, saving
one JPEG + one `HandSample` per frame via `HandImageStore.shared.saveImage`
and `modelContext.insert`. `studySessionIndex` is set to the per-frame
counter (0,1,2,…) reset per condition — critical for the Python trainer's
time-order sort. Camera unavailable shows a skip path; `onDisappear` calls
`stop()` and cancels the countdown task (no partial data kept on early
dismiss). `onComplete` signature changed from `(HandSample?) -> Void` to
`([HandSample]?) -> Void`.

### EDIT: `TypingResearch/Views/SessionView.swift`
Updated the `.sheet(isPresented: $showHandCapture)` trailing closure in
`BetweenSessionView` (~line 631) to match the new `([HandSample]?) -> Void`
signature: renamed `sample` to `samples`, replaced the single-sample check
with a `for sample in samples` loop calling `sessionManager.recordHandSample(sample)`
once per frame. No other changes in this file.

### NEW: `docs/HAND_DATA_COLLECTION.md`
Researcher-facing collection protocol: conditions (left/right/both),
60 s/condition at 2 Hz (~120 frames), participant count guidance,
lighting/pose/framing notes from HandyTrak, export steps from the app,
the exact `train_hand_classifier.py` command with parameter table, how to
read `summary.json`, and how `study_session_index` / `captured_at_iso`
encode time order for the trainer.

---

## Unchanged (confirmed)

- **Python pipeline** (`scripts/train_hand_classifier.py`,
  `scripts/hand_dataset.py`, `scripts/DataExporter`): not touched.
  Manifest schema (14-col CSV) unchanged.
- **Tests**: not touched.
- **`SessionManager.swift`**: not touched. `recordHandSample(_:)` called in
  a loop from `SessionView` — no change to the method itself.
- **`project.pbxproj` permissions**: `NSCameraUsageDescription` already
  present at lines 379 and 410 (`INFOPLIST_KEY_NSCameraUsageDescription`).
  AVFoundation reuses the same key — no new pbxproj entry required.
  `NSPhotoLibraryUsageDescription` left untouched (harmless).
- **`HandImageStore.swift`**, **`HandSample.swift`**: not touched.

---

## Tunable constants

| Constant | Value | File | Effect |
|----------|-------|------|--------|
| `captureSeconds` | `60` | `HandCaptureView.swift` line ~28 | Duration per condition (human override: 60 s) |
| `targetFPS` | `2.0` | `HandCaptureView.swift` line ~29 | Frames per second (~120 frames/condition) |

The `HandBurstCapture.targetFPS` property is set from this constant at
capture start; the throttle is implemented via CMTime comparison in the
delegate, so changing `targetFPS` here is the only tuning needed.

---

## Note: xcodebuild not run

This implementation was not compiled with `xcodebuild`. The Tester should
focus the static/code review on:

1. **`HandBurstCapture.swift`**
   - `nonisolated(unsafe) private var lastEmittedPTS` — valid Swift 5.10+
     syntax; confirm the project deployment target / toolchain supports it.
   - `AVCaptureDevice.requestAccess` is called without holding the main
     actor (it internally dispatches); the completion hops back via
     `Task { @MainActor in ... }` — confirm no threading warning from the
     compiler.
   - `connection.videoRotationAngle = 90` requires iOS 17+. If deployment
     target is earlier, wrap in `if #available(iOS 17, *) { ... }` or use
     the deprecated `videoOrientation = .portrait` path.
   - `CIContext(options: [.useSoftwareRenderer: false])` created per-frame
     is inefficient for high-fps but correct at 2 Hz. If performance is a
     concern, cache the context as a stored property (mark
     `nonisolated(unsafe)` or create on sessionQueue).

2. **`HandCaptureView.swift`**
   - `@State private var capture = HandBurstCapture()` — `HandBurstCapture`
     is `@MainActor`; confirm SwiftUI allows this as a `@State` initial
     value (it should, since views are also `@MainActor`).
   - `capture.onFrame = { [self] image in saveFrame(image, hand) }` captures
     `self` (the struct) by copy — confirm `saveFrame` reaches the correct
     `modelContext` and mutable state through `@State` projected values.
     If the compiler complains, promote to an explicit `@State` wrapper or
     pass context explicitly.
   - `onDisappear` fires on every phase transition (not just sheet dismiss).
     `capture.stop()` is idempotent, so repeated calls are safe.

3. **`SessionView.swift`** — minimal change; verify closure parameter
   rename compiled cleanly (`sample` → `samples`).

---

## Quick test commands

```bash
# Python demo (unchanged, confirms Python pipeline still works):
.venv-ml/bin/python scripts/train_hand_classifier.py --demo

# Static Swift review (no build environment required):
# Read HandBurstCapture.swift, HandCaptureView.swift, SessionView.swift
# and check the items listed above.
```
