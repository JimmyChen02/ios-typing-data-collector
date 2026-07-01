# Review: IMU + Image Fusion for the Holding-Hand Classifier

Reviewer: senior read-only review (no code edited, nothing committed).
Branch: `model`. Working tree only — NOT merged, left for human morning review.

## Overall verdict: APPROVE-WITH-NITS

The implementation is a faithful, disciplined execution of `.pipeline/spec.md`.
Every Part A (Swift) and Part B (Python) item was implemented exactly as the
resolved decisions specified, the join-key is correct, backward compatibility
holds, and the two red tests are confirmed pre-existing and environment-caused,
NOT a regression from this change. The nits below are non-blocking; one
(N1) is a genuine research-data-integrity risk Hyunchul should decide on
before large-scale collection, but it is inherited from the existing
`MotionRecorder` design, not introduced by this diff.

I independently re-verified, not just trusted the handoff:
- New IMU tests pass (`TestImuSummaryFeatures`, `TestHandDatasetImuColumn`).
- The 2 failing tests reproduce identically after `git stash` of all pipeline
  changes → confirmed pre-existing / env-caused (torch+tf installed forces the
  paper-faithful VGG16/FCN path; the 2 tests hardcode the 1024-d fallback).
- `imu_summary_features` layout/values/edge-cases exercised directly:
  header-only → zeros(48); values {1,3} → mean=2,std=1,min=1,max=3 per channel;
  concat grows image feature dim by exactly 48. All finite.
- Join-key traced across all files (see below) — consistent.

## Spec conformance: PASS (exact)

Part A:
- A1 `MotionRecorder.isEnabled` false→true; CSV header/row untouched. OK.
- A2 start seam in `startSession` after `self.currentSession = session`
  (SessionManager.swift:270), using real `session.id`; obsolete `startStudy`
  comment removed; stop seam in `finalizeSession` after `flush()` before
  `save()` (SessionManager.swift:616). OK.
- A3 `imuRelativePath` stored prop + default-`""` init param + body assign
  (HandSample.swift:48,64,80); set at call site
  (HandCaptureView.swift:479). OK.
- A4 manifest header + row index-aligned insert after `image_relative_path`
  (DataExporter.swift:128,143); `imu/` zip copy block guarded by
  `fileExists`, copies all session CSVs (DataExporter.swift:198-208);
  step comment renumbered 3→4. OK.
- A5 no pbxproj change (NSMotionUsageDescription already present). OK.

Part B:
- B1 docstring/schema updated; `imu_path` added to records with
  `(row.get(...) or "").strip()` + missing-file warn-once + never-skip
  (hand_dataset.py:211-231); demo writes 6 synthetic 13-col IMU CSVs with
  per-condition `attitude_roll` offset. OK.
- B2 `_IMU_CHANNELS`/`_IMU_FEATURE_DIM=48`; `imu_summary_features` (ddof=0,
  per-channel [mean,std,min,max], zeros on any failure, warn-once-per-reason);
  `--use-imu` flag; concat only when `use_imu` else byte-identical image path;
  banner; `imu_fusion` in summary rows; `_write_markdown_results(..., imu_fusion=)`
  caption; Future-work bullet removed. OK.
- B3 edge cases (14-col + --use-imu → all zeros; mixed; header-only;
  centroid ignores IMU) all handled and test-covered. OK.

## Join-key integrity: CORRECT
All three derive from the SAME `session.id`, all via `.uuidString`:
- IMU CSV filename: `MotionRecorder.writeCSV` → `imu/<sessionId.uuidString>.csv`
  (MotionRecorder.swift:130), sessionId passed as `session.id` (SessionManager.swift:270).
- Manifest `session_id`: `s.sessionId?.uuidString` (DataExporter.swift:138).
- Manifest `imu_relative_path`: `imu/<sessionId.uuidString>.csv`
  (HandCaptureView.swift:479), where `sessionId` = `sessionManager.currentSession?.id`
  (SessionView.swift:639).
So `imu_relative_path = imu/<session_id>.csv` resolves under the zip root. The
join Q2 specified is real and will produce joinable paired data.

## Prioritized findings

### N1 (MEDIUM — research-data-integrity; pre-existing design, decide before real collection)
IMU frames are buffered in memory and flushed to disk ONLY in
`MotionRecorder.stop()`, which is called only from `finalizeSession()`
(SessionManager.swift:616). `finalizeSession` runs on the normal session-end
paths (SessionManager.swift:322,327; TrialView.swift:184). If a session is
terminated abnormally BEFORE finalize — app killed/crashed, or suspended and
jetsammed while backgrounded — the entire session's IMU buffer is lost, even
though the hand IMAGES for that session were already written to disk at capture
time. Result: an image row whose `imu_relative_path` points at a CSV that never
got written. This is NOT silent corruption (the Python loader treats the missing
file as image-only with a one-time warn, per spec), and it is inherited from the
existing MotionRecorder design rather than introduced here — but flipping
`isEnabled = true` is what makes it collect real study data for the first time,
so it now matters. Recommend Hyunchul confirm sessions are always driven to
`finalizeSession` (no reliance on backgrounding to end a session), or consider a
periodic/interim flush, before bulk collection. Not blocking for morning review.

### N2 (LOW — research validity, already flagged by Tester)
The demo's synthetic IMU (uniform jitter + a constant per-class `attitude_roll`
offset, hand_dataset.py) is deliberately separable and does NOT reflect real
CoreMotion statistics. So "fusion demonstrably helps" in `--demo` is a
plumbing check, not evidence fusion helps on real data. The image+IMU vs
image-only comparison (Q5) must be re-run on a real exported manifest before
any claim about fusion benefit. Expected and acceptable; noting so it is not
mistaken for a result.

### N3 (LOW — non-finite IMU cells)
`imu_summary_features` accepts any string `float()` parses, including "nan"/"inf".
CoreMotion realistically never emits these, and the app writes fixed `%.6f`
formatting, so real CSVs cannot contain them. But if a hand-authored/corrupt CSV
ever did, a NaN/Inf channel stat would propagate into the fused vector and could
poison HandyNet training for that split. Non-blocking given the controlled
producer; a one-line `np.isfinite` filter on parsed values would fully close it
if desired.

### N4 (LOW — env/docs, already flagged by Tester)
CLAUDE.md says run Python via `venv/`, but only `.venv-ml/` exists in this
checkout. Doc inconsistency, not a code defect. Separately, because `.venv-ml`
has torch+tf, `TestTrainHandClassifier.test_extract_features_fallback_length`
and `test_nearest_centroid_predict_and_score` FAIL — CONFIRMED pre-existing via
`git stash` (both fail identically on the unmodified tree). Unrelated to this
change; do not attribute to fusion.

## Correctness / backward-compat / regressions
- Backward compat with 14-col manifests: verified — `row.get("imu_relative_path")`
  → None → `imu_path=None`, zero warnings, row not skipped (test + real
  `Model-Training-Test/*.csv` regression pass).
- `--use-imu` OFF path is byte-identical to prior image-only behavior
  (concat only inside `if args.use_imu`). No regression to existing results.
- `train`/`_train_handynet`/split/windowing signatures untouched; larger D flows
  through `n_features = features.shape[1]`. Confirmed nothing else hardcodes dim
  on the fusion path.
- `_write_markdown_results` keeps only the single best run — correctly documented
  in-code that image-only vs image+IMU must use different `--md-out`/`--out`.
  Good catch retained from spec; make sure whoever runs the comparison heeds it.

## Bottom line for morning review
Ship-ready as a data-collection + scaffolding change. Before REAL collection,
resolve N1 (guarantee finalizeSession runs, or add interim flush). Before
reporting any fusion RESULT, re-run Q5 on real device data (N2). N3/N4 optional.
