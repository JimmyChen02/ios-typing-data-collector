# 2026-07-21 — Fusion model dropout experiment (follow-up to D1)

## What was attempted
`.claude/process/2026-07-20-pooled-fusion-training.md` found the IMU+
silhouette fusion model losing badly to the IMU-only model on the
decision-relevant cross-user (LOUO) metric, and named a specific,
falsifiable hypothesis: the fusion head's `Dense(128)` image projection
(~3.2M trainable parameters, off a 25088-d frozen VGG16 input) had NO
dropout anywhere in the image path or fusion head, unlike the IMU branch
(`Dropout(0.5)`) and unlike `train_hand_classifier._train_handynet`'s head
(`Dropout(0.5)`) — a classic overfit setup on as few as 831 training rows
from a single participant (the LOUO case). This entry tests that hypothesis
directly: add `Dropout(0.5)` after the image projection and after the
fusion head's `Dense(128)` (same rate already used everywhere else in this
codebase, not a new hyperparameter), re-run `--pooled --pooled-louo` on the
real dataset, and compare.

## What was done
1. Added a regression test (`tests/test_pooled_fusion.py::TestFusionModel::
   test_build_fusion_model_regularizes_image_branch_and_head`) asserting the
   model has 3 `Dropout(0.5)` layers (was 1) and that the image projection's
   output specifically flows through one before reaching the `Concatenate` —
   confirmed RED before the change, GREEN after.
2. `scripts/fusion_pooled_train.py::build_fusion_model()`: added
   `Dropout(0.5)` immediately after `image_projection` and immediately after
   the fusion head's `Dense(128)`, before the final softmax. Docstring
   updated to state the rationale and cite this experiment.
3. Full `tests/test_pooled_fusion.py` suite: 35/35 pass (34 previous + 1 new).
4. Real-data run (`.venv-ml/bin/python scripts/fusion_pooled_train.py
   Model-Training-Test/hand_manifest_combined.csv --images-root
   Model-Training-Test/ --out /tmp/fusion_dropout_test/ --pooled
   --pooled-louo --epochs 30`, 55.4s wall time — fast because the VGG16
   feature cache was already warm from the prior verification run).

## Results — before (no dropout, 2026-07-20 entry) vs. after (this run)

| split | model | frame-acc (before → after) | windowed-acc (before → after) |
|---|---|---|---|
| pooled | fusion | 0.985 → **0.995** | 1.000 → 1.000 |
| pooled | imu_only | 1.000 → 0.997 | 1.000 → 1.000 |
| LOUO held_out=`anonymous\|` | fusion | 0.696 → **0.927** | 0.733 (0.771 on rerun) → **0.955** |
| LOUO held_out=`anonymous\|` | imu_only | 0.980 → 0.983 | 1.000 → 1.000 |
| LOUO held_out=`jimmy\|` | fusion | 0.823 → **0.921** | 0.935 → **1.000** |
| LOUO held_out=`jimmy\|` | imu_only | 0.918 → 0.959 | 1.000 → 1.000 |

(imu_only's own numbers moved slightly too — expected, no fixed random seed
anywhere in this codebase, same caveat as every other run in this project.)

**The overfitting hypothesis is confirmed.** Dropout alone — no new data,
no architecture change beyond adding two `Dropout(0.5)` layers — closed the
LOUO windowed-accuracy gap from 0.267/0.229 down to 0.045 (`anonymous|`
held out) and from 0.065 down to 0.000 (`jimmy|` held out, fusion now ties
IMU-only exactly). Frame accuracy improved substantially in both LOUO cases
(+0.231 and +0.098) but fusion still trails IMU-only there (0.927 vs 0.983,
0.921 vs 0.959) — windowed accuracy's majority-vote smoothing is doing real
work to close that remaining frame-level gap, not just reporting noise.

## Outcome
**Fusion decision gate: still not a clean win on frame accuracy, but the
windowed (decision-relevant) gap is now small-to-zero.** This is enough to
change the recommendation from "do not ship, needs more data or
regularization" to "worth continuing to invest in" — but not yet enough to
call it a win outright, since:
- Frame-accuracy still trails IMU-only in both LOUO splits, meaning fusion's
  advantage (if real) is currently coming from the same temporal-smoothing
  effect windowed accuracy always provides, not from the model itself being
  more accurate frame-by-frame.
- Still only 2 participants — every caveat from the 2026-07-20 entry about
  LOUO≡single-user-cross-user with n=2 still applies unchanged.

**Next steps, in priority order:**
1. A 3rd participant's data is now more valuable than before this
   experiment — with dropout working as hypothesized, more data is exactly
   what a regularized-but-still-data-hungry ~3.2M-parameter branch needs
   next, and it would also make the pooling question itself meaningful for
   the first time.
2. If a 3rd participant isn't available soon, cheap follow-up experiments on
   the existing 2-participant data: try a stronger dropout rate (e.g. 0.6-
   0.7) on the image branch specifically, or reduce the image projection's
   width below 128 (fewer parameters = less to overfit) before assuming
   0.5/128 is the ceiling of what regularization alone can do.
3. Not yet warranted: shipping this to D3/D4 (final training / Core ML
   export) — that decision should wait for either more data or a
   frame-accuracy result that closes the remaining gap, not just the
   windowed one.

## Files touched
- `scripts/fusion_pooled_train.py` (build_fusion_model: +2 Dropout layers)
- `tests/test_pooled_fusion.py` (+1 test)
