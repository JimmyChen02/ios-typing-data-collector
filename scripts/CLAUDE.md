# scripts/ — Offline Analysis Pipeline

Python (run from repo root, using the project `venv/`). Operates on keystroke CSVs
exported by the iOS app. Mirrors the in-app cleaning/Gaussian logic so results match.

## Typical flow
1. `clean_keystrokes.py <raw.csv> [out.csv] [-t KW] [-s SD]`
   Adds columns, **does not delete rows**: `tap_norm_x/y`, `dist_from_target_kw`,
   `is_outlier`, `outlier_flags`. `-t` = far-from-target cutoff in key-widths
   (default 1.25). `-s` = per-key sigma cluster filter (2.5 tight … 3.0 loose).
2. `keystrokes_to_pdf.py <cleaned.csv> [out.pdf]` — tap-distribution PDFs.
3. `gaussian_keyboard_pdf.py <csv> [out.pdf|.svg]` — one full-dataset Gaussian
   boundary (same model the app uses). `.svg` → smooth boundary view.
4. `session_overlap_visualization.py <cleaned.csv> --output-dir DIR` — one Gaussian
   boundary per session + `final_gaussian_ground_truth_boundary.*` + summary CSVs.
   Useful: `--format svg|pdf`, `--raster-step N`, `--demo`.
5. Trial-loss / coverage:
   - `ground_truth_trial_loss.py <cleaned.csv>` — trial prefixes vs all-trial truth.
   - `future-trial-loss.py <cleaned.csv>` — how early trials predict later ones.
   - `key_backoff_report.py <cleaned.csv>` — keys fitted vs borrowed vs geometry fallback.

## FreeTypeRecorder cursor analysis

`cursor_metrics.py <cursor.csv|session_dir> [...] --out cursor_summary.csv`

Classifies logged caret/selection rows as typing, tap reposition, double-tap
selection, drag, keyboard gesture, or other. Add `--events-out cursor_events.csv`
with one input to save every original row plus its derived `cause`.

## FreeTypeRecorder substitution labelling

`substitution_metrics.py <keystrokes.csv|session_dir> [...] [--out-dir DIR]`

Labels every `replace`/`paste` row along orthogonal axes (see
`.claude/data-dictionary.md` for rules, `.claude/decisions/0003-substitution-taxonomy.md`
for why):
- `substitution_source` + `substitution_source_confidence` — who initiated it
  (`autocorrect_engine`, `smart_typography`, `suggestion_bar`,
  `inline_prediction`, `manual_overtype`, `unknown`); the only inferred axis.
  Bar taps vs space-triggered changes split on the trailing delimiter gap
  (`next_delimiter_gap_ms`, ~13 ms vs ~5 ms machine latency).
- `substitution_effect` — what changed (`capitalization`, `punctuation`,
  `contraction`, `completion`, `spacing`, `spelling`, `other`); certain.
- `substitution_outcome` + `revert_latency_ms` — what the user did about it
  (`kept`, `reverted_to_original`, `reverted_other`, `edited_after`), by
  replaying the edit script; certain.
- `substitution_kind` — legacy alias of source + effect (old flat enum).

**Writes a processed CSV per input by default** — no flags needed:

```sh
python3 scripts/substitution_metrics.py sessions_raw/*_keystrokes.csv
```

produces, in `processed-keystrokes/`:
- `<session>_processed.csv` — every original column plus the label columns
- `substitution_summary.csv` — one row per session, counts per source/effect/
  outcome plus `grey_zone_rows`

`--out-dir` moves the folder, `--out` moves just the summary, `--labeled-out`
names the processed file explicitly (one input only). Output folders are created
if missing.

**Folder convention:** raw exports downloaded from Drive live in `sessions_raw/`
as `<session>_keystrokes.csv`; processed output goes in `processed-keystrokes/`.
The raw files are never modified.

The summary's `session_dir` comes from the folder for a `keystrokes.csv` inside a
session dir, and from the filename (minus `_keystrokes`) for a flat export.
Warns when an `ac_off`-named session still contains `autocorrect_engine` rows,
and when an `ac_on`-named session contains none.

## Outlier criteria (clean_keystrokes.py)
`spatial` (norm outside [-0.5,1.5]), `far_from_target` (>1.25 kw), `iki_low` (<50ms,
double-register), `iki_high` (>3000ms, pause), `trial_start`, `delete_event`,
`sigma_outlier` (only with `-s`).

## Support / legacy
- `numpy_analysis_utils.py` — shared numeric helpers.
- `threshold_analysis.py` — threshold sensitivity sweep on a cleaned CSV.
- `plot_cleansing_verification.py` — cleaning verification plots.
- `loss-automation.py` — older overlap helper, kept for compatibility.
- `manual_test_*.py`, `verify_render_and_numpy_pipeline.sh` — synthetic test helpers.

## Reference
Spatial thresholds from Azenkot & Zhai (2012). Gaussian fit: per-key 2D Gaussian,
membership by Mahalanobis distance.
