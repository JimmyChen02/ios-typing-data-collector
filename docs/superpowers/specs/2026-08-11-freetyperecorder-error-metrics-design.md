# FreeTypeRecorder Error Metrics — Design

**Date:** 2026-08-11
**Status:** Approved design, not yet implemented
**Scope:** FreeTypeRecorder only. Offline Python analysis of already-collected `keystrokes.csv`.

## Problem

FreeTypeRecorder records free-composition typing on the stock iOS keyboard with
autocorrect, QuickType, and smart punctuation deliberately enabled
(`LoggingTextView.swift:24-28`). It computes **no error metrics at all** — `keystrokes.csv`
is a bare event stream.

The TypingResearch method cannot be ported, because it indexes into a known
`trial.targetText` (`SessionManager.swift:125`). Free composition has no target text.

The research question this must serve: **what is the raw tap error rate of the Apple
keyboard, stripped of the assistance autocorrect and QuickType provide?** That is the
only number fairly comparable to a Gaussian-keyboard error rate, since the
TypingResearch keyboard has autocorrect disabled. A naive comparison is confounded —
Apple would look better purely because software cleaned up after the user.

The four repair mechanisms are what make intent recoverable without a target text.
When a user types `bipe` and any mechanism turns it into `bike`, they have
retroactively revealed the target: `p→k` is a scored error.

## Constraints

- **No app changes.** The CSV schema is frozen.
- **No protocol changes.** No participant-supplied reference text (the CHI '21
  recommended method) — it would require re-running collected participants.
- Analysis runs offline from the repo root using the project venv.

## Input

Per session, `keystrokes.csv`:

```
t_ms, event_type, replacement_text, range_start, range_length,
resulting_text_length, inter_key_interval_ms
```

`event_type` ∈ `{insert, delete, replace, paste}` as assigned in
`LoggingTextView.swift:50-60`. `range_start` / `range_length` are **NSRange values in
UTF-16 code units**, not Python code points.

## Architecture

`scripts/freetype_metrics.py`, a single module with four stages. Each stage is a pure
function over the previous stage's output, so each is testable in isolation.

```
keystrokes.csv → replay → classify → align → metrics → per-session report
```

### Stage 0 — Replay

Rebuild the exact buffer after every event:

```
text   = text[:range_start] + replacement_text + text[range_start + range_length:]
cursor = range_start + len(replacement_text)
```

Operate on a UTF-16 code-unit representation so indices match the logged NSRanges.
Emoji or other non-BMP input would otherwise silently misalign every subsequent index.

**Invariant:** replayed length must equal `resulting_text_length` on every row — but
only for ASCII buffers. `resulting_text_length` is Swift's `String.count` (grapheme
clusters) while `range_start`/`range_length` are UTF-16 code units, and the two
legitimately disagree once the buffer contains non-BMP input (emoji, etc.), so the
check cannot be a blanket assertion. For an ASCII buffer, checking is exact and a
mismatch is logged as a per-event warning. Once the buffer goes non-ASCII, the
invariant is no longer checked and the module emits a single warning per session (not
one per subsequent event) noting the divergence and the index where it first
appeared.

Output per event: buffer before, buffer after, cursor before, cursor after.

### Stage 1 — Mechanism classification

Applied in priority order. `prev_cursor` is the cursor after the previous event.

`replace` events are fully resolved by rules 1–5; `insert` and `delete` events by
rules 6–9. A *trailing edit* means the replaced range ends exactly at the cursor
(`range_start + range_length == cursor_before`).

| Order | Applies to | Mechanism | Rule |
|---|---|---|---|
| 1 | `replace` | `smart_punctuation` | `(old, new)` in the smart-punctuation map (`'→’`, `"→“”`, `--→—`). **Excluded from repair analysis** — not a user repair |
| 2 | any | `paste` | `event_type == paste`. **Excluded from repair analysis** — not a user repair |
| 3 | `replace` | `autocorrect` | a trailing edit, **and** a character-insert event occurs within `AC_WINDOW_MS` |
| 4 | `replace` | `suggestion` | a trailing edit, temporally isolated — no character-insert within `AC_WINDOW_MS` either before or after |
| 5 | `replace` | `select_retype` | any other `replace` — the replaced range does not end at the cursor, i.e. a reach-back selection overwrite |
| 6 | `insert`/`delete` | `cursor_move` | range not contiguous with the cursor |
| 7 | `delete` | `backspace` | `range_length == 1`, contiguous |
| 8 | `delete` | `bulk_delete` | `range_length > 1`, contiguous |
| 9 | `insert` | `insert` | ordinary forward typing |

**Autocorrect vs suggestion.** Autocorrect fires synchronously inside the triggering
keystroke's runloop turn, so a character insert sits adjacent to it in time. A QuickType
tap is a standalone user action with no accompanying character and a human-scale
interval. Discriminating on *temporal isolation* rather than on the sign of the interval
avoids depending on which order UIKit fires the two delegate calls.

**Why `cursor_move` does not apply to `replace`.** An earlier draft ranked `cursor_move`
above `select_retype` for all event types, which would have made `select_retype`
practically unreachable — nearly every real select-and-retype requires navigating away
from the current cursor first. The two are genuinely different user actions: a
`cursor_move` repair is *delete-then-retype* at a moved position and spans several
events, while a `select_retype` is a *single* event replacing a selection. Position is
what distinguishes reaching back from editing in place; the event type is what
distinguishes selecting from backspacing. Both matter, so both are used.

**Known ambiguity.** A user who selects the *last* word and retypes it produces the same
log signature as a QuickType tap: a temporally isolated trailing-edit `replace`. Neither
the range nor the timing separates them, so such events are classified `suggestion` and
will slightly inflate the assisted ledger. This is one more thing the screen-recording
validation should measure.

`AC_WINDOW_MS` defaults to 30 ms and **is a calibration parameter, not a known
constant.** It must be fit against labelled data (see Validation) before any reported
number depends on it.

### Stage 2 — Intent extraction and alignment

**Episode grouping.** Following Alharbi et al.'s *editing episode*: an episode opens at
the first `backspace`, `bulk_delete`, or `cursor_move`, and closes when forward typing
resumes past the repair point. `autocorrect`, `suggestion`, and `select_retype` events
are single-event episodes — `select_retype` is manual, so its keystrokes count toward
`F`, while `autocorrect` and `suggestion` contribute `F = 0`.

**Pair extraction.** For each episode, diff the buffer before the episode against the
buffer after it, and take the changed region. This yields `(D, R)` — the typed string and
the intended string — directly, and is more robust than tracking individual deletions,
which arrive right-to-left.

- backspace / bulk_delete / cursor_move: `D` = removed region, `R` = replacement region
- autocorrect: `D` = replaced word, `R` = replacement word (trailing space stripped)
- suggestion: `D` = typed partial word, `R` = chosen word

**Completion special case.** If `D` is a strict prefix of `R` (case `Bi → bike`), the
episode is a *completion*, not a repair. Zero errors. The characters in `R[len(D):]` are
system-supplied and counted in `S`. Only a non-prefix (`Be → bike`) scores.

**Alignment.** Levenshtein DP over `(D, R)`, then enumerate **all** optimal backtrace
paths rather than one, per Wobbrock & Myers. Each operation is weighted by
`1 / num_paths`.

Cap enumeration at `MAX_ALIGNMENTS = 64`; beyond that, weight uniformly over the first
64 found and flag the episode. Report how often the cap is hit.

Each aligned operation emits a row `(typed_char, intended_char, op, weight, mechanism)`:

| Alignment op | Class |
|---|---|
| match | `CNE` — correct keystroke erased as collateral |
| substitution | `IF` — erroneous keystroke, intent recovered |
| char in `D` not in `R` | `IF` — extra character the user typed |
| char in `R` not in `D` | corrected omission — **no erroneous keystroke exists**; counted separately, never as `IF` |

### Stage 3 — Metrics

```
|T|   final text length
S     characters in T supplied by the system (completions, autocorrect insertions)
U     = |T| − S                     user-attributable characters in T   ( = C + INF )
IF_m  erroneous keystrokes the user removed manually
IF_a  erroneous keystrokes autocorrect/suggestion removed
IF    = IF_m + IF_a
CNE   correct keystrokes erased as collateral
F     manual fixing keystrokes
INF   errors surviving in T                                    (estimated, see below)
D     = U + IF                      denominator ( = S&M's C + INF + IF )
K     = U + IF + CNE                all user character-producing keystrokes
```

**`CNE` sits deliberately outside `D`.** S&M 2003 has no class for a correct character
that was erased anyway: it is not `C` (absent from `T`), not `INF` (absent from `T`), and
not `IF` (it was not an error). Wobbrock & Myers added the class precisely because the
four-bucket scheme cannot hold it. Keeping `D = U + IF` therefore stays faithful to the
published denominator, and `CNE` is reported separately rather than folded in.

**Exact — no reference text required:**

```
Corrected error rate         = IF / D
KSPC (effort)                = (U + IF + F) / D
KSPC (output)                = (K + F) / |T|             may fall below 1 with suggestions
Manual correction efficiency = IF_m / F
Assistance share             = IF_a / IF
Keystrokes saved             = S
Coverage                     = (IF + CNE) / K
Per-mechanism episode counts, and correction latency per mechanism
```

`KSPC (output)` counts only keystrokes the user actually made — `K` character keystrokes
plus `F` fixing keystrokes — over the delivered text length. System-supplied characters
inflate `|T|` without costing a keystroke, which is exactly why this ratio can drop below
1 and why it is reported separately from `KSPC (effort)`.

`Coverage` is over `K`, all user character keystrokes, not over `D` — the question it
answers is what fraction of the user's taps a repair gave direct intent evidence for, and
`CNE` keystrokes are evidence-bearing even though they sit outside `D`.

**Bounded — depends on `INF`:**

```
Uncorrected error rate = INF / D
Total error rate       = (INF + IF) / D
Conscientiousness      = IF / (IF + INF)
```

**Headline number for the keyboard comparison:**

```
Raw tap error rate = (IF_m + IF_a + INF) / D
```

Every character where the finger hit the wrong key, regardless of who cleaned it up.
`IF_m + IF_a` is exact; only the `INF` term is bounded.

### `INF` estimation

Vocabulary check on the final text — the backoff paper's *word-level method*. Tokenise
`T`, lowercase, strip punctuation. For each out-of-vocabulary token, add its minimum
Levenshtein distance to the nearest in-vocabulary word.

Vocabulary: `/usr/share/dict/words` (present on macOS, ~236k entries), plus a
project allowlist for proper nouns and informal spellings that appear in the prompts.

This misses real-word errors (`their`/`there`), so it is strictly a **lower bound**.

### Reporting rule

Every `INF`-dependent metric is reported as a bound (`≥ X%`), never as a point estimate,
with `INF ≥ INF_dict` stated explicitly and the real-word-error limitation named. Exact
metrics are reported unqualified alongside them, clearly separated.

### Stage 4 — Output

Per session: one row appended to a summary CSV, plus a per-session JSON holding the
episode list with extracted `(D, R)` pairs and their aligned operations, so any number
can be traced back to the events that produced it.

Summary columns: session id, participant, hand condition, session index, `|T|`, `S`,
`U`, `IF_m`, `IF_a`, `CNE`, `F`, `INF_dict`, each metric above, per-mechanism episode
counts, coverage, and the count of alignment-cap hits.

## Validation

**Replay invariant.** Stage 0's length check runs on every session and surfaces as
warnings, not as a blocking assertion — see Stage 0 for why a blanket assertion would
be wrong. A non-zero warning count on an ASCII session means the replay and the logger
genuinely disagree and that session's numbers should not be trusted; a single
non-ASCII warning is expected and benign.

**Mechanism classifier accuracy.** The screen recordings already on Drive show the
keyboard. Hand-label the mechanism for a sample of episodes across participants and
score Stage 1 against it. This requires no app or protocol change, and turns
`AC_WINDOW_MS` from a guess into a fitted parameter with a reported accuracy figure.
Target: label enough episodes to bound classifier accuracy per mechanism, with
autocorrect-vs-suggestion the pair that matters most.

**Published worked example.** Wobbrock & Myers' `qucehkly` example has four optimal
alignments and a known expected result: substitution for "i" tallies 0.75, omission
0.25. Use it as a fixture for the fractional-weighting code.

## Testing

- Synthetic event streams for each of the four slide mechanisms, with hand-computed
  expected `IF`/`CNE`/`F` counts:
  - backspace: `bipe` →×3 backspace→ `bike` ⇒ `IF=1`, `CNE=2`, `F=3`
  - autocorrect: `bipe ` → `bike ` ⇒ `IF_a=1`, `F=0`
  - suggestion completion: `Bi` → `bike` ⇒ `IF=0`, `S=2`
  - suggestion correction: `Be` → `bike` ⇒ `IF_a=1`, `S=2`
  - cursor move: `bipe`, cursor to after `p`, backspace, type `k` ⇒ `IF=1`, `CNE=0`, `F=1`
- Replay round-trip against `resulting_text_length` on every fixture.
- Smart-punctuation events produce no repair episodes.
- An autocorrect immediately reverted by backspace credits no user error.
- UTF-16 index handling: a fixture containing a non-BMP character.

## Departures from published method

What is taken directly from prior work, and what is not. The novel parts are forced by
the setting, but each needs defending in writing rather than presenting as standard.

**Faithful to published method:**

| Element | Source |
|---|---|
| `C/INF/IF/F` classes and the error-rate family | Soukoreff & MacKenzie 2003 |
| Corrected-no-error class | Wobbrock & Myers 2006 §3.1.2 |
| All-optimal-alignments with fractional weighting | Wobbrock & Myers 2006 |
| Editing-episode unit and correction latency | Alharbi et al. 2020 |
| Treating in-vocabulary completed words as labelled data | backoff paper, word-level method |

**Departures:**

1. **No presented text.** Wobbrock & Myers' algorithm aligns `P`, `T`, and `IS`;
   "unconstrained" in their sense means subjects still transcribe a presented string and
   are merely free to correct or not. Free composition has no `P` at all. This design
   applies their *alignment technique* to `(D, R)` pairs recovered from repairs, not to
   `(P, T)`. That is an adaptation of their method, not an application of it, and their
   assumption "subjects proceed sequentially through `P`" (§3.2.1) has no meaning here.
   Their remaining assumptions — one insert/omit in a row, backspaces accurate and
   intentional — do carry over and are adopted.

2. **Autocorrect and suggestion detection by temporal isolation.** No published
   precedent. Alharbi et al. simulated both features rather than detecting them,
   specifically because keyboard APIs do not expose the internals; their string-shape
   heuristic was a warning that a participant had failed to disable their keyboard, not a
   classifier. This rule is new, `AC_WINDOW_MS` is unvalidated, and the entire
   assisted-versus-manual split rests on it. **Highest methodological risk in this
   design.** The screen-recording validation is what converts it from assertion to
   measured accuracy; until that is done, `IF_a`, `IF_m`, and `assistance share` should
   not be reported.

3. **Splitting `IF` into assisted and manual.** Soukoreff & MacKenzie's `F` class presumes
   a fix is a keystroke. An autocorrect fixes a genuine user tap error with `F = 0`,
   which makes `IF/F` undefined and makes KSPC understate difficulty. The split is
   necessary for an assisted keyboard and is an extension of the 2003 framework, not part
   of it.

4. **Vocabulary-based `INF`.** Precedented in the adaptation literature but not in the
   error-metrics literature. Gaines et al. directly evaluated reference-recovery methods
   for composition tasks and endorsed participant-supplied references, having found even
   crowdsourced judging underestimates true error. Dictionary inference is weaker than the
   method they rejected. This is why every `INF`-dependent metric is reported as a bound,
   and it is the strongest argument for eventually adding a retype step to the protocol.

Departures 1 and 3 are defensible as contributions: extending repair-based intent
recovery beyond backspace-only is precisely the gap the backoff paper names as its own
limitation. Departure 2 is a validation obligation. Departure 4 is a stated limitation.

## Out of scope

- **Tap coordinates.** The stock keyboard exposes none. Recovering them would mean
  extracting ripple positions from the screen recordings — a separate, much larger
  effort. This design yields comparable error *rates*, not spatial distributions.
- **Cross-corpus comparison** against TypingResearch classic/Gaussian numbers. Follow-up,
  once these metrics are trusted.
- **Any change to FreeTypeRecorder** or to the study protocol.
- **`SessionManager.swift:125` positional-accuracy bug.** Real, and it corrupts exported
  TypingResearch data, but it is a TypingResearch defect and belongs in its own change.

## References

- Soukoreff & MacKenzie (2003). Metrics for text entry research: an evaluation of MSD and
  KSPC, and a new unified error metric. *CHI '03*, 113–120. — `C/INF/IF/F` taxonomy and
  the error-rate family. Note its KSPC is `(C+INF+IF+F)/(C+INF+IF)`, which differs from
  the earlier MacKenzie (2002) `keystrokes/|T|`; this design reports both, named
  distinctly.
- Wobbrock & Myers (2006). Analyzing the input stream for character-level errors in
  unconstrained text entry evaluations. *ACM TOCHI* 13(4), 458–489. — all-optimal-
  alignments with fractional weighting; corrected-no-error class; the explicit assumption
  set this design extends beyond backspace.
- Gaines, Kristensson & Vertanen (2021). Enhancing the composition task in text entry
  studies. *CHI '21*. — participant-supplied references beat crowdsourced judging for
  composition tasks. Not adopted here (protocol frozen); the reason `INF` is bounded.
- Alharbi, Stuerzlinger & Putze (2020). The effects of predictive features of mobile
  keyboards on text entry speed and errors. *PACM HCI* 4(ISS), Art. 183. — editing-episode
  definition; autocorrect detection heuristics; precedent that keyboard APIs do not expose
  prediction internals.
- Sivek & Riley (2022). Spatial model personalization in Gboard. *PACM HCI* 6(MHCI),
  Art. 202. — Gaussian spatial personalization at scale; uses proxy metrics (WMR) precisely
  because it has no ground truth.
- Palin, Feit, Kim, Kristensson & Oulasvirta (2019). How do people type on mobile devices?
  *MobileHCI '19*. — population baselines for natural mobile typing behaviour.
