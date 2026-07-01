# Test Results — IMU + Image Fusion for the Holding-Hand Classifier

## Scope

Focused on the Python changes per instructions (the testable, high-value
surface): `scripts/train_hand_classifier.py` (`_IMU_CHANNELS`,
`imu_summary_features`, `--use-imu` fusion, summary/markdown fusion flag) and
`scripts/hand_dataset.py` (`load_dataset_records` `imu_path`, demo IMU CSVs,
backward compatibility). The Swift side got a static diff review only (per
instructions — the Coder already verified `BUILD SUCCEEDED`); no xcodebuild
was re-run.

## Test framework

Repo already has `unittest.TestCase`-based tests in `tests/test_hand_pipeline.py`
(importable via both `python3 tests/test_hand_pipeline.py` and
`python3 -m pytest tests/test_hand_pipeline.py`). Matched that convention:
added new `TestCase` classes to the same file rather than creating a new
framework/file.

New test classes added to `tests/test_hand_pipeline.py`:
- `TestImuSummaryFeatures` — `imu_summary_features()` unit tests
- `TestUseImuFusion` — `--use-imu` concatenation / CLI banner / centroid-ignore / summary flag
- `TestHandDatasetImuColumn` — `load_dataset_records` `imu_path` resolution
- `TestExistingManifestsBackwardCompat` — regression against real
  `Model-Training-Test/` 14-column manifests

## Environment note

CLAUDE.md says "Run Python from the repo root using `venv/`", but this
checkout has no `venv/` directory — only `.venv-ml/` (a full ML environment
with torch + tensorflow/keras installed). Used `.venv-ml/bin/python3` for all
runs (confirmed it has numpy + Pillow; `python3 -m pytest` also resolved
correctly against it). Flagging this venv-name mismatch as a documentation
inconsistency, not a code defect.

Because `.venv-ml` has torch/tensorflow installed, `segment()` and
`extract_features()` take the **paper-faithful** path (FCN-ResNet101 /
VGG16), not the lightweight fallback (32×32 flatten, 1024-d) that two
*pre-existing* tests hardcode assumptions about. Verified via `git stash`
that both failures reproduce identically on the pre-change tree — they are
environment-dependent and unrelated to this change (see Pre-existing
failures below).

## Commands run

```sh
cd /Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector
.venv-ml/bin/python3 tests/test_hand_pipeline.py            # unittest runner, baseline + full suite
.venv-ml/bin/python3 -m unittest tests.test_hand_pipeline.TestImuSummaryFeatures \
    tests.test_hand_pipeline.TestHandDatasetImuColumn \
    tests.test_hand_pipeline.TestExistingManifestsBackwardCompat -v
.venv-ml/bin/python3 -m unittest tests.test_hand_pipeline.TestUseImuFusion -v
.venv-ml/bin/python3 -m pytest tests/test_hand_pipeline.py -q   # final full run
```

Also ran ad hoc verification against the real legacy manifests directly:
```sh
.venv-ml/bin/python3 -c "
import sys, warnings; sys.path.insert(0, 'scripts'); import hand_dataset as hd
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter('always')
    recs = hd.load_dataset_records('Model-Training-Test/hand_manifest_combined.csv', 'Model-Training-Test')
print(len(recs), all(r['imu_path'] is None for r in recs), [str(w.message) for w in caught if 'imu' in str(w.message).lower()])
"
# -> 1071 True []
```

## Result: 47 passed, 2 failed (pre-existing, unrelated to this change)

Final run: `Ran 49 tests ... FAILED (failures=2)` /
pytest: `2 failed, 47 passed, 7 warnings in 172.67s`.

### New tests (19) — all pass

**`TestImuSummaryFeatures`** (`imu_summary_features`, `_IMU_CHANNELS`, `_IMU_FEATURE_DIM`)
| Test | Covers | Result |
|---|---|---|
| `test_happy_path_layout_and_values` | 48-d layout = mean/std/min/max per of the 12 channels, in `_IMU_CHANNELS` order (`t_ms` excluded); exact values from 2 known rows | PASS |
| `test_channel_order_and_dim_constants` | `_IMU_CHANNELS` == the 12-channel MotionRecorder order, `t_ms` excluded; `_IMU_FEATURE_DIM == 48` | PASS |
| `test_single_frame_std_is_zero` | single-frame CSV → std=0 for every channel (population std, ddof=0, n=1) | PASS |
| `test_none_path_returns_zeros` | `imu_path=None` → `zeros(48)`, NaN-safe, no exception | PASS |
| `test_missing_file_returns_zeros` | nonexistent path → `zeros(48)`, warns, no exception | PASS |
| `test_header_only_csv_returns_zeros` | header-only CSV (0 data rows) → `zeros(48)` | PASS |
| `test_non_numeric_cells_skipped_not_fatal` | garbage cell value skipped per-cell, not fatal to the row/file; result all-finite | PASS |
| `test_missing_expected_column_zeros_that_channel` | CSV missing one expected column (`rot_z` dropped) → that channel's 4 stats are 0, others unaffected | PASS |

**`TestUseImuFusion`** (`--use-imu` concatenation, CLI banner, centroid-ignore, summary flag)
| Test | Covers | Result |
|---|---|---|
| `test_use_imu_concatenation_adds_exactly_48_dims` | `concatenate([img_feat, imu_feat])` grows feature dim by exactly 48 | PASS |
| `test_demo_train_hand_classifier_use_imu_flag_cli` | `--demo --use-imu` end-to-end via CLI; prints `IMU fusion: ON (48-d)` | PASS |
| `test_demo_train_hand_classifier_without_use_imu_flag_cli` | no `--use-imu` → prints `IMU fusion: OFF`, still runs end-to-end | PASS |
| `test_use_imu_with_centroid_mode_ignored_no_error` | `--use-imu --mode centroid` completes normally, IMU silently ignored, run reaches "Summary written to:" | PASS |
| `test_summary_rows_record_fusion_flag` | `summary.json` rows include `"imu_fusion": true` when `--use-imu` passed | PASS |

**`TestHandDatasetImuColumn`** (`load_dataset_records` `imu_path`)
| Test | Covers | Result |
|---|---|---|
| `test_imu_path_resolved_when_present_and_exists` | 15-column manifest + real IMU file on disk → `imu_path` resolved to the absolute path | PASS |
| `test_legacy_14_column_manifest_backward_compatible` | manifest with **no** `imu_relative_path` header at all → `imu_path=None` for every row, **zero** IMU warnings, row not skipped | PASS |
| `test_missing_imu_file_on_disk_not_skipped` | `imu_relative_path` column present, points at a file that doesn't exist → `imu_path=None`, row **not skipped** (image-only sample stays valid) | PASS |
| `test_mixed_manifest_some_rows_have_imu` | one row has IMU, one row has empty `imu_relative_path` → correct per-row `None`/resolved split | PASS |
| `test_demo_manifest_has_imu_column_and_files` | `_make_demo_manifest_and_images` emits a 15-column manifest, all 120 rows resolve `imu_path`, exactly 6 distinct IMU CSVs (2 participants × 3 conditions) | PASS |

**`TestExistingManifestsBackwardCompat`** (regression against real legacy data)
| Test | Manifest | Rows | Result |
|---|---|---|---|
| `test_hand_manifest_combined` | `Model-Training-Test/hand_manifest_combined.csv` | 1070 data rows loaded, all `imu_path=None`, 0 IMU warnings | PASS |
| `test_hand_manifest_tran` | `Model-Training-Test/hand_manifest_Tran_.csv` | loaded, all `imu_path=None`, 0 IMU warnings | PASS |
| `test_hand_manifest_jimmy_chen` | `Model-Training-Test/hand_manifest_Jimmy_Chen.csv` | loaded, all `imu_path=None`, 0 IMU warnings | PASS |

Each of these tests first asserts the manifest's real header line does **not**
already contain `imu_relative_path` (guards against the test's assumption
going stale if these files are ever regenerated with the new column).

### Pre-existing failures (2) — NOT caused by this change, not fixed

```
FAILED tests/test_hand_pipeline.py::TestTrainHandClassifier::test_extract_features_fallback_length
AssertionError: 25088 != 1024 : Expected 1024-d fallback; got 25088

FAILED tests/test_hand_pipeline.py::TestTrainHandClassifier::test_nearest_centroid_predict_and_score
AssertionError: 0.233.. (or 0.6, or 0.633, varies by run) not greater than 0.8 : Expected high train acc; got ...
```

Root cause: `.venv-ml` has torch + tensorflow/keras installed, so
`segment()`/`extract_features()` run the **paper-faithful** FCN-ResNet101 /
VGG16 path instead of the lightweight fallback (32×32 flatten → 1024-d)
these two tests were written against. `test_nearest_centroid_predict_and_score`
trains through the real Keras `train()` path (not the pure
`_train_nearest_centroid` used by the assertion's docstring) and its accuracy
varies run to run — also an artifact of the heavier path being exercised
in this environment, not a fusion-related regression.

Verified pre-existing via `git stash` (temporarily removing all pipeline
changes) and re-running the same two tests against the unmodified tree — both
failed identically before any of this change's code existed. Per instructions
("A failing test means the pipeline pauses for the Reviewer, not that you
patch around it"), these are reported, not fixed, but are called out
explicitly as pre-existing/environment-caused so the Reviewer can distinguish
them from a regression introduced by this change.

## Swift static sanity check (no xcodebuild re-run, per instructions)

Reviewed the diffs directly:
- `MotionRecorder.swift`: `isEnabled` flipped `false` → `true` (line 25); CSV
  header string (`t_ms,attitude_roll,...,rot_z`) and row-write format
  untouched — matches spec A1 exactly.
- `SessionManager.swift`: `MotionRecorder.shared.start(sessionId: session.id,
  studySessionIndex: completedStudySessions)` added immediately after
  `self.currentSession = session` in `startSession`; obsolete commented seam
  removed from `startStudy`; `let _ = MotionRecorder.shared.stop()` added in
  `finalizeSession` in the same place the comment used to be (after
  `BackendClient.shared.flush()`, before `modelContext?.save()`) — matches
  spec A2.
- `HandSample.swift`: `imuRelativePath: String` stored property + matching
  default-valued init parameter, assigned in the initializer body — matches
  spec A3 (additive, lightweight-migration-safe).
- `HandCaptureView.swift`: `imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? ""`
  added at the `HandSample(...)` call site — matches spec A3.
- `DataExporter.swift`: `"imu_relative_path"` inserted into the manifest
  header array immediately after `"image_relative_path"`, with
  `csvEscape(s.imuRelativePath)` inserted at the matching row index (header
  and row arrays stay index-aligned) — matches spec A4(a). `exportHandDataZip`
  copies `Documents/imu/*.csv` into `staging/imu/` guarded by
  `fm.fileExists(atPath:)`, unconditionally (all session CSVs, not just
  referenced ones) — matches spec A4(b), and the "Zip the staging directory"
  step comment was correctly renumbered 3 → 4.

No functional or behavioral issues found in the diffs; this is a read-only
review, not a build/run verification.

## Files touched by the Tester

- `/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/tests/test_hand_pipeline.py`
  (appended `TestImuSummaryFeatures`, `TestUseImuFusion`,
  `TestHandDatasetImuColumn`, `TestExistingManifestsBackwardCompat`, plus an
  `_IMU_HEADER`/`_write_imu_csv` fixture helper and a `subprocess` import)
- `/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/.pipeline/test-results.md`
  (this file)

No production code was modified.
