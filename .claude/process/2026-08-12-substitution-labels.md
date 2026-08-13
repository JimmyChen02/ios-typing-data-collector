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

## 2026-08-13 — first real-session run, and the folder convention

Ran the labeller on the one downloaded session, `sessions_raw/Tran_test1_keystrokes.csv`
(225 keystroke rows). Two small script fixes were needed first:

- **`session_dir` was the parent folder name.** A flat export sitting in
  `sessions_raw/` came out labelled `sessions_raw`, so every session would share
  one label and the `ac_off` warning could never match. `session_label()` now
  falls back to the filename minus `_keystrokes` when the file is not a
  `keystrokes.csv` inside a session folder.
- **Output folders were not created.** Writing into a fresh
  `processed-keystrokes/` raised `FileNotFoundError`; `_write_csv()` now
  `makedirs(exist_ok=True)` first.
- **The processed CSV was opt-in and single-input.** It only appeared if you
  passed `--labeled-out PATH`, and that flag rejected more than one input, so the
  default run produced only a summary. Producing the processed file *is* the
  point of the script, so it is now the default: every input gets
  `processed-keystrokes/<session>_processed.csv`, the summary defaults to
  `processed-keystrokes/substitution_summary.csv`, and both paths are still
  overridable (`--out-dir`, `--out`, `--labeled-out`).

**Convention now documented in `scripts/CLAUDE.md`:** raw exports stay untouched
in `sessions_raw/`, processed output goes to `processed-keystrokes/`. Nothing is
written back into the raw folder.

### Result: 225 rows, 10 substitutions

| kind | n |
|---|---|
| `sentence_caps` | 4 (`i`→`I`) |
| `autocorrect` | 2 (`wrnt`→`went`, `my dgo`→`my dog`) |
| `inline_prediction` | 4 (`taro`→`tarot`, `read`→`reading`, `shit`→`shitt`, `I ask`→`i asked`) |
| everything else | 0 |

**`marked_text_before` was 0 on all ten rows — the mechanical tell never fired.**
So the answer to the old open question is *no*: the completion-vs-correction
prefix fallback is not dead code, it is the only thing separating
`inline_prediction` from `autocorrect` in real data. Either the session contained
no ghost-text acceptance, or `markedTextRange` is nil by the time
`shouldChangeTextIn` runs for a prediction. **Needs a deliberate ghost-text trial
to tell those apart before trusting the split.**

Two labels look wrong and show where the fallback is weak:
- `I ask`→`i asked` — a *de*-capitalisation, so not a pure completion; the prefix
  test still passes because it is case-insensitive.
- `shit`→`shitt` — extends by one character, almost certainly a bar tap, but it
  arrived with a trigger keystroke so it cannot be `quicktype_pick`.

Also untested by this session: zero `paste` rows, zero `quicktype_pick`, zero
`manual_overtype`. The bar-tap and select-and-overtype paths are still unexercised
against real data.

## Next

1. Run the labeller against a real session covering all four actions
   (`teh `+space, `tomo`+space on ghost text, `tomo`+bar tap, double-tap select
   and overtype). The open question: is `marked_text_before` 1 for the inline
   prediction? If yes, both remaining labels become certain and the prefix-match
   fallback is dead code.
2. Then step 3, with the both-conditions device check folded in.

---

## 2026-08-13 — Taxonomy split shipped (trailing-gap rule)

Implemented `.claude/plans/substitution-taxonomy-2026-08-13.md` **amended by**
the same-day touch-capture audit: the planned 350 ms preceding-IKI bar-tap rule
was replaced with the audit's trailing delimiter gap (9 ms split, 7–12 ms grey
zone), scoped to the `_extends` branch only. The planned
`marked_text_before == 1` "certain" rule was dropped (proven never to fire on a
substitution row) and demoted to a word-level preceding-row hint. Full
rationale: `.claude/decisions/0003-substitution-taxonomy.md`.

New columns: `substitution_source` (+confidence), `substitution_effect`,
`substitution_outcome`, `revert_latency_ms`, `next_delimiter_gap_ms`;
`substitution_kind` kept as derived alias. Summary fans out per axis.

**Errors hit / fixed while replaying the edit script for outcomes:**
1. While `marked_text_before == 1`, `resulting_text_length` includes the
   uncommitted marked text (test1 row ~15, test2 row ~39), so replay
   "diverged" on healthy data → marked rows exempted from the length check.
2. Tran_test1 row 167 is a **real capture gap**: an auto-inserted space was
   retracted by iOS with no delegate callback (insert " " at 148 → length 149,
   next insert lands at 148 with length 149 again). Replay stops there;
   outcomes resolved before it are kept, later spans stay unlabelled (`kept`
   is never guessed). test2 replays end to end.

**Verification (all passed):** 34 pytest cases; ground-truth rows —
`act`→`actually`, `prett`→`pretty`, `wea`→`weather` all `suggestion_bar` /
`completion` (gaps 12.68/12.35/12.66 ms); `coler`→`cooler` spelling,
`i`→`I` + `Lol`→`lol` capitalization, `its`→`it's` contraction, all
`autocorrect_engine`. Diff vs previous processed CSVs: 5 rows
`inline_prediction`→`quicktype_pick` (3 confirmed bar taps + `taro`→`tarot` +
`shit`→`shitt`, matching the suspicion above); `Lol`→`lol`
`autocorrect`→`sentence_caps` (len==1 restriction dropped); `read`→`reading` →
`inline_prediction` grey_zone via the marked hint; **and one row not in the
plan's expected diff**: `I ask`→`i asked` (test1, gap 5.58 ms, no marked hint)
`inline_prediction`→`autocorrect` — investigated, it is the audit's low-group
row behaving as designed; the plan's expected-diff list had missed it.

Still open: the labelled ghost-text/bar-tap trial (uncalibrated low-gap
branch), and the FreeTypeRecorder capture gap class from error 2 — silent
system edits are invisible to `shouldChangeTextIn`.
