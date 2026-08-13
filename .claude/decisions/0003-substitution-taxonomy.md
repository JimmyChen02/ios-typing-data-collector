# 0003 — Substitution taxonomy: orthogonal axes, trailing-gap source rule

Date: 2026-08-13
Status: accepted

## Context

`substitution_metrics.py` labelled every `replace`/`paste` row with one flat
enum, `substitution_kind`. Three defects, all confirmed against
`sessions_raw/Tran_test2_*.csv` and a screen recording:

1. **`quicktype_pick` could never fire.** Its rule assumed a bar tap has no
   following delimiter keystroke. False: iOS auto-appends a space after a
   candidate tap, logged as its own `insert` row ~13 ms later,
   shape-identical to a typed space. Every confirmed bar tap
   (`act`→`actually`, `prett`→`pretty`, `wea`→`weather`) fell through to the
   completion test and mislabelled as `inline_prediction`. Zero
   `quicktype_pick` rows existed in the corpus.
2. **One slot answered two questions.** Who initiated the change
   (`quicktype_pick`, `manual_overtype`) competed with what changed
   (`sentence_caps`, `smart_punct`), so one uncertain mechanism inference
   poisoned the whole label.
3. **`sentence_caps` was misnamed.** `autocapitalizationType = .sentences`
   pre-shifts the keyboard and inserts the capital directly; it cannot emit a
   `replace`. A case-only replace (`i`→`I`, `Lol`→`lol`) *is* the autocorrect
   engine, differing from `coler`→`cooler` only in effect.

## Decision

Split into orthogonal columns: `substitution_source` (+ confidence),
`substitution_effect`, `substitution_outcome` (+ `revert_latency_ms`), with
`substitution_kind` kept as a derived alias. Effect and outcome are certain
(pure string function; edit-script replay), so they stay clean even where
source inference is shaky — a single flat label cannot degrade gracefully,
orthogonal ones can.

### Why the trailing delimiter gap, not the 350 ms preceding IKI

The first draft separated `suggestion_bar` from the space-triggered pair by
the *preceding* inter-key interval (bar taps measured 573/591/922 ms,
autocorrects 95–166 ms; threshold 350 ms). The 2026-08-13 touch-capture audit
found a stronger signal and a direct contradiction:

- The **trailing** gap (replace row → following delimiter `insert`) is iOS's
  internal latency on two different code paths: ~5 ms when a typed delimiter
  triggered the change, ~13 ms when the system auto-appends the space after a
  bar tap. Across all 19 corpus substitutions the groups are 4.3–6.6 ms and
  11.8–15.0 ms with an empty band between. Machine timing beats a threshold
  fitted to human reaction time on n=3.
- The rules disagree on real rows: `read`→`reading` (preceding 386 ms →
  bar tap under IKI; trailing 5.59 ms → space-triggered). The IKI rule would
  have shipped that mislabel.

Constants: `DELIMITER_GAP_SPLIT_MS = 9.0`, `GAP_GREY_ZONE_MS = (7.0, 12.0)`
(brackets the empty band; corpus extremes 6.58 and 11.76). Gaps inside the
band get `grey_zone` confidence — review against video, don't trust silently.

### Why the gap applies only to completions

The high group also contains plain autocorrects (`i`→`I`, `its`→`it's`,
`Lol`→`lol`) — the causal story for *corrections* is not resolved, so a high
gap on a correction must not read as a bar tap. Completions (`_extends`) are
the only shape where bar tap, inline prediction and autocorrect overlap;
inside that branch the split is clean. Corrections are classified by shape
alone as `autocorrect_engine`.

### Why `marked_text_before` was demoted to a hint

It is 0 on **every** substitution row ever recorded — it clears before
`shouldChangeTextIn` runs. It fires on mid-word `insert` rows (21 across both
sessions), a word-level "candidate was pending" signal, off by a few rows.
Keeping it as a certain per-row rule would repeat the `quicktype_pick`
mistake: a provably dead branch labelled trustworthy. As a word-level hint it
splits the low-gap completion residue (hint → `inline_prediction`, else
`autocorrect_engine`, both `grey_zone`).

## Known limitations — stated, not papered over

- **n=3 ground truth, one device, one iOS version.** The 5/13 ms split is an
  empirical latency; it may shift across devices/OS versions. Every row ships
  `next_delimiter_gap_ms` so the rule can be re-checked and recalibrated. The
  deliberate labelled trial (`teh`+space, `tomo`+ghost-text-space,
  `tomo`+bar-tap, select-and-overtype, ~10× each hand) remains the way to
  nail the causal story; it has not been run.
- **No confirmed inline prediction exists in the corpus.** The low-gap
  completion branch (steps 4/5) is uncalibrated either way — hence permanent
  `grey_zone`.
- **Bar-tap corrections are invisible.** Tapping "the" in the bar after
  typing `teh` is a correction shape and lands in `autocorrect_engine`; the
  gap rule is deliberately not applied there.
- **Effect is single-valued, first match wins.** `I ask`→`i asked` is both a
  case change and a completion; it labels `completion`.
- **Outcome replay can hit real capture gaps.** Tran_test1 row 167: iOS
  retracted an auto-inserted space with no delegate callback, so replay
  diverges mid-session. Outcomes resolved before the gap are kept; later
  spans stay unlabelled because `kept` cannot be certified without a full
  replay. While marked text is pending, `resulting_text_length` includes the
  uncommitted candidate and is exempt from the divergence check.
