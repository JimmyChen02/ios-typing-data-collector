# Substitution taxonomy: split one flat enum into orthogonal axes

## Context

`scripts/substitution_metrics.py` labels every `replace`/`paste` row in a
FreeTypeRecorder session with `substitution_kind` — a single flat enum
(`manual_overtype`, `sentence_caps`, `smart_punct`, `quicktype_pick`,
`inline_prediction`, `autocorrect`, `unknown`). Three problems, all confirmed
against real data in `sessions_raw/Tran_test2_*.csv`:

1. **`quicktype_pick` can never fire.** Its rule (`substitution_metrics.py:172-175`)
   assumes a suggestion-bar tap has no following delimiter keystroke. False — iOS
   auto-appends a space after a candidate tap, logged as its own `insert` row
   ~12 ms later, shape-identical to a typed space. Every bar tap therefore falls
   through to the `_extends` completion test and mislabels as `inline_prediction`.
   Verified against screen recording: `act`→`actually` (t=13607),
   `prett`→`pretty` (t=15575), `wea`→`weather` (t=62552) were all bar taps, all
   labelled `inline_prediction`. Zero `quicktype_pick` rows exist across both
   sessions.

2. **The enum answers two unrelated questions in one slot.** `quicktype_pick` and
   `manual_overtype` describe *who initiated* the change; `sentence_caps` and
   `smart_punct` describe *what changed*. These are not mutually exclusive — a bar
   tap can also fix capitalization — so they compete for one column, and a single
   uncertain mechanism inference poisons the entire label.

3. **`sentence_caps` is misnamed.** `autocapitalizationType = .sentences`
   (`LoggingTextView.swift:24`) works by pre-shifting the shift key, producing a
   capital directly at insert time; it can never emit a `replace`. So `i`→`I`
   arriving as a replace *is* the autocorrect engine, same mechanism as
   `coler`→`cooler`. It differs only in effect. (`smart_punct` is genuinely
   distinct — `smartQuotesType`/`smartDashesType`, `LoggingTextView.swift:26-27` —
   an insert-time deterministic rule, not the correction engine.)

Splitting into orthogonal axes fixes all three and **degrades gracefully**: effect
and outcome are computable with certainty from the text alone, so they stay clean
even while source inference remains shaky.

A fourth axis is new signal the pipeline has never captured: **what the user did
after a substitution**. Nothing in the repo joins a substitution to the later
deletes that undo it, yet the data supports it — every delete row carries
`replaced_text` and `range_start` (`LoggingTextView.swift:74`), and
`.claude/data-dictionary.md:89-91` guarantees rows form a complete replayable edit
script. A user restoring exactly what they originally typed is the cleanest
"the correction was wrong" signal in the corpus.

**Analysis-only.** No app or capture changes, preserving the original decision at
`.claude/plans/2026-08-12-keystroke-labels.md:46` — label in Python so a bad rule
is fixed by re-running, not re-collecting.

## New schema

Replaces `substitution_kind`, with a derived alias kept for compatibility.

| Column | Certainty | Values |
|---|---|---|
| `substitution_source` | inferred | `autocorrect_engine`, `smart_typography`, `suggestion_bar`, `inline_prediction`, `manual_overtype`, `unknown` |
| `substitution_source_confidence` | — | `certain`, `inferred`, `grey_zone` |
| `substitution_effect` | **certain** | `capitalization`, `punctuation`, `contraction`, `completion`, `spacing`, `spelling`, `other` |
| `substitution_outcome` | **certain** | `kept`, `reverted_to_original`, `reverted_other`, `edited_after` |
| `revert_latency_ms` | **certain** | float, empty when `kept` |
| `substitution_kind` | — | derived alias, reproduces the old enum exactly |

## Implementation — `scripts/substitution_metrics.py`

### 1. `substitution_source` — replace `_classify_substitution`

Delete the `triggered` / `quicktype_pick` block (`:162-175`) outright; it is proven
unfireable. New priority cascade:

| # | Test | Source | Confidence |
|---|---|---|---|
| 1 | `selected_length_before > 0` | `manual_overtype` | certain |
| 2 | both sides punctuation-only (reuse `_is_punctuation`, `:90`) | `smart_typography` | certain |
| 3 | `marked_text_before == 1` | `inline_prediction` | certain |
| 4 | `_extends(old,new)` and `inter_key_interval_ms >= 350` | `suggestion_bar` | inferred |
| 5 | `_extends(old,new)` and iki < 350 | `inline_prediction` | inferred |
| 6 | `old` non-empty | `autocorrect_engine` | inferred |
| 7 | else | `unknown` | — |

Rows 4/5 with iki in **250–450 ms** get `grey_zone` confidence — flag for manual
review against video rather than trusting silently.

Rationale for IKI, and it is mechanistic not fitted: an autocorrect is *generated
by* the space keypress, so it inherits that keystroke's in-rhythm interval. A bar
tap needs the thumb to leave the key grid and reach the strip; that travel is the
gap. Measured in test2 — bar taps 573 / 591 / 922 ms, autocorrects 95 / 112 /
166 ms. Define `BAR_TAP_IKI_MS = 350.0` and `GREY_ZONE_MS = (250.0, 450.0)` as
named module constants beside the existing `TRIGGER_WINDOW_MS` (`:42`).

Apply the IKI test **only inside the `_extends` branch**. `Lol`→`lol` is a genuine
autocorrect at 717 ms; because it corrects rather than extends, it never reaches
the threshold test and stays correct.

### 2. `substitution_effect` — new `_classify_effect(old, new)`

Pure function of the two strings. Order matters; first match wins:

1. `old.lower() == new.lower()` and `old != new` → `capitalization`
   (**drop the `len == 1` restriction** in `_is_case_variant` (`:94`) so `Lol`→`lol`
   is caught, not just `i`→`I`)
2. `_is_punctuation(old) and _is_punctuation(new)` → `punctuation`
3. stripping `'’"“”` from `new` gives `old` case-insensitively → `contraction`
   (`its`→`it's`)
4. `_extends(old, new)` (`:98`) → `completion`
5. `old` and `new` equal ignoring whitespace → `spacing`
6. both non-empty → `spelling`
7. else → `other`

### 3. `substitution_outcome` — new `_classify_outcomes(rows)`

Whole-session pass, run after per-row source/effect labelling.

Replay the edit script (guaranteed replayable, data-dictionary `:89-91`) to
reconstruct text state at each step. For each substitution at `range_start = k`
inserting `new`, track the span `[k, k + len(new))` forward, shifting it by the
signed length delta of each subsequent edit that lands before it. Then:

- a later `delete` overlapping the span → the substitution was undone; compare what
  ends up in that position:
  - equals the original `replaced_text` → `reverted_to_original`
  - differs from both `replaced_text` and `new` → `reverted_other`
  - span modified but partially intact → `edited_after`
- never touched by end of session → `kept`

`revert_latency_ms` = first overlapping delete's `t_ms` minus the substitution's
`t_ms`. This is the behavioural measure — how long before the user noticed.

Precedent worth reading first, though it serves a different purpose (Gaussian fit
contamination, not intent): commit `9871ba51` on branch `tran/analyze-keytaps` adds
`scripts/align.py`, `validate_trials.py`, `build_distributions.py` and
`.claude/process/2026-07-09-backspace-rectification.md`. Those files do **not**
exist on this branch; read via `git show 9871ba51` for its span-tracking approach.

### 4. Derived `substitution_kind` alias

Reproduces the old enum exactly so nothing downstream breaks:

| source + effect | legacy kind |
|---|---|
| `manual_overtype` | `manual_overtype` |
| `smart_typography` | `smart_punct` |
| `autocorrect_engine` + `capitalization` | `sentence_caps` |
| `suggestion_bar` | `quicktype_pick` |
| `inline_prediction` | `inline_prediction` |
| `autocorrect_engine` + anything else | `autocorrect` |
| `unknown` | `unknown` |

### 5. Summary CSV

Extend `SUMMARY_FIELDS` (`:26-37`) to count per axis, keeping the existing
`kind_to_field` fan-out pattern (`:196-209`) — three fan-outs instead of one:
`session_dir`, `keystroke_rows`, `substitution_rows`, then `source_*`, `effect_*`,
`outcome_*` counts, plus `grey_zone_rows`. Keep the `ac_off` warning (`:258-266`)
and add the symmetric one the process notes call for: warn when an `ac_on` session
has **zero** `autocorrect_engine` rows, meaning the device switch was off and the
session is silently mislabelled.

## Files

| File | Change |
|---|---|
| `scripts/substitution_metrics.py` | all of the above; `write_processed` (`:213`) needs no change, it emits whatever columns the rows carry |
| `tests/test_substitution_metrics.py` | extend; see below |
| `.claude/data-dictionary.md:133-157` | rewrite the `substitution_kind` section for the new axes |
| `.claude/decisions/0003-substitution-taxonomy.md` | **new ADR** — no ADR covers the taxonomy today (only `0001` spatial thresholds, `0002` sigma filter). Record why the flat enum was split, why `quicktype_pick`'s original rule was wrong, and why 350 ms |
| `scripts/CLAUDE.md:44-70` | update the substitution-labelling section for the new columns |
| `.claude/process/2026-08-12-substitution-labels.md` | append a run entry |

## Verification

1. `python3 -m pytest tests/test_substitution_metrics.py` — system `python3`, **not**
   `venv/bin/python` (it has no pytest). Existing 11 tests must still pass via the
   derived alias. Add cases for: each effect value; `suggestion_bar` vs
   `inline_prediction` either side of 350 ms; grey-zone flagging; `Lol`→`lol` staying
   `autocorrect_engine` + `capitalization`; each outcome value; a `paste`-shaped
   substitution; the `ac_on`-with-zero-autocorrect warning. (Existing tests already
   cover `paste` and `unknown` poorly — the Explore pass found both untested.)
2. `python3 scripts/substitution_metrics.py sessions_raw/*_keystrokes.csv`
3. **Ground-truth check against the video-confirmed rows in test2** — this is the
   acceptance test:

   | t_ms | change | expected source | expected effect |
   |---|---|---|---|
   | 13607 | `act`→`actually` | `suggestion_bar` | `completion` |
   | 15575 | `prett`→`pretty` | `suggestion_bar` | `completion` |
   | 62552 | `wea`→`weather` | `suggestion_bar` | `completion` |
   | 23782 | `coler`→`cooler` | `autocorrect_engine` | `spelling` |
   | 30055 | `i`→`I` | `autocorrect_engine` | `capitalization` |
   | 43091 | `its`→`it's` | `autocorrect_engine` | `contraction` |
   | 47959 | `Lol`→`lol` | `autocorrect_engine` | `capitalization` |

   All three bar taps must move off `inline_prediction`. Any row still labelled
   `inline_prediction` is a bug — the session contains no ghost-text acceptance.
4. Diff the derived `substitution_kind` against the committed
   `processed-keystrokes/*_processed.csv` to confirm only the three bar-tap rows
   change (`inline_prediction` → `quicktype_pick`) and nothing else moves.

## Known limitation — do not paper over it

`marked_text_before` is 0 on **all 19 substitutions across both sessions**; the
mechanical tell has never once fired. Combined with all three
`inline_prediction` rows in test2 being confirmed bar taps, **there is not one
confirmed inline-prediction example in the corpus**, so cascade step 5 is
uncalibrated and the 350 ms threshold rests on n=3 bar taps.

The ADR must state this plainly. Resolving it needs a deliberate ghost-text trial
(type `tomo`, accept the inline suggestion by swipe/tap rather than the bar, repeat
~10x, once per hand) to answer whether `markedTextRange` is non-nil by the time
`shouldChangeTextIn` runs. If it is, step 3 becomes mechanical and steps 4–5 reduce
to a backstop. This is data collection, out of scope here.

Also out of scope, both previously deferred and unchanged by this plan: step 3 of
`keystroke-labels.md` (per-session `ac_on`/`ac_off` condition — `SessionMeta`,
`SessionNaming`, `StudyProtocol` 10→20 sessions), and setting `inlinePredictionType`
explicitly (needs `if #available(iOS 17.4, *)`; deployment target is iOS 17.0 per
`FreeTypeRecorder/project.yml:3-4`, and the trait is currently never set, so ghost
text runs at an iOS default that cannot be reported as a controlled condition).

---

## Amendment (2026-08-13, at implementation)

Superseded before shipping, per the same-day touch-capture audit and
`.claude/decisions/0003-substitution-taxonomy.md`:
- Cascade steps 3–5: the 350 ms preceding-IKI rule was replaced by the
  **trailing delimiter gap** (split 9 ms, grey zone 7–12 ms, `_extends` branch
  only); `marked_text_before` demoted from certain per-row rule to word-level
  preceding-row hint. `next_delimiter_gap_ms` ships as a column.
- Verification 3–4: expected diff is larger than "three bar taps" — also
  `taro`→`tarot`, `shit`→`shitt` (→ `quicktype_pick`), `Lol`→`lol`
  (→ `sentence_caps`), `read`→`reading` and `I ask`→`i asked` (low-gap group).
