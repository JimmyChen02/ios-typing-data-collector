# 2026-08-12 — Substitution labelling: what caused each text change

Branch `tran/free-type-analysis`. Plan: `.claude/plans/2026-08-12-keystroke-labels.md`.
Background audit: `.claude/process/2026-08-12-free-type-analysis.md`.

## Done (commit `441a2a46`)

Two capture columns on `keystrokes.csv`, both read in
`Views/LoggingTextView.swift` before the edit applies:

| Column | Source | Tells you |
|---|---|---|
| `selected_length_before` | `textView.selectedRange.length` | user selected text and typed over it — **certain**, the system never substitutes into a selection |
| `marked_text_before` | `textView.markedTextRange != nil` | an inline prediction was pending — mechanical tell vs autocorrect |

`scripts/substitution_metrics.py` derives `substitution_kind` offline:

- **Certain:** `manual_overtype`, `sentence_caps`, `smart_punct`,
  `quicktype_pick` (no keystroke within 200 ms before it, so it can only be a
  bar tap — autocorrect and inline prediction both require a keystroke)
- **Inferred:** `autocorrect` vs `inline_prediction`, only when
  `marked_text_before` is 0; falls back to completion-vs-correction
  (`tomo`→`tomorrow` extends the typed prefix, `teh`→`the` does not)

Warns when an `ac_off` session contains `autocorrect` rows — the Settings switch
was not actually flipped.

Both new `logEvent` parameters default, so existing call sites are unchanged.

**Verified:** BUILD SUCCEEDED, 45/45 Swift tests, 12/12 Python tests.

## Not done

Step 3 of the plan — the per-session autocorrect ON/OFF condition
(`SessionMeta`, `SessionNaming`, `StudyProtocol` 10→20 sessions, setup-screen
check). Deliberately left for a separate commit; it touches persisted protocol
state and the UI.

Cursor/caret gesture typing was cut from scope by the user.

## Hard-won context

- **Build command.** `xcodebuild -scheme FreeTypeRecorder` from the repo root
  fails. FreeTypeRecorder has its own project:
  `xcodebuild -project FreeTypeRecorder/FreeTypeRecorder.xcodeproj -scheme FreeTypeRecorder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- **`venv/bin/python` has no pytest.** Use system `python3` for `tests/`.
- **`autocorrectionType` gates the QuickType bar.** Verified on an iPhone 17 Pro
  simulator (iOS 26.4) with a throwaway app where only that trait changed and
  global Predictive was on in both runs: `.yes` → bar shows `I · I'm · We`;
  `.no` → bar strip present but **empty**. So the app cannot turn off `teh`→`the`
  while keeping the bar; that half of the OFF condition has to be
  Settings → General → Keyboard → Auto-Correction, set by hand.
  Useful side effect: the strip keeps its height either way, so key geometry —
  and therefore tap coordinates — stay comparable across conditions.
- **Autocorrect depends on the participant's phone, not the app.** The app asks
  (`LoggingTextView.swift:23` sets `.yes`); the device decides. The global
  Auto-Correction switch, the active keyboard language, and the user's learned
  personal dictionary all override it, and none are readable from the app. A
  participant with Auto-Correction off silently produces OFF-condition data
  tagged ON. The setup screen should therefore verify device state for **both**
  conditions, and the script should also flag ON sessions with **zero**
  autocorrect rows.
- **Suggestion taps often log as `paste`, not `replace`.** Tapping a candidate
  frequently inserts the completion at a collapsed caret (`range.length == 0`,
  multi-char), which the shape classifier at `LoggingTextView.swift:58-84` calls
  `paste`. Nothing was pasted. `substitution_metrics.py` therefore classifies
  both `replace` and `paste` rows. `event_type` remains a description of shape;
  `substitution_kind` is the column that carries intent.
- **Two-stage pipeline, and the split surprised the user.** Phone → Drive is
  automatic on session finalize (`NotepadView.swift:334` → `SessionBackup.attempt`).
  Labelling is **not** — `substitution_kind` is absent from the file in Drive and
  is added by running `scripts/substitution_metrics.py` on a downloaded session.
  This is the deliberate tradeoff for offline labelling: a wrong rule is fixed by
  re-running instead of re-collecting.
- **simctl wedged** on the iPhone 17 Pro simulator while installing the app
  (`install` and `listapps` both hung past 3 min with the device shown as
  Booted). Run from Xcode instead of fighting it.

## Next

1. Run the labeller against a real session covering all four actions
   (`teh `+space, `tomo`+space on ghost text, `tomo`+bar tap, double-tap select
   and overtype). The open question: is `marked_text_before` 1 for the inline
   prediction? If yes, both remaining labels become certain and the prefix-match
   fallback is dead code.
2. Then step 3, with the both-conditions device check folded in.
