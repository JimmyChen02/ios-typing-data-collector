# 2026-07-20 — Pooled + LOUO training + IMU/silhouette fusion (D1 implementation)

## What was attempted
Implement the design in docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md:
pooled + leave-one-user-out (LOUO) training for the IMU-only model, a new
IMU+silhouette fusion model with the same modes, and a fix to the windowed-
accuracy metric (was silently calibrated to the old 2Hz/30-frame cadence).
This entry is the real-data verification pass (Task 7): running the finished
tools (Tasks 1-6) against the actual captured dataset
(`Model-Training-Test/hand_manifest_combined.csv`, 3,290 labeled frames,
2 participants: `anonymous|` 2,249 frames / `jimmy|` 1,041 frames) rather
than the demo/synthetic data the unit tests use.

## What was done

**1. `scripts/window_grid.py`** — converts a time window (seconds) to a
per-session frame count from each session's own measured capture rate
(`(last_ts - first_ts) / (n-1)`, not a hardcoded 2Hz/30fps assumption), swept
across `WINDOW_SECONDS_GRID = [0, 0.1, 0.5, 1.0, 1.5, 3.0, 5.0, 10.0, 15.0]`,
with `select_window()` picking the smallest window within 0.002 of the best
accuracy in the grid.

**2. `scripts/cross_user_eval.py`** rewired onto that grid — real-data run
(`.venv-ml/bin/python scripts/cross_user_eval.py`, ~6s wall time, exit 0):

| model → data | condition | n | frame | windowed | sel(s) |
|---|---|---|---|---|---|
| anonymous_ → anonymous_ | SELF held-out 20% | 451 | 1.000 | 1.000 | 0 |
| anonymous_ → jimmy_ | MOCK USER (100% unseen) | 1041 | 0.953 | **1.000** | 10.0 |
| jimmy_ → anonymous_ | MOCK USER (100% unseen) | 2249 | 0.974 | **0.999** | 10.0 |
| jimmy_ → jimmy_ | SELF held-out 20% | 210 | 0.986 | 1.000 | 3.0 |

This is the recomputed baseline referenced below. It confirms the design
doc's Context section: the historical 0.904/0.914 windowed numbers (measured
at the old fixed 30-frame/15s window) were themselves an artifact of that
window's miscalibration once the live app moved to 30fps capture — at a
time-correct window the SAME trained models score 0.999-1.000 windowed.
Nothing was retrained to get this; only the evaluation metric changed.

**3. `scripts/train_hand_classifier.py --pooled --pooled-louo`** — real-data
run (`--imu-seq --imu-causal --imu-window 50 --epochs 30 --pooled
--pooled-louo`, ~22s wall time, exit 0). Per-participant training reproduced
the committed `summary.json` numbers closely (anonymous_: n_train=1798
n_eval=451, test frame=1.000 windowed=1.000; jimmy_: n_train=831 n_eval=210,
test frame=0.986 windowed=1.000).

Pooled: n_train=2629 n_eval=661, frame-acc=0.995, windowed-acc=1.000
(window=3.0s).

LOUO — **index-set regression check, the deterministic part of this task**:

| held_out | n_train | n_eval | frame-acc | windowed-acc | sel(s) |
|---|---|---|---|---|---|
| `anonymous\|` | 831 | 2249 | 0.973 | 1.000 | 10.0 |
| `jimmy\|` | 1798 | 1041 | 0.965 | 0.999 | 5.0 |

`held_out='jimmy|'`'s n_train=1798 exactly equals the committed `anonymous_`
model's own n_train (1,798, `Model-Training-Test/models/summary.json`), and
n_eval=1041 exactly equals jimmy's full known-label frame count. Symmetrically,
`held_out='anonymous|'`'s n_train=831 equals `jimmy_`'s own n_train and
n_eval=2249 equals anonymous's full frame count. **Both hold exactly — PASS.**
The accuracy numbers are close to but not identical to `cross_user_eval.py`'s
(0.973/1.000 vs. baseline's 0.974/0.999, and 0.965/0.999 vs. 0.953/1.000) —
expected, since training is stochastic with no fixed seed anywhere in this
codebase; the gaps are a few tenths of a point on frame-acc, not the large
gap that would indicate a grouping/windowing bug.

**4. `scripts/fusion_pooled_train.py --pooled --pooled-louo`** — real-data
run (`--epochs 30`, first run: **13m50.28s** wall time / 2589.38s user CPU,
exit 0 — this was the first time the real 3,290 images went through
FCN-ResNet101 segmentation + VGG16 feature extraction; no cache existed
beyond 120 unrelated demo-image entries).

`Loaded 3290 records; 3290 eligible (both image and IMU readable), 0 dropped`
— confirms the brief's prediction (every session with any IMU coverage has
full coverage) rather than assuming it. Cached feature vectors verified to
be the real 25088-d paper-faithful VGG16 output (not the 1024-d 32×32-flatten
fallback), spot-checked on 5 random cache files.

Fusion vs. IMU-only, same run, identical filtered rows (n_train/n_eval match
the Step 2 LOUO table exactly: 831/2249 and 1798/1041 — same index-set
regression check, also PASS):

| split | model | n_train | n_eval | frame-acc | windowed-acc | sel(s) |
|---|---|---|---|---|---|---|
| pooled | fusion | 2629 | 661 | 0.985 | 1.000 | 10.0 |
| pooled | imu_only | 2629 | 661 | **1.000** | 1.000 | 0 |
| LOUO held_out=`anonymous\|` | fusion | 831 | 2249 | 0.696 | **0.733** | 10.0 |
| LOUO held_out=`anonymous\|` | imu_only | 831 | 2249 | 0.980 | **1.000** | 5.0 |
| LOUO held_out=`jimmy\|` | fusion | 1798 | 1041 | 0.823 | **0.935** | 15.0 |
| LOUO held_out=`jimmy\|` | imu_only | 1798 | 1041 | 0.918 | **1.000** | 10.0 |

**Fusion did not beat IMU-only cross-user — it lost badly.** See "Errors hit /
gotchas" and "Outcome" below.

**5. Cache-speedup verification** — re-ran the identical command to
`/tmp/fusion_real_rerun/`. `Loaded 3290 records; 3290 eligible (both image
and IMU readable), 0 dropped` matched line-for-line. Wall time dropped to
**51.075s** (205.42s user CPU) — a **~16.3x speedup**, confirming
`cached_image_feature()` is genuinely reading `Model-Training-Test/cache/
img_features/*.npy` on the second run rather than recomputing every time (the
image/segmentation/VGG16 stage is skipped entirely on a cache hit; only the
six Conv1D/fusion `.fit()` calls still ran, since keras training isn't
cached). The rerun's accuracy numbers were close-but-not-identical to the
first run's (e.g. LOUO `anonymous|` fusion windowed 0.771 vs. 0.733,
imu_only windowed 1.000 both times) — same stochastic-training caveat as
above, and the fusion-loses-cross-user pattern reproduced in both runs, so
it is not a one-off unlucky initialization.

## Errors hit / gotchas
- **Headline finding, not a bug**: fusion substantially underperforms
  IMU-only on every cross-user (LOUO) comparison in this run — by 20-27
  windowed-accuracy points held out on `anonymous|`, 6-7 points held out on
  `jimmy|` — despite using genuine 25088-d VGG16 features (confirmed, not
  the degraded fallback) and identical filtered rows to the IMU-only
  comparison trained in the same run. Working hypothesis: the image branch's
  `Dense(128)` projection off a 25088-d input is ~3.2M trainable parameters,
  fit on only 831-1798 rows from a SINGLE training participant in the LOUO
  case — with that little data and that many parameters, the projection
  plausibly memorizes participant-specific visual nuisance (background,
  framing, this-is-anonymous's-hand-not-jimmy's) rather than a
  generalizable grip cue, and that overfit signal actively hurts the fused
  prediction on a genuinely new person. Consistent with this: fusion is
  worse than IMU-only even in the pooled condition (both participants
  represented in training) at frame-acc (0.985 vs 1.000, and 0.977 vs 0.994
  on rerun), though pooled windowed-acc mostly still reaches ceiling because
  errors don't cluster as badly when both users are in-distribution.
- The documented numpy 1.x/2.x `ImportError` spam (pre-existing, unrelated
  to this task) fired heavily on every script that imports keras/tensorflow,
  including repeated retries of the full `tensorflow → keras → pandas →
  pyarrow` import chain during `fusion_pooled_train.py`'s first VGG16 call.
  It resolved itself (subsequent calls used a successfully-cached `keras`
  module) and never affected correctness — confirmed by the 25088-d cache
  spot-check above — but it is worth flagging that this environment's
  `.venv-ml` is picking up `/Applications/anaconda3/lib/python3.12/
  site-packages/pandas` (a system/conda install) rather than a venv-local
  one, which is the actual root cause of the spam; not fixed here since it's
  out of this task's scope and does not affect results.
- No fixed random seed anywhere in this codebase (by design, per the
  testing/validation plan) means real run-to-run frame-acc variance of
  several points on identical index sets — e.g. `train_hand_classifier.py`'s
  own LOUO `jimmy|` imu_only (0.965 frame-acc) vs. `fusion_pooled_train.py`'s
  freshly-trained LOUO `jimmy|` imu_only comparison model on the exact same
  831/1041 split (0.918, then 0.947 on rerun). Windowed accuracy is far more
  stable across these reruns (1.000 in all three cases) than frame accuracy
  is — good independent evidence for why the design prefers windowed
  accuracy as the gating metric.

## Key facts for future agents
- With only 2 participants, LOUO ≡ single-user cross-user transfer
  (mathematically, not just empirically -- see the design doc's Context
  section). The pooling question needs a 3rd participant (Part C,
  scripts/merge_hand_export.sh) to mean anything beyond what
  cross_user_eval.py already measured. Confirmed empirically here: the
  `fusion_pooled_train.py` run's LOUO IMU-only comparison model's
  windowed-acc (1.000 / 1.000, table above under step 4) is a near-exact
  match to cross_user_eval.py's recomputed baseline (0.999 / 1.000) — a
  "close call," as the design doc predicted, not a clear pooling win,
  because with 2 participants the LOUO train set literally IS the
  baseline's training data. (Note: `train_hand_classifier.py`'s own
  separately-trained LOUO IMU-only model, step 3's table, landed at
  1.000 / 0.999 instead of 1.000 / 1.000 — a different model instance
  than either of the two just compared, since training is stochastic
  with no fixed seed anywhere in this codebase; all three numbers are
  real, independently trained models, not one figure copied around.)
- windowed_accuracy()'s window_size is STILL a raw frame count -- unchanged,
  still the right choice for that low-level function. Callers now compute
  the count via scripts/window_grid.py from each session's OWN measured
  capture rate, not a hardcoded 2Hz/30Hz assumption -- this survives any
  future capture-rate change with no further code edits.
- **Fusion (IMU + VGG16 silhouette) currently loses to IMU-only cross-user,
  clearly and reproducibly (two independent training runs agree).** Do not
  assume adding the camera signal back in is a free win — on this dataset
  size it actively hurts generalization to a new person. Before investing
  more here: (a) a 3rd participant would test whether the overfitting
  hypothesis above is specifically a too-little-data problem that pooling
  fixes, or a more fundamental one; (b) regularizing the image branch
  (smaller projection, dropout, or L2 on the Dense(128) weights) untested by
  this run would be the next experiment if fusion is worth revisiting before
  more data exists.

## Outcome
**Fusion decision gate: FAIL on this run.** Per the design doc's Decision
gate section, fusion needed to beat IMU-only's cross-user/LOUO windowed
accuracy on identical filtered rows; instead IMU-only beat fusion by 0.267
(held_out=`anonymous|`) and 0.065 (held_out=`jimmy|`) windowed-accuracy
points, reproduced on a second independent run. Fusion is not recommended
for D3/D4 (final training / Core ML export) at this time.

**Pooled/LOUO IMU-only vs. single-user baseline: essentially a tie**, as
expected given only 2 participants — does not by itself justify shipping a
pooled model yet, and per the design doc this comparison was never expected
to be decisive with only 2 participants.

**Both new code paths (index-set correctness, cache correctness) verified
clean** — the two deterministic regression checks this task exists to run
(LOUO n_train/n_eval equality, cache-hit speedup + identical dropped-row
count) both passed. The accuracy findings (fusion loses cross-user) are a
real, reproducible research result, not a code defect.

**Next steps**: waiting on a 3rd participant's export
(`scripts/merge_hand_export.sh`) before the pooling question is meaningful.
Fusion needs either more data or a smaller/regularized image branch before
it's worth re-testing — do not ship the fusion model as-is.
