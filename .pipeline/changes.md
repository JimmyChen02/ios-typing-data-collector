# Changes — IMU sequence modeling + labeled posture capture + live inference

Implements `.pipeline/spec.md` in full. All four "RESOLVED QUESTIONS" (IMU-only
Core ML, Mid == `both`, posture training run as a new opt-in sub-flow, centered
offline / causal live window) were treated as final and no new open questions
came up during implementation. Nothing was left unresolved; a small number of
implementation deviations were needed to get the iOS side to compile — see
"Deviations from spec text" below, all of which are mechanical/compiler-forced,
not scope changes.

---

## D1 — IMU sequence model (Python)

**`scripts/imu_sequence.py`** (new)
- `IMU_CHANNELS` — imported from `train_hand_classifier._IMU_CHANNELS` when
  possible, else a literal mirror (guards against import-order issues).
- `load_imu_series(imu_path)` — reads a MotionRecorder CSV into `(T, 13)`
  float32 (`t_ms` + 12 channels). Returns `None` (never raises) for missing
  path / missing file / unreadable / header-only, each warned once. Skips
  non-numeric rows/cells per-cell.
- `window_for_timestamp(series, center_t_ms, window, causal)` — returns a
  fixed `(window, 12)` slice, centered (prev+curr+future) by default or
  trailing (`causal=True`, prev+curr only). Out-of-range timestamps are
  clamped into the series range; out-of-range window indices are clamped to
  the boundary sample (never a ragged shape). Empty series → zeros.
- `imu_sequence_feature(...)` — `window_for_timestamp` + per-channel
  z-normalization within the window (zero-variance channel → all-zero, no
  division by zero) + optional flatten.
- `build_sequence_dataset(records, window, causal)` — groups records by
  `imu_path` (one CSV per session), computes each frame's
  `center_t_ms = captured_at - session_start_proxy` (session start
  approximated as the MIN `captured_at_iso` in that IMU-path group — the
  manifest has no `session_start_iso` column; this approximation is
  documented in the module docstring exactly as the spec's edge-case section
  requires, and intentionally NOT resolved by adding a new manifest column).
  Missing IMU → all-zero window, kept, warned once (not dropped).
- `train_imu_sequence_model(X, labels, epochs)` — Conv1D(32,5)→BN→ReLU→
  Conv1D(64,5)→GlobalAvgPool→Dropout(0.5)→Dense(softmax) via keras when
  available, else sklearn `LogisticRegression` on flattened X, else a
  pure-numpy nearest-centroid — same 3-tier fallback ladder as
  `train_hand_classifier.train()`. Attaches `._hand_classes`.

**`scripts/train_hand_classifier.py`** (modified)
- New flags: `--imu-seq`, `--imu-window` (default 50), `--imu-causal`.
  `--imu-seq` wins over `--use-imu` when both are passed (warned).
- New branch in `main()`: when `--imu-seq`, skips preprocess/segment/VGG
  entirely, builds `features_arr` via `imu_sequence.build_sequence_dataset`,
  forces `mode -> "handynet"` (centroid baseline is image-only, printed
  note if overridden), and flags any participant whose IMU is entirely
  zero (prints a note, does not crash — chance-level accuracy expected).
  The existing per-participant grouping, time-ordered
  `split_train_eval_indices`, `windowed_accuracy`, `_save_model`, and
  summary/markdown writers are reused completely unchanged — the
  IMU-sequence model just occupies the same `handynet_*` row slot as the
  image HandyNet model (`row["imu_seq"]` flag added for provenance).
  `_predict_labels` needed no changes: `imu_sequence`'s nearest-centroid and
  wrapped-sklearn classifiers both return arrays that fall through its
  existing type-dispatch logic correctly (verified by the demo runs below).
- New helper `_group_by_participant` for the all-zero-IMU sanity check.

**`scripts/hand_dataset.py`** (modified)
- `load_dataset_records` now also returns `captured_at_iso` (str) and
  `study_session_index` (int, parsed) as explicit top-level dict keys,
  kept in sync with the existing `sort_key` tuple. Fully backward
  compatible — no existing keys removed or renamed.

**Docs** — `Model-Training-Test/model.md` (new "IMU sequence model
(`--imu-seq`)" section, inserted before the `<!-- TRAIN_RESULTS_START -->`
auto-generated block, which was NOT hand-edited) and `scripts/README_hand.md`
(new section + updated "Future work") document the new flags, the
`--imu-window` vs `--window-size` distinction, and the causal-vs-centered
window semantics.

**Verified:**
```sh
.venv-ml/bin/python scripts/train_hand_classifier.py --demo --imu-seq
.venv-ml/bin/python scripts/train_hand_classifier.py --demo --imu-seq --imu-causal --epochs 3
.venv-ml/bin/python scripts/train_hand_classifier.py --demo --use-imu --mode centroid   # regression check, still passes
.venv-ml/bin/python scripts/hand_dataset.py --demo
```
All ran end-to-end to a printed summary table + `summary.json`, using
`.venv-ml/bin/python` (never the anaconda base / analysis `venv/`). Also
unit-checked `imu_sequence.window_for_timestamp` / `imu_sequence_feature` /
`load_imu_series` directly (centered/causal/edge-clamp/empty-series/
missing-file/header-only/non-numeric-row cases) via ad hoc scripts run
against `.venv-ml`; all matched the documented contract.

---

## D2 — iOS labeled in-session capture + live preview

**`TypingResearch/Views/PostureSelectView.swift`** (new) — D2a. Three large
buttons (Left / Right / Mid=`.both`), styled after `HandCaptureView`'s ring
colors (blue/green/orange) and Form layout. Calls `onSelect(HoldingHand)`.

**`TypingResearch/Services/PostureCaptureController.swift`** (new) — D2b.
`@MainActor @Observable` class owning a single `HandBurstCapture` + per-frame
counter for the typing screen. `start(...)` is idempotent; `saveFrame` is a
line-for-line port of `HandCaptureView.saveFrame` (JPEG via
`HandImageStore.shared.saveImage`, label-only `HandSample` on disk-write
failure, `holdingHand` set from the declared posture, `imuRelativePath =
imu/<sessionId>.csv`, `studySessionIndex` = per-frame counter). Also
publishes `latestFrame: UIImage?` for D2c's overlay (single capture stream,
no second `AVCaptureSession`).

**`TypingResearch/ViewModels/SessionManager.swift`** (modified) — added
`selectedPosture: HoldingHand = .unknown`, `isPostureTrainingRun: Bool =
false` (default off — normal studies unaffected), `startPostureCapture()` /
`stopPostureCapture()` (both guarded on `isPostureTrainingRun`,
`participant`, `modelContext`), `latestPostureFrame` computed passthrough,
and `reset()` now also stops posture capture and clears the two new flags.
`MotionRecorder` start/stop call sites were NOT touched — the spec's "reuse,
do NOT add a second IMU recorder" requirement.

**`TypingResearch/Views/TrialView.swift`** (modified) — `onAppear`/
`onDisappear` call `sessionManager.startPostureCapture()`/
`stopPostureCapture()`. Keystroke logging (`LoggingTextField` /
`handleKeyTap`), timers, and event flow are completely untouched — capture
is purely additive and backgrounded. Also adds the D2c toggle button +
overlay presentation (see below).

**`TypingResearch/Views/ParticipantSetupView.swift`** (modified) — new
"Posture Training Run" button + footer text below "Start Study", presenting
`PostureSelectView` as a `.sheet`. On selection, builds a `Participant`
exactly like `startStudy()` does, sets `selectedPosture`/
`isPostureTrainingRun = true`, then calls
`sessionManager.startStudy(participant:totalSessions: 1, design: .classicOnly)`
— a single classic-mode session (Gaussian switch-over is irrelevant to
labeled posture capture). This is a NEW, separate entry point; the existing
"Start Study" button/flow is byte-for-byte unchanged.

### D2c — live camera-preview overlay

**`TypingResearch/Views/CameraPreviewOverlay.swift`** (new) —
`PostureCameraToggleButton` (small `camera.viewfinder` SF Symbol button,
pinned top-trailing of `TrialView` via `.overlay(alignment: .top)`, only
shown when `isPostureTrainingRun`) + `CameraPreviewOverlay` (a plain overlay
layer, NOT a `.sheet`, so it cannot steal keyboard focus or interrupt the
session/timer — confirmed by inspection: it renders in `TrialView`'s own
`.overlay { }` modifier, stacked above the existing view tree, and its
Color scrim's `onTapGesture` only toggles a local `@State` binding). Shows
the most recent frame from `sessionManager.latestPostureFrame` (reusing
`PostureCaptureController`'s single capture stream — no second
`AVCaptureSession`). The tag shows `PosturePredictor.livePredictedPosture` +
confidence once `isModelAvailable` is true; until then it shows
`sessionManager.selectedPosture` with a `"(declared)"` suffix, exactly per
the staged D2-before-D3 requirement.

### D2 edge cases (verified in code, not on-device — see Deferred)
- Simulator / camera denied → `HandBurstCapture.onUnavailable` fires;
  `PostureCaptureController` stops itself and clears `latestFrame`; no crash,
  typing continues (this path is identical to `HandCaptureView`'s existing,
  already-shipped handling — reused, not reimplemented).
- Disk write failure in `saveImage` → label-only `HandSample` still saved
  (ported verbatim from `HandCaptureView.saveFrame`).
- Overlay opened/closed repeatedly → `PostureCaptureController.start()` is a
  no-op while already running (`guard capture == nil`); `stop()` is
  idempotent.
- Early dismiss of the typing screen → `onDisappear` stops capture; frames
  already saved/inserted into `modelContext` are kept (documented as an
  intentional difference from `HandCaptureView`'s discard-on-dismiss, in
  both `SessionManager.stopPostureCapture()` and `TrialView`).
- `isPostureTrainingRun == false` → every new hook (`startPostureCapture`,
  `stopPostureCapture`, the D2c button) is guarded on this flag; zero
  behavioral change to a normal study when it's false (the default).

---

## D3 — Core ML live-inference model + demo

**`scripts/export_imu_coreml.py`** (new) — lazy-imports `coremltools` with a
clean, non-crashing error + `exit(1)` when absent (verified — see below).
Loads a saved keras IMU-sequence model (`.keras`), reads `labels.json` for
class-label metadata, verifies/reconciles `--window` against the model's own
input shape, and converts to a Core ML classifier
(`ct.convert(..., convert_to="mlprogram")`) with `imu_window` input
`(1, window, 12)` and a `classLabel`/`classProbability` classifier output.
Docstring covers the D3 feasibility note verbatim (image pipeline NOT
converted — too heavy for on-device use; IMU-only realizes the "no declared
hand at inference time" goal).

**`requirements-ml.txt`** (modified) — added `coremltools>=7.0` under a
comment marking it export-step-only, same numpy-2.x caveat style as the
existing tensorflow entry.

**`TypingResearch/Services/PosturePredictor.swift`** (new) — `@MainActor
@Observable` singleton. Loads a bundled Core ML model by resource name
(`posture_imu`, tunable constant) via the generic `MLModel(contentsOf:)`
runtime API (no generated Swift class needed, so the app builds with zero
model shipped — `isModelAvailable` stays `false` and
`livePredictedPosture` stays `.unknown`, exactly per the spec's no-op
requirement). `start()` wires `MotionRecorder.shared.onFrame` to buffer a
rolling causal window (`windowSize = 50`, matching D1's default), z-normalizes
it identically to `imu_sequence.imu_sequence_feature`, and runs prediction on
a 0.5s (~2 Hz) timer, publishing `livePredictedPosture: HoldingHand` +
`confidence: Double`. `stop()` clears `MotionRecorder.shared.onFrame` back to
nil and resets published state to `.unknown`.

**`TypingResearch/Services/MotionRecorder.swift`** (modified) — added
`var onFrame: ((MotionFrame) -> Void)?` (nil by default, guarded), fired
alongside the existing `frames.append(...)` inside the same
`startDeviceMotionUpdates` closure. CSV output and the 50 Hz
`deviceMotionUpdateInterval` are byte-for-byte unchanged — confirmed by
diff review (only the frame-construction line was refactored from an inline
initializer into a local `let frame = ...` so it could be appended AND
passed to `onFrame`). Widened `MotionFrame` from `private struct` to
internal `struct` so `PosturePredictor` (a different file) can reference it.

**Wiring** — `CameraPreviewOverlay`'s tag view reads
`PosturePredictor.shared.isModelAvailable` / `livePredictedPosture` /
`confidence` directly, falling back to the "(declared)" placeholder when no
model is bundled, per spec.

**`docs/POSTURE_DEMO.md`** (new) — the demo/video recipe: run a posture
training capture (D2), export the hand data zip, train the causal IMU
sequence model (D1, exact `--imu-seq --imu-causal` command), export to Core
ML (D3, exact command), bundle `posture_imu.mlpackage` into the Xcode
target's Copy Bundle Resources, rebuild, then screen-record the live tag
while typing in each posture. Lists exact commands per the spec's "List
exact commands" requirement.

**Verified (no coremltools installed in `.venv-ml`, by design — spec did
not ask for it to be installed):**
```sh
.venv-ml/bin/python scripts/export_imu_coreml.py --model /tmp/nope.keras --out /tmp/out.mlpackage
# -> clean stderr message + `pip install 'coremltools>=7.0'` instructions, exit code 1, no traceback
```
The iOS side (`PosturePredictor`, `MotionRecorder.onFrame`) was verified by
a full `xcodebuild` (see below) — no `.mlpackage` was bundled, so the
build-and-run-before-a-model-is-shipped no-op path is exactly what was
compiled and is the state the app ships in right now.

---

## iOS project file changes

**`TypingResearch.xcodeproj/project.pbxproj`** (modified) — this project
does NOT use Xcode's file-system-synchronized groups, so the 4 new Swift
files were registered manually: `PostureSelectView.swift` and
`CameraPreviewOverlay.swift` added to the `Views` group;
`PostureCaptureController.swift` and `PosturePredictor.swift` added to the
`Services` group; all 4 added to the `PBXBuildFile`/`PBXFileReference`
sections and the `Sources` build phase. Validated with `plutil -lint`
(passed) and by a full `xcodebuild` (passed — see below).
`NSCameraUsageDescription` / `NSMotionUsageDescription` already existed in
the target's `Info.plist` build settings (verified, not modified — the spec
said "verify, add only if missing").

---

## Build verification

```sh
xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.3.1' build
xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.3.1' clean build
```
Both: **`** BUILD SUCCEEDED **`**, zero errors, zero new warnings (one
pre-existing, unrelated `appintentsmetadataprocessor` informational log line
is emitted regardless of this change). `build_log.md` has full entries for
both the iOS build (including the concurrency fix that was required — see
below) and the Python-side verification commands.

Note: `OS=18.3.1` had to be pinned explicitly — this machine has both iOS
18.3.1 and iOS 26.1 "iPhone 16" simulators installed, so the bare
`platform=iOS Simulator,name=iPhone 16` destination from CLAUDE.md is
ambiguous on this machine (same issue already logged in `build_log.md`'s
2026-07-01 entry, reproduced here for a different reason: `OS:latest` in the
literal CLAUDE.md command resolves to 26.1's iPhone 16 build for `xcodebuild`
in some environments but was rejected outright as "device not found" in
this shell — using the explicit `OS=18.3.1` qualifier is the reliable form).

---

## Deviations from spec text (all compiler-forced, not scope changes)

1. **`SessionManager` marked `@MainActor`.** The spec says
   "`PostureCaptureController` ... owns the `HandBurstCapture` instance", and
   `HandBurstCapture` is `@MainActor` (pre-existing). Storing a `@MainActor`
   `PostureCaptureController` as a property of the previously-unannotated
   `SessionManager` produced 5 compiler errors ("call to main actor-isolated
   ... in a synchronous nonisolated context"). Since `SessionManager` is
   `@Observable` and, by inspection, only ever driven from SwiftUI (main
   actor) call sites already, marking the whole class `@MainActor` was the
   most surgical fix (the alternative — making `PostureCaptureController`
   non-isolated — would have pushed manual thread-safety work onto its
   `HandBurstCapture` usage instead). This required two follow-on, purely
   mechanical fixes: `keyRow(for:)`/`keyCol(for:)` marked `nonisolated`
   (called from a free, non-isolated extension method — both are pure
   stateless lookups, so this is safe), and `startTimer()`'s
   `Timer.scheduledTimer` closure body wrapped in `Task { @MainActor in }`
   (the closure type is not statically `@MainActor` even though it fires on
   the main run loop in practice). All three are documented inline at the
   call sites and in `build_log.md`. No behavior changed — every existing
   caller of `SessionManager` was already on the main actor.
2. **Posture-training-run session uses `startStudy(..., totalSessions: 1,
   design: .classicOnly)`** rather than a bespoke single-session entry
   point — the spec did not specify exactly how the "next screen" typing
   session should be started, only that it should be "the next" screen
   after posture selection. Reusing the existing `startStudy` machinery
   (which already routes a 1-session `.classicOnly` study straight to
   `SummaryView` after the one session, skipping `BetweenSessionView`/
   `HandCaptureView` entirely) was the smallest-footprint way to get a
   normal typing screen with zero new state-machine code.

## Deferred / not done

- **On-device / physical-device testing.** No physical iPhone was available
  in this environment; `xcodebuild` targets the iOS Simulator only. The
  camera-permission-denied path, the live Core ML prediction loop, and the
  actual screen-recorded demo in `docs/POSTURE_DEMO.md` were verified by
  code inspection and by confirming the Simulator build compiles and the
  Python export script fails cleanly without `coremltools` — but not
  exercised end-to-end on hardware. This matches the Coder's available
  tooling (Simulator-only `xcodebuild`, no device attached) and is called
  out as the Tester's first thing to attempt on real hardware if one is
  available.
- **No `.mlpackage` was trained or bundled.** D3 ships the *infrastructure*
  (export script + `PosturePredictor` + `MotionRecorder` hook) per the
  spec's explicit "must be a no-op ... so the app builds and runs before a
  model is shipped" requirement — training a real model requires real
  posture-training-run data collected on a device first (chicken-and-egg,
  called out in the spec itself as the D2-before-D3 staging rationale).
- **`coremltools` was not installed into `.venv-ml`.** The spec listed it as
  a `requirements-ml.txt` addition (done) but did not ask for it to be
  installed on this branch; installing it was left to whoever runs the D3
  export step for real (per `docs/POSTURE_DEMO.md`).

---

## Tester focus

1. **iOS build** — `xcodebuild` as above; also worth opening in Xcode once
   to confirm the 4 new files show up correctly grouped (no red/missing
   file references) since the pbxproj was hand-edited.
2. **Concurrency change blast radius** — `SessionManager` is now
   `@MainActor`. Worth a careful look at anything that calls into
   `sessionManager` from a background task/closure that I might have missed
   (I checked `Task.detached` call sites in `SessionView.swift` and found
   none that call back into `sessionManager`, but a second pass would be
   good given how central this class is).
3. **D2 end-to-end on a real device**: setup screen → "Posture Training
   Run" → pick a posture → type for a bit → open the camera icon → confirm
   frames update and the tag reads `<posture> (declared)` → end session →
   confirm the "Hand Data Zip" export on the Summary screen includes the
   posture-training photos/IMU/manifest rows with `notes =
   "posture_training_run"`.
4. **D1 with real (not synthetic) IMU/photo data** once some posture-training
   runs exist on a device — the `--demo` paths are pipeline/CI-only and
   were the only thing testable in this environment.
5. **D3** once real data + a trained causal model exist: run
   `export_imu_coreml.py`, bundle the `.mlpackage`, confirm
   `PosturePredictor.isModelAvailable` flips to `true` and the tag replaces
   `(declared)` with a live prediction + confidence.
