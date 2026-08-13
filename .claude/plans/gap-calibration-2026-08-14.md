# Per-session delimiter-gap calibration (deterministic)

## Problem

`DELIMITER_GAP_SPLIT_MS = 9.0` is calibrated on one device / one iOS version.
At study scale (100+ participants, mixed devices), the two latency modes
(~5 ms space-triggered vs ~13 ms bar-tap auto-append) will sit at different
absolute values per device. A hardcoded threshold does not scale; a naive
"widest empty band" splitter is worse — on a session containing only one mode
it splits that single cluster and mislabels half of it.

## Key idea: anchors with label-independent cluster membership

The taxonomy already labels some rows with **certainty independent of timing**,
and the audit shows which timing group they sit in:

- **Low anchors**: non-completion corrections with effect `spelling`/`spacing`
  **and preceding `inter_key_interval_ms` < 250 ms**. The IKI filter is what
  makes this provable rather than assumed: a bar tap on a correction candidate
  (`coler` → tap "cooler" in the bar) has the same string shape but rides the
  high lane, and would poison the low-anchor measurement. A thumb cannot leave
  the key grid and reach the bar in < ~300 ms (corpus bar taps: 573–922 ms),
  so in-rhythm preceding timing *excludes* bar taps with certainty. One-sided
  filter: ambiguous rows (IKI ≥ 250) are dropped from anchors, never guessed.
  (IKI was unsafe as a classifier — 386/717 ms genuine autocorrects exist —
  but is sound as an exclusion filter that only needs one direction.)
- **High anchors**: effect `capitalization`/`contraction`/`punctuation`
  (incl. smart typography) — e.g. `i`→`I` 11.76–15.0 ms, `its`→`it's`. Audit:
  these sit high *regardless of initiator*, so no filter needed. This is an
  empirical claim from one device (causal story unresolved) — recorded as an
  assumption in the ADR; the two-sided ratio guard catches violations whenever
  low anchors coexist.

Anchor rows are classified by *shape* (plus the one-sided IKI exclusion),
never by their own gap — so calibrating the threshold from anchors and
applying it only to completions is a clean DAG, no circularity. Manual
overtypes are excluded (rule 1 catches them first and their following
keystroke is human).

## Calibration cascade (first match wins; all pure arithmetic, no RNG)

Let `L` = anchor-low gaps, `H` = anchor-high gaps (gap defined ≤ 200 ms only).

1. **anchored** — `len(L) ≥ 2 and len(H) ≥ 2 and min(H)/max(L) ≥ 1.4`:
   `grey = [max(L), min(H)]`, `threshold = sqrt(max(L) * min(H))`
   (geometric midpoint — latencies are multiplicative).
2. **anchored_high** — `len(H) ≥ 2`: `threshold = min(H)/1.4`,
   `grey = [min(H)/1.4, min(H)]`. Mechanistic margin: the two modes differ by
   ~2× (5 vs 13 ms); 1.4 is a safety factor inside that.
3. **anchored_low** — `len(L) ≥ 2`: `threshold = max(L)*1.4`,
   `grey = [max(L), max(L)*1.4]`.
4. **otsu** — no usable anchors: exact 1-D two-cluster split on log-gaps of
   ALL defined gaps (try every split point on the sorted list, maximise
   between-class variance; first maximum wins — deterministic tie-break).
   Accept only if ≥ 8 points, ≥ 3 per cluster, and cluster-edge ratio ≥ 1.4;
   otherwise it is not credibly bimodal.
5. **global** — fall back to the constants (9.0, grey 7–12), flagged.
   Also used, flagged as `global_conflict`, when two-sided anchors exist but
   overlap (ratio < 1.4) — that session contradicts the latency story and must
   surface, not silently classify.

Confidence: gap inside `[grey_lo, grey_hi]` (inclusive) → `grey_zone`; else
side by `gap >= threshold`. Low side keeps `grey_zone` regardless (the
inline-prediction-vs-autocorrect branch stays uncalibrated — unchanged).

## Determinism guarantees

- No RNG, no dict-order dependence (all reductions over sorted lists or
  min/max), fixed tie-break in the Otsu scan, pure float arithmetic on the
  same inputs → identical output on every run and platform.
- Every session records how it was calibrated: summary gains
  `gap_threshold_ms`, `gap_calibration` (anchored|anchored_high|anchored_low|
  otsu|global|global_conflict), `gap_low_anchors`, `gap_high_anchors`.
  No session silently rides a wrong constant.

## Acceptance

- test1/test2 must reproduce today's committed labels and confidences exactly
  (expected modes: test1 anchored or anchored_high, test2 anchored_high — it
  has one low anchor only).
- Unit tests per cascade arm: two-sided anchors; high-only; low-only;
  single-cluster session (all-low, no high anchors → completion at 1.5×max(L)
  goes high, completion inside the cluster stays low); otsu bimodal;
  otsu rejects unimodal; global fallback; conflict flag.

## Files

`scripts/substitution_metrics.py` (calibration + summary fields),
`tests/test_substitution_metrics.py`, `.claude/decisions/0004-gap-calibration.md`,
`.claude/data-dictionary.md` (summary columns), `scripts/CLAUDE.md`,
process-log entry, regenerated `processed-keystrokes/` summaries.
