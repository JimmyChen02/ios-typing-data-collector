# Spec — IMU sequence modeling + labeled in-session hand-posture capture + live inference

Scope for one branch of work. Splits into three deliverables that can be built and
reviewed independently but share one data-collection change:

- **D1 (Python)** — IMU *sequence* model in `scripts/` (windowed prev+curr+future
  frames), extending the existing `--use-imu` fusion path in
  `train_hand_classifier.py` from 48-d summary stats to a temporal-window feature.
- **D2 (iOS)** — In-session labeled capture flow: user picks L / R / Both on one
  screen, then types on the next while photos + IMU are captured continuously and
  auto-labeled with the chosen posture. Plus a live camera-preview overlay with a
  predicted-posture "tag".
- **D3** — Core ML conversion path + a demo/video recipe.

The Coder reads only this file. Follow `CLAUDE.md`: iOS 17+, SwiftUI, `@Observable`
`SessionManager`, update `build_log.md` on every build, no Claude attribution in
commits, commit only when asked. Run Python from repo root via the ML venv
(`.venv-ml/`), never install into the anaconda base.

---

## RESOLVED QUESTIONS (user confirmed 2026-07-02 — these are final decisions)

1. **Live inference model format → (A) IMU-only Core ML model.** Convert the D1
   IMU sequence model (small 1D-CNN/GRU on a rolling 12-channel window) to Core ML.
   No camera needed for inference; the camera preview in D2c is display-only.
   Vision-based live inference (B) is deferred, not built on this branch.

2. **"Mid" == `both`.** Reuse the existing `HoldingHand.both` class. No new enum
   case, no manifest schema churn; existing trained models stay valid.

3. **Labeled-typing capture is a NEW opt-in sub-flow** ("Posture training run")
   reachable from the setup screen — NOT folded into the default timed study, so
   existing keystroke-study data integrity is untouched.

4. **Train/serve window asymmetry accepted.** Offline training/eval uses the
   centered window (prev+curr+future); the live on-device model uses a causal
   trailing window (prev+curr only).

---

## Assumptions (chosen defaults, not blocking)

- IMU is recorded at 50 Hz (`MotionRecorder`, `deviceMotionUpdateInterval = 1/50`).
  Photos at ~2 Hz (`HandBurstCapture.targetFPS = 2.0`). A "frame" for labeling is a
  photo; each photo is joined to the IMU window centered on its capture time.
- Sequence window default: **50 IMU samples (~1.0 s) centered on the photo timestamp**
  (25 before + 25 after). Tunable via CLI flag. Rationale: matches the "increase
  window size / prev+curr+future" note and the 50 Hz rate.
- One IMU CSV per session already exists at `Documents/imu/<sessionId>.csv` with the
  13-column header in `MotionRecorder.swift`. Reuse it; do not change the format.
- Class set stays `{left, right, both}` (drop `unknown` for training, as today).
- No new SwiftData migration is needed — `HandSample` already carries
  `imuRelativePath`, `holdingHand`, `capturedAt`, and per-frame `studySessionIndex`.

---

## D1 — IMU sequence model (Python)

### Files
- **Create** `scripts/imu_sequence.py` — new module: IMU window loading + feature
  builder + a small sequence classifier. Pattern to copy: the structure, lazy-import
  guards, `[PAPER-FAITHFUL]/[FALLBACK]` banner style, and docstring conventions of
  `scripts/train_hand_classifier.py`. Reuse `_IMU_CHANNELS` ordering exactly from
  that file (12 channels, no `t_ms`).
- **Modify** `scripts/train_hand_classifier.py` — add a new IMU-sequence code path
  alongside the existing 48-d `--use-imu` summary path. Do NOT delete
  `imu_summary_features`; add a sibling.
- **Modify** `scripts/hand_dataset.py` — `load_dataset_records` already returns
  `imu_path` and `sort_key` (which contains `captured_at_iso`). Add `captured_at_iso`
  and the per-frame `study_session_index` as explicit keys on each record dict so the
  sequence builder can locate a photo's timestamp inside its session IMU CSV without
  re-parsing `sort_key`. Keep backward compatibility (existing keys unchanged).
- **Modify** `Model-Training-Test/model.md` and `scripts/README_hand.md` — document
  the new flag and window semantics (append; do not rewrite existing sections). The
  auto-generated results block between `<!-- TRAIN_RESULTS_START -->` markers is
  written by `_write_markdown_results`; do not hand-edit inside it.

### Interfaces (`scripts/imu_sequence.py`)

```python
# Channel order — import/reuse from train_hand_classifier if practical, else mirror.
IMU_CHANNELS: list[str]   # == train_hand_classifier._IMU_CHANNELS (12 entries)

def load_imu_series(imu_path: str | None) -> "np.ndarray | None":
    """Read a MotionRecorder CSV → float32 array shape (T, 13):
    columns [t_ms] + the 12 channels in IMU_CHANNELS order.
    None / missing / unreadable / header-only → None (never raise).
    Warn-once per distinct failure reason, mirroring imu_summary_features."""

def window_for_timestamp(
    series: "np.ndarray",       # (T, 13) from load_imu_series
    center_t_ms: float,         # photo time offset within the session, ms
    window: int = 50,           # total samples in the window
    causal: bool = False,       # True → trailing (prev+curr); False → centered
) -> "np.ndarray":
    """Return a fixed (window, 12) float32 slice of the 12 channels centered
    (or trailing) on the sample nearest center_t_ms.
    Edge handling: pad by clamping/replicating the boundary sample so the shape
    is ALWAYS exactly (window, 12). Empty series → zeros((window, 12))."""

def imu_sequence_feature(
    series: "np.ndarray | None",
    center_t_ms: float,
    window: int = 50,
    causal: bool = False,
    flatten: bool = True,
) -> "np.ndarray":
    """Convenience: window_for_timestamp → per-channel z-normalized →
    flattened to (window*12,) when flatten else (window, 12).
    series None → zeros of the corresponding shape."""

def build_sequence_dataset(
    records: list[dict],        # from load_dataset_records (with new keys)
    window: int = 50,
    causal: bool = False,
) -> tuple["np.ndarray", list[str], list]:
    """Group records by session_id; load each session IMU series once; for each
    record compute center_t_ms = (captured_at - session_start) and build its
    window. Returns (X, labels, sort_keys) where X is (N, window, 12).
    Records whose IMU series is missing get an all-zero window (kept, warned)."""

def train_imu_sequence_model(
    X: "np.ndarray",            # (N, window, 12)
    labels: list[str],
    epochs: int = 10,
) -> object:
    """Small temporal classifier. Paper-faithful-analog priority:
      1. keras: Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->GlobalAvgPool->Dropout(0.5)
         ->Dense(n_classes, softmax). Adam, batch 32.
      2. sklearn LogisticRegression on FLATTENED X (fallback).
      3. numpy nearest-centroid on flattened X (guaranteed fallback).
    Attach ._hand_classes = sorted(unique labels), like train_hand_classifier."""
```

### `train_hand_classifier.py` changes
- Add CLI flags (in `_parse_args`), mirroring existing flag docstring style:
  - `--imu-seq` (store_true): use the sequence IMU model instead of image features.
    Mutually informative with `--use-imu`; if both passed, `--imu-seq` wins and a
    warning is printed.
  - `--imu-window` (int, default 50): window size in IMU samples.
  - `--imu-causal` (store_true): trailing window instead of centered.
- New branch in `main()`: when `--imu-seq`, skip the preprocess/segment/VGG stages
  entirely (they are the slow part). Build `X` via
  `imu_sequence.build_sequence_dataset(records, ...)`, then run the SAME
  per-participant grouping + time-ordered `split_train_eval_indices` +
  `windowed_accuracy` evaluation already in the file. Reuse
  `_predict_labels`, `_per_class_and_confusion`, `sliding_window_majority_vote`,
  `windowed_accuracy`, `_save_model`, and the summary/markdown writers unchanged.
  The window-size for the *sliding-window majority vote* stays `--window-size`
  (a different concept from `--imu-window`; keep both, document the distinction in a
  comment as this file already does for similar overlaps).
- `center_t_ms` derivation: the session IMU CSV `t_ms` is milliseconds since
  `MotionRecorder.start()` (i.e. session start). Each HandSample has `capturedAt`.
  `center_t_ms = (capturedAt - session_start).milliseconds`. **Edge case:** the
  manifest does not currently carry the session start time. Resolve by taking the
  session start as the MIN `captured_at_iso` among that session's frames as a proxy,
  and note the approximation in a comment. (If exactness is later required, add a
  `session_start_iso` column — do NOT add it now; flagged.)

### Edge cases D1 must handle
- Session with a photo but no IMU CSV, or header-only IMU → zeros window, keep row,
  warn once.
- Fewer IMU samples than `window` → pad by clamping to the boundary sample.
- Photo timestamp outside the IMU series time range → clamp `center_t_ms` into range.
- Participant/condition with `< 2` frames → existing `split_train_eval_indices`
  behavior (all to train, warn); do not special-case.
- All records for a participant have zero IMU → training still runs but flag it in a
  printed note (a zero-variance feature will give chance accuracy; do not crash).
- Non-numeric / short rows in the IMU CSV → skip per-cell/row like
  `imu_summary_features` does; never raise.

### D1 CLI examples (add to README_hand.md)
```sh
.venv-ml/bin/python scripts/train_hand_classifier.py \
    Model-Training-Test/hand_manifest_Jimmy_Chen.csv \
    --images-root Model-Training-Test/ \
    --out Model-Training-Test/models_imu/ \
    --imu-seq --imu-window 50 --epochs 10 \
    --md-out Model-Training-Test/model.md
# causal (serve-matched) variant:
#   ... --imu-seq --imu-causal
```
Because `_write_markdown_results` keeps only the single best run per `--md-out`,
use a DIFFERENT `--md-out` (or `--out`) for image-only vs. imu-seq runs to compare
both — same gotcha the file already documents.

---

## D2 — iOS labeled in-session capture + live preview

### D2a — Posture-select screen (the "first page: L, R, Mid")
- **Create** `TypingResearch/Views/PostureSelectView.swift` — a screen with three
  large buttons (Left / Right / Both). Pattern to copy: the button styling, ring
  colors (`ringColor(for:)` blue/green/orange), and Form/VStack layout in
  `HandCaptureView.swift`. On tap it stores the selected `HoldingHand` and advances.
  Reuse `HoldingHand` from `Models/HandSample.swift` (Both == "Mid", per OPEN Q2).
- Selection is written to `SessionManager` (new property below) so all frames
  captured during the following typing screen inherit that label.

### D2b — Continuous labeled capture during typing
- **Modify** `TypingResearch/ViewModels/SessionManager.swift`:
  - Add `var selectedPosture: HoldingHand = .unknown` (set by PostureSelectView).
  - Add `var isPostureTrainingRun: Bool = false` (gates the whole opt-in flow;
    default false so normal timed studies are unchanged — see OPEN Q3).
  - MotionRecorder already starts/stops in `startSession`/`finalizeSession`
    (lines 270, 616) — reuse; do NOT add a second IMU recorder.
  - Add a hook to start/stop a background `HandBurstCapture` for the typing screen
    when `isPostureTrainingRun`. Frames are saved via the SAME `saveFrame` logic as
    `HandCaptureView` (JPEG through `HandImageStore`, one `HandSample` per frame with
    `holdingHand = selectedPosture`, `imuRelativePath = imu/<sessionId>.csv`,
    `studySessionIndex = per-frame counter`). Append to `pendingHandSamples` and
    `modelContext.insert` exactly as `HandCaptureView.saveFrame` does.
- **Create** `TypingResearch/Services/PostureCaptureController.swift` (or fold into
  SessionManager if cleaner) — owns the `HandBurstCapture` instance + per-frame
  counter for the typing screen, so `TrialView` stays a thin view. Copy the
  onFrame/onUnavailable wiring and the `saveFrame` body from `HandCaptureView.swift`
  (lines 375-490); do not duplicate JPEG logic — call `HandImageStore.shared.saveImage`.
- **Modify** `TypingResearch/Views/TrialView.swift` — when
  `sessionManager.isPostureTrainingRun`, start the posture capture on appear and stop
  on disappear. **Do not touch keystroke logging** (`LoggingTextField`), timers, or
  event flow — capture runs strictly in the background so session data integrity is
  preserved (per the research-integrity requirement).

### D2c — Live camera-preview overlay with predicted-posture tag
- **Create** `TypingResearch/Views/CameraPreviewOverlay.swift` — a togg(button at
  the top of the typing screen, per the notes) that shows what the front camera sees
  plus a live label ("little tag") of the predicted posture. Requirements:
  - A small button pinned top of `TrialView` (e.g. `camera.viewfinder` SF Symbol).
    Tapping presents the overlay (sheet or overlay layer). Must NOT steal keyboard
    focus or pause the typing session/timer.
  - Live preview: reuse `HandBurstCapture` frames (display the latest `UIImage`), OR
    add an `AVCaptureVideoPreviewLayer` wrapped in a `UIViewRepresentable`. Prefer
    reusing the existing `HandBurstCapture.onFrame` UIImage stream to avoid a second
    camera session (two `AVCaptureSession`s on the same device may conflict). Display
    the most recent frame in an `Image`.
  - The tag shows `livePredictedPosture` (see D3). Until a Core ML model is wired,
    the tag shows the user-selected posture with a "(declared)" suffix so the UI is
    testable before the model exists. This staged behavior lets D2 land before D3.
- **Camera permission:** `HandBurstCapture` already handles authorization and
  Simulator/denied gracefully via `onUnavailable`; reuse it. Ensure
  `NSCameraUsageDescription` exists in the app's Info settings (check
  `project.pbxproj` / Info.plist; it must already be present because HandCaptureView
  uses the camera — verify, add only if missing).

### D2 edge cases
- Simulator / camera denied → `onUnavailable` fires; capture and preview degrade to
  no-frames without crashing; typing continues normally.
- Disk write failure in `saveImage` → label-only `HandSample` still saved (mirror
  existing `saveFrame` behavior, HandCaptureView lines 455-466).
- Overlay opened/closed repeatedly → `HandBurstCapture.start()/stop()` are idempotent;
  do not create multiple sessions. Reuse the single background capture.
- Early dismiss of the typing screen → stop capture on `onDisappear`; keep frames
  already saved (this is training data, unlike HandCaptureView's discard-on-dismiss).
  Document this intentional difference in a comment.
- `isPostureTrainingRun == false` → none of the above runs; zero behavioral change to
  the normal study (guard every new hook on this flag).

---

## D3 — Core ML live-inference model + demo (assumes OPEN Q1 = A)

### Files
- **Create** `scripts/export_imu_coreml.py` — converts the trained IMU sequence model
  (from D1, `--imu-causal` variant) to a `.mlmodel`/`.mlpackage`. Pattern: lazy import
  `coremltools` with a clear error if absent; take `--model` (the saved keras model),
  `--window`, `--out`. Emit class-label metadata (`._hand_classes`) into the Core ML
  model's classifier config. Input: `(window, 12)` float32; output: class label +
  softmax probabilities.
- **Add** `coremltools>=7.0` to `requirements-ml.txt` under a comment noting it is
  used only for the on-device export step (keep the numpy-2.x pin caveat that file
  already documents).
- **Create** `TypingResearch/Services/PosturePredictor.swift` — loads the bundled
  `.mlmodel`, buffers the last `window` IMU samples from a live 50 Hz stream, runs
  prediction on a timer (~2 Hz to match the tag cadence), and publishes
  `livePredictedPosture: HoldingHand` + confidence. Must be a no-op (returns
  `.unknown`) when the model resource is absent, so the app builds and runs before a
  model is shipped. `MotionRecorder` currently buffers to CSV and does not expose a
  live tap — add a lightweight live-callback hook to `MotionRecorder` (an optional
  `onFrame: ((MotionFrame-like values)) -> Void`) WITHOUT changing its CSV output or
  the 50 Hz cadence, or have `PosturePredictor` own its own `CMMotionManager` read.
  Prefer adding the callback to avoid two motion managers; guard it so it is nil in
  normal runs.
- **Wire** `PosturePredictor.livePredictedPosture` into the D2c tag, replacing the
  "(declared)" placeholder when a model is present.

### D3 feasibility note (put in export script docstring + README)
- The image pipeline (FCN-ResNet101 + VGG16) is NOT converted for live use — too
  heavy for interactive on-device inference. Core ML path covers the **IMU sequence
  model only** (small Conv1D/GRU). This realizes the advisor's goal that the deployed
  model no longer depends on the user declaring L/R/Both: at inference time the IMU
  model predicts posture from motion alone. The declared label is used ONLY as the
  training label during D2 capture.

### D3 — Demo / video recipe
- **Create** `docs/POSTURE_DEMO.md` — a short recipe: run a posture-training capture
  (D2), export the hand data zip, train the causal IMU sequence model (D1), export to
  Core ML (D3), reinstall, open the live camera overlay while typing in each posture,
  and screen-record the tag updating live. This is the "video/demo of the
  classification model working" deliverable. List exact commands.

---

## Non-goals (explicitly out of scope for this branch)
- A distinct "Mid/thumb" class separate from `both` (OPEN Q2).
- Converting the vision (FCN/VGG) pipeline to Core ML (OPEN Q1 option B).
- Cross-user generalization experiments / multi-participant retraining (data
  collection only; the "works on future users" goal is enabled by the IMU-only
  inference design, but validating it needs more participants — future work).
- Any change to keystroke logging, cleaning, or the Gaussian keyboard.
- SwiftData schema migration (none needed).

---

## Build / verification checklist for the Coder
- iOS: build with the documented `xcodebuild` command; update `build_log.md` with the
  result (required by CLAUDE.md).
- Python: `.venv-ml/bin/python scripts/train_hand_classifier.py --demo --imu-seq`
  must run end-to-end on the synthetic data (the demo manifest already writes
  per-condition IMU CSVs — see `_make_demo_manifest_and_images`). Add/adjust a demo
  path so `--imu-seq --demo` works without real data.
- Do not commit unless asked; when asked, one concise commit per deliverable (D1/D2/D3),
  no Claude attribution.
