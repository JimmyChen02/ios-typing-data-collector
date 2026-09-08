# 2026-09-07 — Jimmy four-session free-type analysis

## What was run

Renamed the four supplied raw exports, without modifying their contents:

- `sessions_raw/keystrokes_1.csv` → `sessions_raw/jimmy_keystrokes_1.csv`
- `sessions_raw/keystrokes_2.csv` → `sessions_raw/jimmy_keystrokes_2.csv`
- `sessions_raw/keystrokes_3.csv` → `sessions_raw/jimmy_keystrokes_3.csv`
- `sessions_raw/keystrokes_4.csv` → `sessions_raw/jimmy_keystrokes_4.csv`

Ran `substitution_metrics.py` and `word_edit_metrics.py` on every file.
Per-session outputs are in `processed-keystrokes/`. The substitution run also
wrote `jimmy_four_sessions_substitution_summary.csv` (one machine-readable
row per session) and `jimmy_four_sessions_substitution_episodes.csv`
(long-form episode counts). The session logs do not establish a combined
duration, so this record makes no duration claim.

## Capture-integrity finding

Every session diverged during edit replay: session 1 at CSV row 42, session 2
at row 54, segment 3 at row 10, and segment 4 at row 36. At each point the
next ordinary `insert` event advances `resulting_text_length` by more than the
logged replacement text. For example, segment 1 logs `e` at row 43 while the
reported length jumps from 39 to 45. This is consistent with system text
appearing without a matching delegate callback (such as accepted predictive
text), rather than a malformed CSV.

The substitution script therefore preserves source/effect labels but leaves
`substitution_outcome` empty after the divergence. Do not interpret an empty
outcome as `kept`; it means the final episode fate is not certifiable from this
capture. The per-word reports reconcile these gaps conservatively, so their
rates are useful descriptively but should be presented with this capture caveat.

## Initial descriptive result

The four sessions contain 351, 346, 317, and 353 keystroke rows; respectively
13/66, 12/63, 13/55, and 10/72 final words are edited. The edited-word rate
declines in session 4 (13.9%) after 19.7%, 19.0%, and 23.6% in sessions 1–3.
Across the sessions, substitution source labels are predominantly
`autocorrect_engine`; no suggestion-bar or inline-prediction substitution shape
was observed. Source labels remain inferred under ADR 0003.
