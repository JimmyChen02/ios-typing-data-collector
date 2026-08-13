# 0004 — Per-session delimiter-gap calibration

Date: 2026-08-14
Status: accepted

## Context

ADR 0003's `suggestion_bar` rule splits completion substitutions on the
trailing delimiter gap at a fixed 9 ms. The two latency modes (~5 ms
space-triggered, ~13 ms bar-tap auto-append) were measured on one device and
one iOS version; at study scale (100+ participants, mixed devices) their
absolute values will drift, and a fixed threshold misclassifies entire
sessions at once. A naive per-session "widest empty band" splitter is worse:
on a session containing only one mode it splits that single cluster in half.

## Decision

Re-derive the split per session from **anchor rows whose timing group is
known from non-timing evidence**, so the threshold is measured on the same
device/OS/build that produced the ambiguous rows. Deterministic cascade
(`_calibrate_gap_split`): two-sided anchors → one-sided anchors with the
mechanistic ~2× separation margin (factor 1.4) → exact 1-D Otsu on log-gaps
with a bimodality guard (≥8 points, ≥3 per cluster, edge ratio ≥1.4) →
global constants. Summary records `gap_threshold_ms`, `gap_calibration`
mode, and anchor counts — no session rides a wrong constant silently.

- **Low anchors**: `spelling`/`spacing` corrections with preceding
  `inter_key_interval_ms` < 250 ms. The IKI filter is what makes them
  provable: a bar-tap spelling fix (`coler` → tap "cooler") has identical
  string shape but rides the high lane; a thumb cannot reach the bar in
  < ~300 ms (corpus bar taps 573–922 ms), so in-rhythm timing *excludes* it.
  One-sided use only — IKI failed as a classifier (genuine autocorrects at
  386/717 ms) but is sound as an exclusion.
- **High anchors**: `capitalization`/`contraction`/`punctuation` corrections;
  the audit shows they sit high regardless of initiator, so no filter.
- Completions and manual overtypes never anchor; anchors are labelled by
  string shape, never by their own gap — calibration → classification is a
  DAG, no circularity.
- Anchors that overlap (two-sided ratio < 1.4) contradict the latency story:
  fall back to constants **flagged `global_conflict`**, never silently.

Determinism: no RNG, all reductions over sorted lists or min/max, fixed
first-maximum tie-break in the Otsu scan; same input → same output anywhere.

## Assumptions recorded

- A1: the two latency modes differ by ≥ ~1.4× on every device (observed 2.25×
  on the corpus device). The one-sided anchor rules lean on this.
- A2: capitalization/contraction/punctuation corrections sit in the high mode
  on all devices. Empirical from one device (causal story still unresolved);
  violations surface as `global_conflict` whenever low anchors coexist, and
  the deliberate labelled trial remains the way to settle it.

## Acceptance (verified 2026-08-14)

test1/test2 reproduce their committed labels byte-identically. test1
calibrates `anchored` (2 low / 4 high anchors, threshold 8.400 ms); test2
`anchored_high` (its only spelling fix is a single low anchor, threshold
8.751 ms). 42 tests cover every cascade arm, the bar-tap-fix anchor
exclusion, and the single-cluster session that motivated the design.
