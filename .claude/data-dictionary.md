# Data Dictionary — Keystroke CSV Schema

Canonical column reference for keystroke exports. **Raw** columns are written by the
iOS app (`DataExporter`); **cleaning** columns are appended by
`scripts/clean_keystrokes.py` (rows are never deleted — only flagged).

## Raw columns (iOS export)
| Column | Type | Meaning |
|---|---|---|
| `participant_first`, `participant_last` | str | Participant name |
| `session_id` | str | Unique session identifier |
| `session_mode` | str | `classic` or `gaussian` |
| `study_session_index` | int | Order of this session within the study design |
| `trial_id` | str | Unique trial identifier |
| `trial_index` | int | Trial number within the session (0–14; 15 trials/session) |
| `event_type` | str | `insert` / `delete` (backspace) |
| `key_label` | str | Key that was hit (a–z, `space`, `delete`) |
| `tap_local_x`, `tap_local_y` | float | Tap position in the hit key's local frame (points) |
| `tap_norm_x`, `tap_norm_y` | float | App-side normalized tap (local / key size) |
| `key_width`, `key_height` | float | Hit key geometry (points) |
| `key_row`, `key_col` | int | Hit key grid position |
| `expected_char` | str | Character the prompt expected here |
| `actual_char` | str | Character actually produced |
| `corrected_char` | str | Char after any correction |
| `is_correct` | int | 1 if actual == expected |
| `previous_key_label` | str | Prior key (for IKI context) |
| `text_before` | str | Field text before this event (empty = trial start) |
| `timestamp_ms` | int | Event time (ms) |
| `inter_key_interval_ms` | float | ms since previous event |

## Cleaning columns (appended by clean_keystrokes.py)
| Column | Type | Meaning |
|---|---|---|
| `tap_norm_x`, `tap_norm_y` | float | **Recomputed** normalized tap (tapLocal / keySize); 0=left/top, 1=right/bottom. Note: appears a second time after the raw pair. |
| `dist_from_target_kw` | float | Distance from tap to the **expected** key rect, in key-widths (0 if inside) |
| `is_outlier` | int | 1 if any flag fired |
| `outlier_flags` | str | Pipe-separated reasons (empty = clean) |
| `is_spatial_outlier` | int | (some variants) 1 if normalized tap outside `[-0.5, 1.5]` |

## Outlier flag values
| Flag | Trigger |
|---|---|
| `spatial` | `tap_norm_x/y` outside `[-0.5, 1.5]` (>½ key-width outside hit key) |
| `far_from_target` | `dist_from_target_kw` > 1.25 (too far to be a neighbor mistap) |
| `iki_low` | `inter_key_interval_ms` < 50 (double-registration) |
| `iki_high` | `inter_key_interval_ms` > 3000 (pause / distraction) |
| `trial_start` | `text_before` == "" (first keystroke of a trial) |
| `delete_event` | `event_type` == "delete" (intentional backspace) |
| `sigma_outlier` | > N std devs from expected key's cluster mean (only with `-s`) |

Filename convention: `<name>_cleaned_t<thr>[_s<sigma>].csv` encodes the cleaning
thresholds used (e.g. `_cleaned_t1.0_s2.5.csv`).
