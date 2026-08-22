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

## FreeTypeRecorder committed-prefix CER/WER

`prefix_error_metrics.py <keystrokes.csv|session_dir|export_root> [...]`

Replays each edit log without changing it, censors a final word that never
reached whitespace/punctuation, and calculates retrospective CER/WER whenever
a word becomes committed. The current committed words are compared only with
the corresponding final-text prefix, so future text is never counted as an
error. It also calculates active CER and WER after every edit, including the
unfinished word, against the same-length character prefix of the final text.
This keeps a correctly typed partial word at zero while exposing a divergent
partial word immediately. `raw_active_event_outcome` flags events that
introduce or correct observable error units. Outputs default to
`results/prefix-error-metrics/`:

- `session_summary.csv` — raw and spell-normalized references plus final/mean metrics.
- `timestamp_metrics.csv` — event-by-event committed-prefix CER/WER.
- `spelling_audit.csv` — every preserved, suggested, or accepted questionable token.
- `metrics_summary.md` — overall weighted metrics, per-session results, and method notes.

The spelling layer abstains by default. It accepts a correction only from a
reviewed `--corrections-csv original,replacement` map or when a unique local
corpus candidate has strong evidence. Raw and normalized results are always
reported separately. `final_text.txt`, when present, is preferred over replay;
older exports fall back to a conservative replay that marks unlogged inline
prediction text as unknown rather than inventing it.

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
