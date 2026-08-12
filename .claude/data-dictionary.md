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

---

# Data Dictionary — FreeTypeRecorder Session Files

A different app and schema from the TypingResearch export above. Free-typing
sessions have no target word, so they have no correctness columns. One session
directory (`Documents/Sessions/<hand>/<name>-<n>/`) contains:

| File | Contents |
|---|---|
| `keystrokes.csv` | Every text-change event |
| `cursor.csv` | Every caret or selection change |
| `imu.csv` | Device motion |
| `final_text.txt` | The text the participant ended with (UTF-8) |
| `session_meta.json` | Participant, hand, device, and prompt; written at session start |
| `face.mov`, `screen.mov`, `seg_images/` | Video and segmented frames |

The loggers start together, so the CSV streams use a common session-relative
`t_ms` origin and can be joined by nearest timestamp.

## `keystrokes.csv`

| Column | Type | Meaning |
|---|---|---|
| `t_ms` | float | Milliseconds since session start |
| `event_type` | str | `insert`, `delete`, `replace`, or `paste` |
| `replaced_text` | str | Text replaced by this edit; empty for a plain insert |
| `replacement_text` | str | Text inserted by this edit; empty for a delete |
| `range_start` | int | UTF-16 offset where the edit applied |
| `range_length` | int | UTF-16 length replaced |
| `resulting_text_length` | int | Swift character count after the edit, not a UTF-16 length |
| `inter_key_interval_ms` | float | Milliseconds since the previous edit; 0 for the first |
| `selected_length_before` | int | Selection length when the change fired. Non-zero means the user highlighted their own text and typed over it — the system never substitutes into a selection |
| `marked_text_before` | 0/1 | Whether marked text (a pending inline prediction) existed when the change fired |

Rows form a complete edit script. Replay them from an empty string using UTF-16
offsets and compare the result with `final_text.txt`. For each row, the text at
`range_start`/`range_length` should equal `replaced_text`; a mismatch indicates
desynchronization and the session should be excluded rather than analyzed.

## `cursor.csv`

| Column | Type | Meaning |
|---|---|---|
| `t_ms` | float | Milliseconds since session start; same origin as the other logs |
| `sel_start` | int | New selection start, or caret position when `sel_length` is 0; UTF-16 |
| `sel_length` | int | New selection length; values greater than 0 mean text is selected |
| `prev_sel_start`, `prev_sel_length` | int | Previous selection, in UTF-16 units |
| `delta_chars` | int | `sel_start - prev_sel_start`; negative means a backward move |
| `caret_x`, `caret_y` | float | Snapped caret origin in text-view points; empty if unavailable |
| `caret_h` | float | Caret height in points; empty if unavailable |
| `touch_x`, `touch_y` | float | Most recent in-app touch in text-view points; empty if unavailable |
| `touch_phase` | str | `began`, `moved`, or `ended`; empty when no touch has been observed |
| `tap_count` | int | UIKit tap count for the latest touch; `2` directly identifies a double tap |
| `touch_age_ms` | float | Milliseconds from the most recent in-app touch to this row |
| `ms_since_last_text_change` | float | Milliseconds since the latest text edit; empty before the first edit |
| `text_length` | int | Current UTF-16 text length |

Empty geometry fields mean unavailable, never zero. `caret_x`/`caret_y` record
where iOS snapped the caret; `touch_x`/`touch_y` record where the finger landed.
Their difference is the caret tap-accuracy signal.

`ms_since_last_text_change` is raw timing rather than a boolean latch. A
same-length autocorrect may not trigger a selection callback, which would leave
a latch stale and mislabel a later deliberate caret move. The timestamp cannot
become stranded and its threshold can be refined offline.

## Derived offline (not columns)

**Cursor `cause`**, derived per row in this priority order:

| Value | Starting rule |
|---|---|
| `typing` | `ms_since_last_text_change < 50`, or `text_length` differs from the previous cursor row |
| `tap` | `touch_phase == "began"` and `touch_age_ms <= 100` |
| `double_tap_selection` | `tap_count == 2` and `sel_length > 0`; directly observed whole-word selection candidate |
| `drag` | `touch_phase == "moved"`; collapse contiguous rows into one episode |
| `keyboard_gesture` | No recent in-app touch and no text change; typically the space-bar trackpad gesture |

**Keystroke `substitution_kind`** — implemented in
`scripts/substitution_metrics.py`, which writes `keystrokes_labeled.csv`. It is
**not** present in the `keystrokes.csv` that uploads to Drive; run the script on
a downloaded session to add it.

Applies to `event_type` of both `replace` **and** `paste`. A suggestion tap often
inserts the completion at a collapsed caret (`range_length == 0`, multi-character),
which the shape classifier calls `paste` even though nothing was pasted.

| Value | Rule | Certain |
|---|---|---|
| `manual_overtype` | `selected_length_before > 0` — the system never substitutes into a selection | yes |
| `sentence_caps` | One character each side, same letter ignoring case | yes |
| `smart_punct` | Both sides punctuation only | yes |
| `quicktype_pick` | No keystroke within 200 ms before it; autocorrect and inline prediction both need one, so this can only be a bar tap | yes |
| `inline_prediction` | `marked_text_before == 1`; else the new word extends the typed prefix (`tomo` → `tomorrow`) | mechanical, else inferred |
| `autocorrect` | Followed a delimiter keystroke and the new word does *not* extend the old (`teh` → `the`) | inferred |
| `unknown` | Fallthrough | — |

The first four are certain. Only `autocorrect` vs `inline_prediction` is inferred,
and only when `marked_text_before` is 0 — both are accepted by the same space
keystroke, so they split on completion-versus-correction.

The script warns when an `ac_off` session contains `autocorrect` rows, which means
the Settings switch was not actually flipped.

## Platform limits

- The offered QuickType candidates cannot be captured. iOS exposes no API for
  them, and ReplayKit hides the system keyboard from `screen.mov`; only accepted
  substitutions are observable.
- Keyboard touches are invisible to the app. Only touches inside the app window
  populate `touch_*`, which is also what makes space-bar gestures distinguishable.
