# Review — IMU sequence modeling + labeled posture capture + live inference

## VERDICT: APPROVE WITH NITS

The branch implements all three deliverables and honors all four RESOLVED
decisions. The critical research-integrity invariant — the existing keystroke
study is untouched — holds: every new behavior is gated on
`isPostureTrainingRun` (default `false`), keystroke logging / timers / event
flow in `TrialView` are additive-only, and no keystroke/cleaning/Gaussian code
was modified. The `@MainActor` change to `SessionManager` is the one non-trivial
blast-radius item; I verified it is safe (see below). No blocking correctness or
data-integrity issues found. The nits below are follow-ups, not merge gates.

---

## Spec compliance per deliverable

### D1 — IMU sequence model (Python): COMPLETE
- `scripts/imu_sequence.py` implements all four required interfaces
  (`load_imu_series`, `window_for_timestamp`, `imu_sequence_feature`,
  `build_sequence_dataset`, `train_imu_sequence_model`) with the 3-tier
  keras/sklearn/numpy fallback ladder and `._hand_classes` attachment.
- Record ordering is preserved end-to-end:
  `build_sequence_dataset` builds `X = np.zeros((n, window, 12))` indexed by the
  original record position `i` (imu_sequence.py:300), so `train_hand_classifier`
  reusing `records[i]["label"]`/`["sort_key"]` against `X[abs_train]` is correct.
  This is the load-bearing assumption behind reusing the existing split/eval code
  and it holds.
- `--imu-seq` / `--imu-window` / `--imu-causal` added; `--imu-seq` wins over
  `--use-imu` with a warning (train_hand_classifier.py:871); `--mode` forced to
  `handynet` with a printed note (:932-940); all-zero-IMU participant flagged,
  not crashed (:954-957). `hand_dataset.py` adds `captured_at_iso` /
  `study_session_index` as explicit keys, backward compatible (no keys removed).
- session_start proxy = MIN `captured_at_iso` per IMU group, documented as an
  approximation exactly as the spec's edge-case section requires.

### D2 — iOS labeled capture + live preview: COMPLETE
- D2a `PostureSelectView.swift`, D2b `PostureCaptureController.swift` +
  `SessionManager` hooks, D2c `CameraPreviewOverlay.swift` all present and wired.
- `PostureCaptureController.saveFrame` is a faithful port of
  `HandCaptureView.saveFrame`: label-only `HandSample` on disk-write failure,
  `notes = "posture_training_run"`, `studySessionIndex` = per-frame counter, and
  `imuRelativePath = imu/<sessionId>.uuidString.csv` — byte-identical to both
  `MotionRecorder`'s actual CSV filename (MotionRecorder.swift:147) and
  `HandCaptureView`'s convention (HandCaptureView.swift:479). Verified match.
- Single `AVCaptureSession`: D2c reuses `latestPostureFrame` off the one
  `HandBurstCapture`; no second camera session. Overlay is a `.overlay {}` layer,
  not a `.sheet`, so it cannot steal keyboard focus or pause the timer.
- Early-dismiss-keeps-frames difference from `HandCaptureView` is implemented and
  documented in both `stopPostureCapture()` and `TrialView.onDisappear`.
- Posture-run frames flow to export: `exportHandData` in `SessionView.swift:547`
  reads `sessionManager.pendingHandSamples` (which posture frames are appended
  to) on the main actor before detaching. Confirmed reachable.

### D3 — Core ML export + live inference: COMPLETE (infra only, by design)
- `export_imu_coreml.py` lazy-imports coremltools, exits 1 with an install hint
  and no traceback when absent; emits `ClassifierConfig(class_labels=...)` and an
  `imu_window (1, window, 12)` input. Label contract is consistent: labels.json =
  `sorted(set(train_labels))` from the manifest `holding_hand` column, which are
  exactly the `HoldingHand` rawValues (`both`/`left`/`right`), and iOS decodes via
  `HoldingHand(rawValue: classLabel)` (PosturePredictor.swift:242). No mismatch.
- `PosturePredictor.swift` is a correct no-op when no `.mlmodelc`/`.mlpackage` is
  bundled (`isModelAvailable` stays false, prediction stays `.unknown`). z-norm
  mirrors `imu_sequence_feature`; causal-trailing pad-by-replicate mirrors
  `window_for_timestamp`. Uses `MotionRecorder.shared.onFrame` (single motion
  manager) and clears it on `stop()`.
- `requirements-ml.txt` + `docs/POSTURE_DEMO.md` added per spec.

---

## Concurrency review (the @MainActor SessionManager change)

Verified safe. The only background-context callers of `SessionManager` are the
`Task.detached` blocks in `SessionView.swift` (:516, :551, :575); each reads
`sessionManager` properties *before* the detached closure and only re-enters via
`await MainActor.run` for UI state — none call back into `sessionManager` from
the background. So the isolation change does not introduce a data race or a
"call to main-actor-isolated in nonisolated context" at any existing site.
`nonisolated` on the pure static `keyRow`/`keyCol` lookups is correct.
`startTimer`'s `Task { @MainActor in }` wrapper and `PosturePredictor`'s
`MotionRecorder.onFrame` -> `Task { @MainActor in appendFrame }` hop are the
correct way to cross from the motion delegate queue / Timer closure onto the
actor. `let postureCapture = PostureCaptureController()` (a `@MainActor` type) is
initialized within `SessionManager`'s now-main-actor init — consistent.

---

## Nits / follow-ups (non-blocking)

1. `MotionRecorder.onFrame` is a single-slot callback. `PosturePredictor.start()`
   overwrites it and `stop()` nils it back. Today only `PosturePredictor` uses it
   so there is no collision, but this is a silent last-writer-wins design: if any
   future consumer also sets `onFrame`, one will be clobbered with no warning.
   Consider a small multicast/token API later. (PosturePredictor.swift:96-118,
   MotionRecorder.swift:37)

2. `PosturePredictor` is only start()/stop()'d from `CameraPreviewOverlay`'s
   appear/disappear. That means live inference only runs while the preview overlay
   is open. That is a defensible product choice (the tag only shows in the
   overlay), but if the intent is "the model predicts continuously during a
   posture run," it currently does not. Worth confirming with the advisor; flag
   only. (CameraPreviewOverlay.swift:100-108)

3. Deviation #2 (posture run reuses `startStudy(totalSessions: 1,
   design: .classicOnly)`) is reasonable, but it routes a posture run through the
   full study-completion path (SummaryView). Confirm on-device that a 1-session
   classicOnly run does not present the between-session `HandCaptureView`
   guided-capture flow (the changes note claims it skips straight to Summary —
   plausible from the code but unverified on hardware).

4. Pre-existing flaky tests (`test_extract_features_fallback_length`,
   `test_nearest_centroid_predict_and_score`) confirmed by the Tester to fail on
   the pre-change baseline and to be untouched by this branch. Not gating. Should
   be a separate cleanup ticket (pin a seed / fix the env-dependent 1024-d
   assumption).

---

## Recommended before/at merge

- None blocking. When a real device is available, exercise the Tester's
  end-to-end D2 checklist (setup -> Posture Training Run -> pick posture -> type
  -> open camera icon -> confirm frames + `<posture> (declared)` tag -> end
  session -> confirm Hand Data Zip contains the posture frames with
  `notes = "posture_training_run"`), then run the D3 export + bundle recipe to
  flip `isModelAvailable` and validate the live-tag path. These are the two paths
  that could not be tested in a Simulator-only environment and are the only
  meaningful residual risk.
- build_log.md was updated per CLAUDE.md. Commit rule (concise, per-deliverable,
  no Claude attribution) is a commit-time concern; nothing committed yet.
