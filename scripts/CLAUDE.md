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
