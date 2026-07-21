# 2026-07-21 — Merged Jimmy's 30fps re-capture; fixed merge_hand_export.sh for large exports

## What was attempted
User provided a new export, `hand_export_Jimmy V2_.zip`, intending to add a
3rd participant's data per the D1 process log's recommended next step.

## What was done
1. **Identified this was NOT a new participant.** The export's manifest
   showed `participant_first="Jimmy V2"`, but corroborating evidence made
   clear this was Jimmy re-capturing himself with the new 30fps app build
   built earlier this branch (never merged to main, still uncommitted in
   the working tree): 16,947 frames (~16x his original 1,041, matching the
   2fps→30fps capture-rate jump), 720×1280 resolution (exactly the
   `.hd1280x720` preset `HandBurstCapture` switches to above 10fps, vs. his
   original 1290×1720 `.photo`-preset capture), same device (iPhone 14 Pro
   Max), and multiple frames sharing one identical ISO timestamp — exactly
   the second-precision quantization pattern predicted for 30fps captures
   in `scripts/window_grid.py`'s design work. Confirmed with the user
   before proceeding.
2. Relabeled `participant_first` from "Jimmy V2" to "Jimmy" (matching the
   existing entries' exact format, empty last name) in a working copy —
   the original zip in ~/Downloads is untouched as the true raw record.
3. **Found and fixed two real bugs in `scripts/merge_hand_export.sh`**
   while merging (see commit `16ab5e3` for detail): `cp SRC/* DEST/`
   blows past ARG_MAX at this scale (broke at ~16,900 files — never hit by
   prior 2fps-era exports of 1,000-3,000 frames); and a relative-path
   re-run against an already-existing `exports/` provenance folder failed
   its string-match resume check and silently made a redundant full copy
   instead. Both fixed and verified against an isolated sandbox (never
   against real data) before landing.
4. **Caught and corrected a real data-integrity near-miss.** An initial,
   less careful smoke test of the ARG_MAX fix was run directly against the
   real repo instead of an isolated copy, merging 2,005 synthetic
   `Smoke,...` rows and empty placeholder images into the real
   `Model-Training-Test/hand_manifest_combined.csv` / `hand_images/`. Since
   this data is entirely `.gitignore`d (`hand_manifest*.csv`, `hand_images/`,
   `imu/`, `exports/` — no git safety net), this was caught immediately via
   manual row/file-count verification and reverted with a precise filter
   (`grep -v "^Smoke,"`) rather than a git checkout. Verified the resulting
   dataset matched the correct post-merge state exactly (row/image/imu
   counts) before proceeding. All further script testing used a fully
   isolated fake repo tree.

## Result
Combined dataset grew from 3,290 to **20,236 frames**:

| participant | before | after |
|---|---|---|
| Anonymous | 2,249 | 2,249 |
| Jimmy | 1,041 | **17,987** |
| **Total** | 3,290 | **20,236** |

Still only **2 real participants** — this does not unlock the pooling
question (still needs a genuinely different 3rd person) or, on its own,
give the fusion model cross-user data from a new individual. What it does
give: a much larger, denser Jimmy-only pool (17x), useful for (a) the LOUO
`held_out=anonymous|` split, where Jimmy's data is entirely the *training*
side — more of it directly gives the fusion model's image branch more
examples of grip *variation* even from one person, which is relevant
context for interpreting future LOUO-anonymous results; and (b) confirming
the 30fps capture pipeline works end-to-end on a real device for the first
time (resolution, timestamp pattern, frame density all matched prediction).

## Gotchas / lessons for future agents
- **`Model-Training-Test/hand_manifest_combined.csv`, `hand_images/`,
  `imu/`, and `exports/` are ALL gitignored.** There is no git-based undo
  for mistakes here — verify row/file counts before AND after any merge or
  test, and never run merge/test operations against the real repo path
  when a synthetic/smoke test would do; use an isolated fake repo tree
  instead (see commit `16ab5e3`'s test method for the pattern).
- Participant identity is asserted by whatever string was typed into the
  app's name field at capture time — it is NOT independently verified
  against anything. A researcher re-capturing themselves under a slightly
  different name (testing a new build, a typo, deliberate versioning) will
  silently look like a new participant to every script in this pipeline
  unless a human catches it. Worth eyeballing device model / resolution /
  frame density against existing participants before merging anything that
  claims to be "new."
- Disk usage: this merge alone added ~2.9GB (`hand_images/` growth) plus a
  ~2.9GB provenance copy under `exports/`. 30fps captures are ~15x denser
  than the 2fps era this pipeline was originally sized around — disk
  headroom that was fine before may not stay fine; this run pushed local
  disk to 97% before cleanup of an (unrelated, self-inflicted) duplicate
  provenance folder.

## Outcome
Real data merged correctly (verified row/image/imu counts match exactly).
`merge_hand_export.sh` is more robust for future large exports. Nothing
else in the pipeline (models, cache, code) was retrained or touched by this
entry — that's the natural next step once there's reason to.
