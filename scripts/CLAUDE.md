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
  (`kept`, `reverted_to_original`, `replaced_with_other`, `deleted_entirely`,
  `edited_after`), by
  replaying the edit script; certain.
- `substitution_kind` — legacy alias of source + effect (old flat enum).

**Writes a processed CSV per input by default** — no flags needed:

```sh
python3 scripts/substitution_metrics.py sessions_raw/*_keystrokes.csv
```

produces, in `processed-keystrokes/<session>/`:
- `<session>_processed.csv` — every original column plus the label columns
- `<session>_summary.md` — vertical markdown: raw behaviour counts (inserts,
  backspaces, whole-selection deletes), one block per mechanism with its
  purposes (effects) and fates (outcomes) indented, an `## episodes` section
  pairing the three axes per substitution with the observed strings
  (`day → say`; reverted rows quote the replayed `episode_final`, printed only
  when `episode_final_trusted`), the session's gap calibration (ADR 0004), and
  a label-definitions glossary. Data lines carry only counts and strings from
  the session itself. `--out FILE.csv` adds one combined machine-readable
  CSV row per session for cross-session stats; `--joint-out FILE.csv` writes
  the episode counts in long format (`session_dir, source, effect, outcome,
  count`).

**Summaries quote participant text.** The observed strings are free-typed
content, so treat `processed-keystrokes/` summaries with the same care as
`sessions_raw/` exports.

Every raw export gets its own `<session>/` folder, so its processed CSV and
reports stay together. Processing a new trial never overwrites an earlier one;
re-running the **same** session regenerates that folder's files after a rule
change.

`--out-dir` moves the folder, `--out` writes one combined summary for the
run's inputs instead of the per-session files, `--labeled-out` names the
processed file explicitly (one input only). Output folders are created if
missing.

**Folder convention:** raw exports downloaded from Drive live in `sessions_raw/`
as `<session>_keystrokes.csv`; each raw export's processed output goes in
`processed-keystrokes/<session>/`. The raw files are never modified.

The summary's `session_dir` comes from the folder for a `keystrokes.csv` inside a
session dir, and from the filename (minus `_keystrokes`) for a flat export.
Warns when an `ac_off`-named session still contains `autocorrect_engine` rows,
and when an `ac_on`-named session contains none.
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

## FreeTypeRecorder per-word edit metrics

`word_edit_metrics.py <keystrokes.csv ...> [--out-dir processed-keystrokes]`

Purpose of the keystrokes.csv export: (1) compute typing performance metrics
(CER/WER, per-word edit rates); (2) serve as behavioral ground truth for
evaluating the adaptive (Gaussian) keyboard.

Decides, for every word in the final text, one binary — edited or typed
clean — and breaks edited words down by correction mechanism
(`backspace_retype`, `autocorrect`, `suggestion_bar`, `inline_prediction`,
`smart_typography`, `select_overtype`), reported as percentages of the word
and character totals with observed examples. Backspace corrections have no
substitution row, so this is the only report where manual self-correction
appears as a category. Substitutions are attributed to the word holding
their inserted characters; deletes carry a left-biased position marker
shifted through later edits into final-text coordinates. Words deleted
entirely are not in the denominator (see `deleted_entirely` outcomes).
Outputs per session in `processed-keystrokes/<session>/`:
`<session>_word_edits.csv`, `<session>_word_summary.md` — both quote
participant text; handle like `sessions_raw/`.

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
