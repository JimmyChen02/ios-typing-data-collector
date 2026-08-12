# Make keystrokes.csv say what actually happened

Branch: `tran/free-type-analysis`. Cursor/caret work out of scope.
First step on approval: copy this to `.claude/plans/2026-08-12-keystroke-labels.md`.

## Problem

Everything is labeled by shape, not intent. Autocorrect, suggestion taps, inline
predictions, smart punctuation and auto-caps all come out as `replace`.

## 1. Two new columns in keystrokes.csv

`Services/KeystrokeLogger.swift:69` header becomes:

```
t_ms,event_type,replaced_text,replacement_text,range_start,range_length,
resulting_text_length,inter_key_interval_ms,
selected_length_before,marked_text_before
```

| Column | Read from | Answers |
|---|---|---|
| `selected_length_before` | `textView.selectedRange.length` | did the user select text and retype? |
| `marked_text_before` | `textView.markedTextRange != nil` | was an inline prediction pending? |

Both read in `Views/LoggingTextView.swift` at the top of
`shouldChangeTextIn` (currently lines 58-84), before the change applies.

Everything else needed is already in the file — whether a space came right before
is just the previous row.

## 2. Label offline: scripts/substitution_metrics.py

Reads `keystrokes.csv`, writes `keystrokes_labeled.csv` with `substitution_kind`.

| Label | Rule | Certain |
|---|---|---|
| `manual_overtype` | `selected_length_before > 0` | yes |
| `sentence_caps` | same letter, case differs | yes |
| `smart_punct` | punctuation both sides | yes |
| `quicktype_pick` | no keystroke immediately before it | yes |
| `inline_prediction` | `marked_text_before = 1`, or new word extends old | see below |
| `autocorrect` | came after space/period, new word does not extend old | see below |
| `unknown` | fallthrough | — |

Python not Swift, so a bad rule is fixed by re-running, not re-collecting.

**Open question, resolve on your iPhone before finalizing the last two rules:**
type `teh`+space (autocorrect), then `tomo`+space on the ghost text (inline
prediction). If `marked_text_before` is 1 for the prediction and 0 for the
autocorrect, both are certain and no heuristic is needed. If not, they split on
prefix match (`tomo`→`tomorrow` extends, `teh`→`the` doesn't).

## 3. Autocorrect on/off per session

Researcher picks ON/OFF on the setup screen before the session.

- `LoggingTextView` — OFF sets `autocapitalizationType = .none`,
  `smartQuotesType`/`smartDashesType`/`smartInsertDeleteType = .no`.
  `autocorrectionType` stays `.yes` always — verified on simulator that `.no`
  blanks the predictive bar.
- `Logic/SessionMeta.swift` — record `"on"`/`"off"`
- `Logic/SessionNaming.swift` — folder becomes `<name>,<trial>,<hand>,ac_<on|off>`
- `Logic/StudyProtocol.swift` — 10 sessions → 20

`teh`→`the` itself is turned off in iOS Settings → General → Keyboard →
Auto-Correction, since no API separates it from the bar. Setup screen reminds the
researcher. No API reads that setting, so the app can't verify it — but an OFF
session containing `autocorrect` rows is mislabeled, and the script flags it.

## Verify

- `xcodebuild -scheme FreeTypeRecorder -destination 'platform=iOS Simulator,name=iPhone 16' build`
- Swift tests: `KeystrokeLoggerTests` (new columns), `SessionNamingTests`,
  `StudyProtocolTests`, `SessionMetaTests`
- `venv/bin/python -m pytest tests/` + new `tests/test_substitution_metrics.py`
- On your iPhone: one ON and one OFF session. OFF should have zero `autocorrect`
  rows. `keystrokes.csv` must still replay exactly into `final_text.txt`.
