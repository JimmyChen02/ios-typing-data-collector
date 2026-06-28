# Glossary

Shared vocabulary for the TypingResearch project.

- **Trial** — one prompted typing task (8 random words). 15 trials per session.
- **Session** — one sitting of 15 trials, run in a single keyboard mode.
- **Study design** — the ordering of session modes across the study:
  `classic + adaptive` (first half classic, second half Gaussian trained on the
  classic data) or `classic only`.
- **Classic keyboard** — fixed rectangular key hit-regions (the baseline).
- **Gaussian / adaptive keyboard** — per-key probabilistic hit-regions fit from a
  user's own taps; a tap maps to the key with the highest probability.
- **Key-width (kw)** — distance unit = one key's width; used for `dist_from_target_kw`.
- **Tap (touch) coordinate** — where the finger landed; `tap_local_*` is in the hit
  key's frame, `tap_norm_*` is that normalized to `0..1` of key size.
- **Outlier flag** — a reason a tap is suspect (see data-dictionary.md). Flagging
  never deletes the row; downstream analyses choose what to drop.
- **Gaussian fit** — per-key 2D Gaussian: mean `muX/muY` + inverse-covariance
  `pxx/pxy/pyy`. Stored in-app at `Documents/gaussian_taps.json`.
- **Mahalanobis distance** — covariance-aware distance from a tap to a key center;
  decides Gaussian-key membership and defines the boundary.
- **Gaussian boundary** — the set of per-key decision regions from the fit; the
  visible "shape" of the adaptive keyboard.
- **Ground-truth boundary** — the Gaussian boundary fit from ALL trials; treated as
  the target the model converges toward.
- **Trial loss / ground-truth loss** — how much a boundary fit from the first N
  trials differs from the ground-truth boundary; measures how many trials are
  needed before the model stabilizes.
- **Key backoff** — fallback when a key has too few taps: fitted → borrowed (from a
  neighbor) → geometry (classic rect). Reported by `key_backoff_report.py`.
