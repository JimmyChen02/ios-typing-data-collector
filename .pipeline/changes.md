# Changes — IMU + Image Fusion for the Holding-Hand Classifier

Implements `.pipeline/spec.md` exactly. No open questions; all decisions were
pre-resolved in the spec's "Resolved decisions" section.

## Part A — iOS (Swift)

### `TypingResearch/Services/MotionRecorder.swift`
- Flipped `isEnabled` from `false` to `true` (line 26) — IMU collection is now
  ON by default for every session.
- Updated the file-header doc comment to reflect "ON by default" and that
  `SessionManager` now calls `start()`/`stop()` (previously said it did not).
- Did **not** touch the CSV header string (line 117-118) or per-row format
  (line 121) — still exactly
  `t_ms,attitude_roll,attitude_pitch,attitude_yaw,grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z`.
  This is the format the Python `imu_summary_features` extractor and the demo
  IMU CSV generator both depend on.

### `TypingResearch/ViewModels/SessionManager.swift`
- **Start seam**: in `startSession(...)`, immediately after
  `self.currentSession = session` is assigned, added
  `MotionRecorder.shared.start(sessionId: session.id, studySessionIndex: completedStudySessions)`.
  Using `session.id` (not a fresh `UUID()`) means the IMU CSV filename
  (`Documents/imu/<sessionId>.csv`) equals the `HandSample.sessionId` /
  manifest `session_id` value — this is the join key from spec Q2.
- Removed the now-obsolete commented-out seam
  `// MotionRecorder.shared.start(sessionId: UUID(), studySessionIndex: 0)`
  from `startStudy(...)` (it would have started recording before any
  `Session` existed, using a throwaway id that could never match a
  HandSample).
- **Stop seam**: in `finalizeSession()`, replaced the commented-out
  `// let _ = MotionRecorder.shared.stop()` with a real call, in the same
  location (after `BackendClient.shared.flush()`, before
  `try? modelContext?.save()`), so buffered motion frames flush to disk
  exactly once per session, at session end.
- No guard code added around either call — `MotionRecorder.start()`/`stop()`
  are already internally guarded by `isEnabled` and
  `manager.isDeviceMotionAvailable`.

### `TypingResearch/Models/HandSample.swift`
- Added a new stored property `var imuRelativePath: String` (relative to
  `Documents/`; `""` if no IMU CSV) directly after `imageRelativePath`.
- Added a matching init parameter `imuRelativePath: String = ""` (default,
  so existing call sites that omit it keep compiling) directly after the
  `imageRelativePath` init parameter, and assign it in the initializer body.
  This is an additive, lightweight-migration-safe change to the `@Model`.

### `TypingResearch/Views/HandCaptureView.swift`
- In `saveFrame(_:_:)`, where each `HandSample` is constructed, added:
  ```swift
  imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? "",
  ```
  right after `imageRelativePath: rel,`. This produces exactly the relative
  path that both `MotionRecorder`'s CSV filename and the zip export's `imu/`
  folder use. It is a path string only — no on-device file-existence check
  (per spec).

### `TypingResearch/Services/DataExporter.swift`
- `exportHandManifestCSV`: added `"imu_relative_path"` to the header array
  immediately after `"image_relative_path"` (new 15-column order); added the
  matching `csvEscape(s.imuRelativePath)` at the same index in the per-row
  array, so header and row stay index-aligned (mirrors the existing
  pattern used for every other column).
- `exportHandDataZip`: added a new step (renumbered the final "Zip the
  staging directory" comment from step 3 to step 4) that copies every file
  under `Documents/imu/*.csv` into a `imu/` subfolder of the zip staging
  directory, guarded by `fm.fileExists(atPath:)`. Copies *all* session CSVs
  unconditionally (not just referenced ones) per spec — harmless extras.
  Updated the doc comment listing the archive layout to include
  `imu/<sessionId>.csv`.

### `TypingResearch.xcodeproj/project.pbxproj`
- No change. `INFOPLIST_KEY_NSMotionUsageDescription` was already present
  for both build configurations (verified at lines 386 and 417).

### Build
```sh
xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16' build
```
The `name=iPhone 16` destination initially failed to resolve
(`Unable to find a device matching the provided destination specifier`) on
this machine — `OS:latest` picks iOS 26.1 but the installed "iPhone 16"
simulators are pinned to iOS 18.3.1, so xcodebuild couldn't match a device by
name alone. Re-ran with the explicit simulator id
(`platform=iOS Simulator,id=912C042A-EA3D-4108-B74E-A0A326452C65`, the same
physical "iPhone 16" simulator, OS 18.3.1). **Result: `** BUILD SUCCEEDED **`**,
no errors, no new warnings. Full entry appended to `build_log.md` at the repo
root (this file did not exist before; created per the mandatory
build_log.md convention in CLAUDE.md).

## Part B — Python

### `scripts/hand_dataset.py`
- Updated the module docstring's manifest schema block and the "14-column"
  wording to document the new optional 15th column `imu_relative_path`
  (backward compatible — external 14-column manifests still work unchanged).
- `load_dataset_records(...)`: added `imu_path` to each emitted record dict.
  Computed as `imu_rel = (row.get("imu_relative_path") or "").strip()`; empty
  → `None`; else resolved against `root`, and if the file does not exist on
  disk → `None` with a one-time `warnings.warn` (row is **not** skipped —
  image-only samples remain valid, per spec). Rows from a 14-column manifest
  have no `imu_relative_path` key, so `row.get(...)` returns `None` →
  `imu_path = None`, no crash. Verified with a standalone 14-column-manifest
  test (see Verification below).
- `load_dataset(...)` (image-only helper) is unchanged, as specified.
- `_make_demo_manifest_and_images(...)`: extended so the demo now exercises
  fusion end-to-end:
  - Added `"imu_relative_path"` to `fieldnames`, positioned after
    `"image_relative_path"` (matches the new manifest column order from A4).
  - Writes **one synthetic IMU CSV per (participant, condition) block**
    (2 participants × 3 conditions = 6 files) under `<tmp>/imu/<name>.csv`
    — e.g. `imu/alice_alpha_left.csv` — with the exact 13-column
    MotionRecorder header and 40 deterministic rows generated from the
    existing `rng = random.Random(42)`. Each block's `attitude_roll` channel
    is offset by a per-condition constant (`left: -1.0, right: +1.0,
    both: 0.0`) with small jitter, making the IMU signal class-separable so
    fusion demonstrably helps (per spec). Every manifest row belonging to
    that (participant, condition) block gets
    `imu_relative_path = imu/<name>.csv` (one CSV shared by all frames in the
    block, since the app also writes one IMU CSV per session, not per frame).
  - Existing image generation logic (rectangle position/color per condition)
    is untouched.

### `scripts/train_hand_classifier.py`
- Added module-level constants near the other tunables:
  `_IMU_CHANNELS` (the 12 channel names, `t_ms` excluded) and
  `_IMU_FEATURE_DIM = 48`.
- Added `imu_summary_features(imu_path: str | None) -> np.ndarray`, placed
  after the VGG16/fallback feature-extraction code (before the `train`
  pipeline stage), following the module's existing
  "never abort, warn-once-and-degrade" idiom:
  - `None` / non-existent file / unreadable / header-only (no data rows) →
    `np.zeros(48, dtype=np.float32)`, each distinct failure reason warned
    exactly once via a module-level `_warned_imu_reasons` set (so repeated
    per-frame calls during a training run don't spam the console).
  - Reads with `csv.DictReader`; missing expected column → that channel's 4
    stats are `0.0`; non-numeric cell → skipped per-cell (`try/except` inside
    the per-row loop); unexpected extra columns ignored (DictReader-based
    lookup only touches `_IMU_CHANNELS` keys).
  - Deterministic ordering: iterates `_IMU_CHANNELS` and emits
    `[mean, std, min, max]` per channel (population std, `ddof=0`).
- Added the `--use-imu` CLI flag (`store_true`) to `_parse_args()`, with the
  exact help text from the spec.
- `main()` feature-build loop: when `need_features` and `args.use_imu`, each
  frame now computes `img_feat = extract_features(sil)`, then
  `imu_feat = imu_summary_features(r.get("imu_path"))`, then
  `feat = np.concatenate([img_feat, imu_feat])` — appended to `feature_list`
  in place of the raw `img_feat`. When `--use-imu` is not passed, the loop is
  byte-for-byte identical to the prior image-only behavior (`feat = img_feat`,
  no concatenation call at all). `train()` / `_train_handynet()` /
  `_NearestCentroidClassifier` were **not** touched — they already derive
  `n_features = features.shape[1]` dynamically, so the larger fused
  dimension flows through with zero signature changes.
- Printed the fusion banner (`IMU fusion: ON (48-d)` / `IMU fusion: OFF`) in
  `main()` right after the paper-faithful/fallback banner, with an inline
  comment explaining that `_write_markdown_results` keeps only the single
  best run by windowed accuracy, so comparing an image-only vs. image+IMU
  run requires different `--md-out` (or `--out`) paths per run.
- `summary_rows`: each per-participant `row` dict now includes
  `"imu_fusion": bool(args.use_imu)`. `_write_markdown_results(...)` gained
  an `imu_fusion: bool = False` keyword parameter, passed through from
  `main()` as `imu_fusion=args.use_imu`; its generated caption now reads
  `(mode=..., epochs=..., imu=on/off)`. Table structure/columns were not
  otherwise changed, per spec ("minimal" instruction).
- Removed the now-implemented "IMU+image multimodal fusion" bullet from the
  trailing "Future work" print block; the other two bullets are unchanged.
- `--mode centroid` + `--use-imu`: no code path touches IMU in that mode
  (the fusion branch is nested inside `if need_features`, and
  `need_features = mode in ("handynet", "both")` is `False` for
  `mode == "centroid"`), so IMU is silently ignored there, no error —
  verified in Verification below.

## Verification performed
1. **iOS build** — `xcodebuild -scheme TypingResearch -destination
   'platform=iOS Simulator,id=912C042A-EA3D-4108-B74E-A0A326452C65'` (iPhone
   16 simulator, substituting an explicit id for the unresolvable
   `name=`-only destination on this machine) → `** BUILD SUCCEEDED **`.
   Entry appended to `build_log.md`.
2. `python3 scripts/hand_dataset.py --demo` (via `venv/`) → 120 samples
   loaded across left/right/both (40 each); confirmed the generated manifest
   has the new `imu_relative_path` column (15 columns total) and that six
   13-column IMU CSVs (`imu/<first>_<last>_<condition>.csv`, 41 lines each =
   header + 40 rows) were written under the demo tmp dir.
3. `python3 scripts/train_hand_classifier.py --demo` and
   `python3 scripts/train_hand_classifier.py --demo --use-imu` — both ran
   end-to-end without errors. Banner correctly printed `IMU fusion: OFF` and
   `IMU fusion: ON (48-d)` respectively (paper-faithful deps — torch/tf — are
   not installed in this venv, so both runs used the fallback
   32×32-flatten → nearest-centroid path, which is expected/pre-existing
   behavior, not something this change affects).
4. Standalone script: confirmed `extract_features` image-feature dim (1024,
   the 32×32 fallback flatten) plus `imu_summary_features` (48,) concatenate
   to exactly 1072 — i.e. fusion adds exactly 48 dims, matching Q3/Q4.
5. Edge cases directly exercised: `imu_summary_features(None)`,
   `imu_summary_features("/nonexistent/path.csv")`, and a header-only IMU
   CSV all returned all-zero 48-d vectors with a one-time warning each, no
   exceptions.
6. Backward compatibility: hand-built a legacy 14-column manifest (no
   `imu_relative_path` header) and confirmed `load_dataset_records` returns
   `imu_path: None` for its row with zero warnings and the row is not
   skipped.
7. `--use-imu --mode centroid` demo run completed normally (centroid
   baseline output unaffected, no IMU-related output/errors) confirming the
   "IMU ignored for centroid" edge case.
8. `--use-imu --md-out <path>` demo run: confirmed the generated markdown
   caption reads `imu=on`.

## What the Tester should focus on
- **Swift**: the two `MotionRecorder` seam call sites in
  `SessionManager.swift` (`startSession` / `finalizeSession`) — confirm a
  real device/simulator run produces `Documents/imu/<sessionId>.csv` with
  the session's actual `Session.id`, and that a session with zero motion
  frames still writes a header-only CSV without crashing the export/zip
  flow. Also confirm the manifest CSV and zip export both surface
  `imu_relative_path` correctly for HandSamples captured both inside and
  outside a session (`sessionId == nil` → `imuRelativePath == ""`).
- **Python**: `imu_summary_features` warning behavior under repeated calls
  in a real (non-demo) multi-hundred-frame training run — confirm warnings
  don't spam per-frame (they shouldn't, due to the one-time-per-reason
  guard). Also worth spot-checking a real exported manifest + real IMU CSVs
  from an actual device build once available, since the demo's synthetic
  IMU data is intentionally simplistic (uniform noise + constant per-class
  offset) and doesn't reflect real device-motion statistics.
- **sklearn LogisticRegression fallback warning** seen during local testing
  (`LogisticRegression.__init__() got an unexpected keyword argument
  'multi_class'`) is a pre-existing environment/version issue unrelated to
  this change — the code already has a designed fallback to nearest-centroid
  when this happens, and did so correctly in both the `--use-imu` and
  non-`--use-imu` demo runs.
