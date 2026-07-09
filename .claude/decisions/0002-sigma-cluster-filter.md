# 0002 — Per-key sigma cluster filter for Gaussian ground truth

- **Status:** proposed (reconstructed from code — confirm with owner)
- **Date:** 2026-06-28
- **Context:** Even after geometric cleaning, a few stray taps remain far from a
  key's main cluster and skew the Gaussian fit used for the adaptive keyboard.
- **Decision:** Offer an optional second pass (`-s / --sigma N`) that flags taps
  more than N std devs from their expected key's cluster mean (mean computed from
  geometrically clean taps only). Suggested range 2.5 (tight) to 3.0 (loose).
- **Rationale:** A distribution-aware filter removes isolated outliers a fixed
  key-width cutoff misses, producing a cleaner Gaussian ground truth.
- **Consequences:** Off by default (geometric flags only). When used, encoded in the
  filename `_s<sigma>` and the `sigma_outlier` flag. Multiple sigma variants exist in
  `csv_threshold_test/` for comparison.
