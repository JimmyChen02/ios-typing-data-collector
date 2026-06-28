# 0001 — Spatial outlier thresholds

- **Status:** proposed (reconstructed from code — confirm with owner)
- **Date:** 2026-06-28
- **Context:** Raw taps include mistaps, double-registrations, and pauses that would
  distort per-key tap distributions and Gaussian fits.
- **Decision:** Flag (not delete) taps using: normalized tap outside `[-0.5, 1.5]`
  (`spatial`); `dist_from_target_kw` > 1.25 (`far_from_target`); IKI < 50 ms
  (`iki_low`) or > 3000 ms (`iki_high`); plus `trial_start` and `delete_event`.
- **Rationale:** The `[-0.5, 1.5]` / half-key-width bound follows Azenkot & Zhai
  (2012). 1.25 kw is treated as the limit of a plausible neighbor mistap. 50 ms / 
  3000 ms bracket physically implausible double-taps and distraction pauses.
- **Consequences:** Flags are additive columns, so analyses can re-threshold without
  re-running cleaning. `-t` overrides the 1.25 cutoff for sensitivity sweeps
  (see `threshold_analysis.py`, `csv_threshold_test/`).
