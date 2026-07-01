# Spec: IMU + Image Fusion for the Holding-Hand Classifier (app-collected data)

## OPEN QUESTIONS
None. All five prior questions were resolved by the human (see "Resolved decisions" below). Implement exactly as specified; do not invent extra features.

## Resolved decisions (authoritative)
- Q1: ENABLE iOS IMU collection now. All IMU + image data comes from the app's own collection. iOS work below is IN SCOPE.
- Q2 (join key): one IMU CSV per `session_id`; add an `imu_relative_path` column to the hand manifest.
- Q3 (feature representation): 48-d summary-stat vector = mean/std/min/max of the 12 IMU channels (roll, pitch, yaw, grav_x/y/z, acc_x/y/z, rot_x/y/z). Column `t_ms` is NOT a channel.
- Q4 (fusion): feature-level concatenation of the 48-d IMU vector onto the existing image feature vector, BEFORE the Dense softmax head. Reuse `train(features, labels, epochs)` with its existing `(N, D)` contract unchanged (fusion just makes D larger).
- Q5 (success metric): same held-out time-ordered 80/20 split, windowed (size-30) accuracy; report image-only vs image+IMU on the SAME split.

---

## Part A — iOS data-collection changes (Swift)

### A1. Flip MotionRecorder ON
File: `TypingResearch/Services/MotionRecorder.swift`, line 26.
- Change `var isEnabled: Bool = false` to `var isEnabled: Bool = true`.
- Do NOT change the CSV header (line 117-118) or the row format (line 121) — the Python side is hardcoded to that exact 13-column order (see A5). Header, in order:
  `t_ms,attitude_roll,attitude_pitch,attitude_yaw,grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z`
- CSV path is unchanged: `Documents/imu/<sessionId.uuidString>.csv`.

### A2. Wire the two SessionManager seams
File: `TypingResearch/ViewModels/SessionManager.swift`.

Seam 1 — start (currently line 291, commented):
```
// MotionRecorder.shared.start(sessionId: UUID(), studySessionIndex: 0)
```
Do NOT start recording in `startStudy` — at that point no `Session` exists yet, so its id is unknown and would not match the HandSample join key. Instead start recording inside `startSession(...)` right after `self.currentSession = session` is assigned (currently line 269). Add:
```swift
MotionRecorder.shared.start(sessionId: session.id, studySessionIndex: completedStudySessions)
```
Rationale: `HandSample.sessionId` is set to `sessionManager.currentSession?.id` (SessionView.swift line 639), and the IMU CSV is named `<sessionId>.csv`. Using `session.id` here makes the CSV filename equal the manifest `session_id` value — that IS the join. Remove the now-obsolete commented seam at line 291.

Seam 2 — stop (currently line 617-618, commented):
```
// let _ = MotionRecorder.shared.stop()
```
This sits inside `finalizeSession()`. Replace the comment with a real call so the buffered frames flush to disk when the session ends:
```swift
let _ = MotionRecorder.shared.stop()
```
Keep it in the same location (after `BackendClient.shared.flush()`, before `try? modelContext?.save()`).

Edge cases:
- `start()` / `stop()` are internally guarded by `isEnabled` and `isDeviceMotionAvailable`; no extra guards needed.
- If a session produces zero motion frames, `writeCSV` still writes a header-only CSV. That is acceptable; the Python loader treats an empty-body IMU CSV as "no IMU" (see A5 edge cases). Do not add special-casing in Swift.

### A3. Add `imuRelativePath` to the HandSample model
File: `TypingResearch/Models/HandSample.swift`.
- Add stored property after `imageRelativePath` (line 47):
  ```swift
  var imuRelativePath: String   // relative to Documents/; "" if no IMU CSV
  ```
- Add matching init parameter (default `""`) after the `imageRelativePath` parameter (line 62), and assign `self.imuRelativePath = imuRelativePath` in the body.
- Set the value where HandSample is constructed, `TypingResearch/Views/HandCaptureView.swift` around line 468-485. Add:
  ```swift
  imuRelativePath: sessionId.map { "imu/\($0.uuidString).csv" } ?? "",
  ```
  Place it in the initializer call (e.g. right after `imageRelativePath: rel,`). This yields the same relative path the zip layout uses (see A4). It is a path string only; do NOT check file existence on device.

  SwiftData note: adding a non-optional stored property with a default value to an existing `@Model` is a lightweight-migration-safe additive change. Give it a default in the init so existing call sites that omit it still compile.

### A4. Include IMU CSVs in the export + add manifest column
File: `TypingResearch/Services/DataExporter.swift`.

(a) Manifest header + rows — `exportHandManifestCSV` (lines 121-156).
- Add `"imu_relative_path"` to the header array. Insert it immediately AFTER `"image_relative_path"` (currently line 128), so header order becomes:
  `participant_first, participant_last, study_id, session_id, study_session_index, captured_at_iso, holding_hand, image_relative_path, imu_relative_path, image_pixel_width, image_pixel_height, camera_position, device_model, system_version, notes`
  (15 columns; was 14.)
- In the per-row array (lines 134-149), insert `csvEscape(s.imuRelativePath)` immediately after `csvEscape(s.imageRelativePath)` so column order matches the header exactly.

(b) Zip layout — `exportHandDataZip` (lines 165-198).
- After copying images into `hand_images/` (lines 189-194), copy every session IMU CSV into an `imu/` subfolder so `imu_relative_path` = `imu/<sessionId>.csv` resolves under the zip root (matching A3). Add:
  ```swift
  // IMU CSVs: Documents/imu/<sessionId>.csv → staging/imu/<sessionId>.csv
  let imuSrc = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("imu", isDirectory: true)
  if fm.fileExists(atPath: imuSrc.path) {
      let imuDest = staging.appendingPathComponent("imu", isDirectory: true)
      try? fm.createDirectory(at: imuDest, withIntermediateDirectories: true)
      if let files = try? fm.contentsOfDirectory(at: imuSrc, includingPropertiesForKeys: nil) {
          for f in files where f.pathExtension == "csv" {
              try? fm.copyItem(at: f, to: imuDest.appendingPathComponent(f.lastPathComponent))
          }
      }
  }
  ```
  Copy ALL session CSVs (do not try to filter to referenced sessions); extra CSVs are harmless.

### A5. Info.plist / permissions
`INFOPLIST_KEY_NSMotionUsageDescription` is ALREADY present in `TypingResearch.xcodeproj/project.pbxproj` (lines 386 and 417) for both build configs. No plist change required. Do not remove it.

### A6. Build + log requirement (per CLAUDE.md)
- Build after the Swift changes:
  ```sh
  xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16' build
  ```
- Append an entry to `build_log.md` describing the change, any errors, fixes, and the result (success/failure). This is mandatory on every build.

---

## Part B — Python fusion pipeline

Two files change. Keep both backward-compatible with existing 14-column manifests (no `imu_relative_path`).

### B1. `scripts/hand_dataset.py`
- Update the module docstring schema block (lines 8-15) and the "14-column" wording (line 29-33) to mention the optional 15th column `imu_relative_path`.
- In `load_dataset_records` (lines 129-207), add to each emitted record dict a new key:
  ```python
  "imu_path": <absolute path str or None>,
  ```
  Compute it as: `imu_rel = (row.get("imu_relative_path") or "").strip()`. If empty → `None`. Else `imu_abs = root / imu_rel`; if the file does not exist → `None` with a one-time `warnings.warn` (do NOT skip the row — image-only samples remain valid). Store `str(imu_abs)` when it exists.
- Backward compat: rows from a 14-col manifest have no `imu_relative_path` key → `row.get(...)` returns `None` → `imu_path = None`. No crash.
- `load_dataset` (lines 71-126) is unchanged (image-only helper).
- Extend `_make_demo_manifest_and_images` (lines 227-333) so the demo exercises fusion:
  - Add `"imu_relative_path"` to `fieldnames` (after `"image_relative_path"`), matching the new manifest column order in A4.
  - Write one synthetic IMU CSV per participant-condition block under `<tmp>/imu/<name>.csv` with the EXACT 13-column header from A1 and ~40 rows of deterministic values (use the existing `rng`). Make the values class-separable (e.g. offset one channel by condition) so fusion demonstrably helps. Set each row's `imu_relative_path` to `imu/<name>.csv`.
  - Keep the existing image generation intact.

### B2. `scripts/train_hand_classifier.py`

Add an IMU-feature extractor and a fusion switch. Do NOT change the `train`, `_train_handynet`, split, or windowing function signatures.

(a) New constant near line 132:
```python
# 12 IMU channels (excludes t_ms), 4 stats each → 48-d summary vector
_IMU_CHANNELS = [
    "attitude_roll", "attitude_pitch", "attitude_yaw",
    "grav_x", "grav_y", "grav_z",
    "acc_x", "acc_y", "acc_z",
    "rot_x", "rot_y", "rot_z",
]
_IMU_FEATURE_DIM = 48  # 12 channels × {mean, std, min, max}
```

(b) New function:
```python
def imu_summary_features(imu_path: "str | None") -> "np.ndarray":
    """Return a 48-d float32 vector: [mean,std,min,max] per IMU channel,
    channels in _IMU_CHANNELS order (stats grouped per channel:
    ch0_mean,ch0_std,ch0_min,ch0_max, ch1_mean,...).

    imu_path None, missing file, unreadable, or header-only (no data rows)
    → zeros(48). Warns once per distinct failure reason. Reads the CSV with
    csv.DictReader; ignores unexpected extra columns; missing expected column
    → that channel's 4 stats are 0. Non-numeric cells are skipped per-cell.
    """
```
Implementation notes: use `csv.DictReader`; collect per-channel float lists; `np.mean/std/min/max` (population std, `ddof=0`); empty channel → 4 zeros; return `np.zeros(48, dtype=np.float32)` on any total failure. Deterministic ordering: iterate `_IMU_CHANNELS` and emit `[mean, std, min, max]` for each.

(c) CLI flag in `_parse_args` (near line 1145):
```python
parser.add_argument(
    "--use-imu",
    action="store_true",
    help="Concatenate a 48-d IMU summary vector onto the image features "
         "before the softmax head (feature-level fusion). Requires "
         "imu_relative_path in the manifest.",
)
```

(d) `main()` feature build (lines 804-828). When `args.use_imu` and `need_features`:
- For each record `r`, compute `img_feat = extract_features(sil)` as today, then `imu_feat = imu_summary_features(r.get("imu_path"))`, then `feat = np.concatenate([img_feat, imu_feat])`. Append `feat`.
- When `--use-imu` is NOT passed, behavior is byte-for-byte the current image-only path (no concat). This is how Q5 "image-only vs image+IMU on the same split" is produced: run twice on the same manifest, once without and once with `--use-imu`.
- Because `train`/`_train_handynet` derive `n_features = features.shape[1]` (line 399), the larger fused D flows through with NO signature change. Confirm nothing else hardcodes the feature dimension.
- Print a one-line banner in `main()` after the paper-faithful/fallback banner: `IMU fusion: ON (48-d)` or `IMU fusion: OFF`.

(e) Summary/markdown labeling: add the fusion state to the run so results are self-describing. Minimal: include `"imu_fusion": bool(args.use_imu)` in each `summary_rows` dict, and pass it through so `_write_markdown_results` notes `(mode=..., epochs=..., imu=on/off)` in its generated caption. Do not otherwise restructure the summary table. NOTE: `_write_markdown_results` keeps only the single BEST run by windowed accuracy — an image+IMU run and an image-only run compete for the same block. To compare both, use DIFFERENT `--md-out` paths (or `--out` dirs) for the two runs; call this out in a code comment near the fusion banner.

(f) Update the trailing "Future work" print (lines 1021-1024): remove the now-implemented "IMU+image multimodal fusion" bullet.

### B3. Edge cases the Python side MUST handle
- 14-column manifest (no IMU column) + `--use-imu`: every `imu_path` is None → every IMU vector is zeros(48). Fusion still runs (D grows by 48 zeros); warn once that no IMU data was found. Do not crash.
- Mixed manifest: some rows have IMU, some don't → per-row zeros for the missing ones.
- IMU CSV present but header-only (empty session): zeros(48).
- `--use-imu` with `--mode centroid`: centroid path uses silhouettes, not features; IMU is ignored for centroid (only affects the HandyNet feature path). No error.
- Fusion changes feature length only; the time-ordered split (`split_train_eval_indices`), windowing (`sliding_window_majority_vote`, `windowed_accuracy`), and per-class/confusion code are untouched.

---

## Patterns to copy / follow
- Swift CSV column add: mirror the exact header/row parallelism already in `exportHandManifestCSV` (DataExporter.swift lines 125-151) — header array and row array must stay index-aligned.
- Swift file copy into zip staging: copy the existing `hand_images/` block in `exportHandDataZip` (DataExporter.swift lines 189-194) for the new `imu/` block.
- Python optional-column read: follow the defensive `(row.get("...") or "").strip()` + missing-file-warn-and-continue idiom already in `load_dataset_records` (hand_dataset.py lines 157-198).
- Python fallback discipline: follow the existing "never abort, warn and degrade" pattern (return zeros rather than raise) used throughout `train_hand_classifier.py`.

## Files touched (summary)
Create: none.
Modify:
- `TypingResearch/Services/MotionRecorder.swift` (line 26)
- `TypingResearch/ViewModels/SessionManager.swift` (~line 269 start seam; ~line 617 stop seam; remove line 291 comment)
- `TypingResearch/Models/HandSample.swift` (add `imuRelativePath`)
- `TypingResearch/Views/HandCaptureView.swift` (~line 468 init call)
- `TypingResearch/Services/DataExporter.swift` (`exportHandManifestCSV` header+row; `exportHandDataZip` imu copy)
- `scripts/hand_dataset.py` (`load_dataset_records`, `_make_demo_manifest_and_images`, docstring)
- `scripts/train_hand_classifier.py` (IMU constants, `imu_summary_features`, `--use-imu`, `main` feature build, summary/markdown label, future-work print)
- `build_log.md` (mandatory build entry)

## Verification (Coder should run)
1. `xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16' build` → update `build_log.md`.
2. `python3 scripts/hand_dataset.py --demo` (from repo root, using `venv/`) → confirms demo manifest now has `imu_relative_path` and IMU CSVs are written.
3. `python3 scripts/train_hand_classifier.py --demo --use-imu` and again without `--use-imu` → both run end-to-end; fusion banner reflects the flag; feature dim differs by 48.
