# 2026-07-21 — Fusion pooled/LOUO retrain on full merged dataset (20,236 frames)

## What was attempted
Following the Jimmy re-capture merge (`.claude/process/2026-07-21-jimmy-recapture-merge.md`,
grew `hand_manifest_combined.csv` from ~2,249 to 20,236 frames: Anonymous
2,249 / Jimmy 17,987) and the dropout fix
(`.claude/process/2026-07-21-fusion-dropout-experiment.md`), user ran the
full pooled + LOUO retrain themselves using the new tqdm progress bar added
to `eligible_records()`:

```
.venv-ml/bin/python scripts/fusion_pooled_train.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out /tmp/retrain_after_merge/fusion/ \
    --pooled --pooled-louo --epochs 30
```

Caching stage: 34m19s to go from 11,628 cached images to all 20,236 eligible
(0 dropped) — matches the previously measured ~250 img/min single-image
caching rate. Progress bar worked as intended (live `cached=/kept=/dropped=`
counters visible throughout).

## Results

| split | model | n_train | n_eval | frame-acc | windowed-acc | window |
|---|---|---|---|---|---|---|
| pooled | fusion | 16,187 | 4,049 | 1.000 | 1.000 | 0s |
| pooled | imu_only | 16,187 | 4,049 | 1.000 | 1.000 | 0s |
| LOUO held_out=`anonymous\|` | fusion | 14,389 | 2,249 | 0.926 | 0.935 | 3s |
| LOUO held_out=`anonymous\|` | imu_only | 14,389 | 2,249 | 0.928 | 0.944 | 5s |
| LOUO held_out=`jimmy\|` | fusion | 1,798 | 17,987 | 0.951 | 0.986 | 15s |
| LOUO held_out=`jimmy\|` | imu_only | 1,798 | 17,987 | 0.934 | 0.986 | 10s |

Models saved under `/tmp/retrain_after_merge/fusion/{fusion,imu_only}_{pooled,louo_anonymous,louo_jimmy}/hand_model.keras` + `labels.json` each. **This is `/tmp` — not durable across reboots; copy out if these should be kept.**

## Interpretation

**Pooled hit its ceiling (1.000/1.000, both models).** Expected, not a new
leakage bug: pooled evaluates each participant against their own
LATER-IN-TIME 20% split (see `split_train_eval_indices`'s time-ordered,
per-condition split) — same participant, same session characteristics, just
a different time slice. The code's own comment on this
(`fusion_pooled_train.py` around `participant_splits`) already flags this as
a "continuity number, not literally unseen." With only 3 well-separated
posture classes and a consistent per-participant IMU/visual signature, this
task saturates easily within-participant.

**LOUO (the decision-relevant, genuinely-unseen-user number) held up well** —
92.6-95.1% frame accuracy, 93.5-98.6% windowed accuracy across both held-out
participants and both model types. This continues to validate the dropout
fix from the prior entry: fusion is no longer losing badly to IMU-only
cross-user (it's now essentially competitive, and wins frame-accuracy
outright when Jimmy is held out: 0.951 vs 0.934).

**Notable: held_out=`anonymous|` windowed-acc did NOT improve despite ~17x
more Jimmy training data** (14,389 train rows now vs a much smaller Jimmy
set in the pre-merge dropout-experiment entry) — 0.935 now vs 0.955
(fusion) / 0.944 now vs 1.000 (imu_only) then. This matches the
already-documented 30fps-capture-density finding: near-duplicate consecutive
frames within a burst don't contribute proportionally independent
information, so raw frame-count growth from denser capture doesn't
translate into proportional accuracy gains. Not a regression to chase —
consistent with prior evidence, not new evidence of a problem.

## Non-fatal noise observed during the run
Repeated `ImportError: ... NumPy 1.x cannot be run in NumPy 2.4.6` tracebacks
fired during the caching stage, tracing into
`/Applications/anaconda3/lib/python3.12/site-packages/{pandas,pyarrow,numexpr,bottleneck}`
— i.e. imports resolving to the **Anaconda base env**, not `.venv-ml`,
for `pandas`'s optional accelerators (`numexpr`, `bottleneck`). These are
caught internally by pandas' `import_optional_dependency(..., errors="warn")`
and are non-fatal (confirmed: the run completed all 6 pooled/LOUO models
successfully). Cosmetic/log-noise only, but indicates `.venv-ml` is not
fully isolated from the Anaconda base install for these two optional
pandas deps. Not investigated further — didn't block this run. Follow up
only if it starts affecting real behavior (or gets noisier).

## Outcome
**Full-dataset pooled+LOUO retrain complete, 6 models saved.** Cross-user
generalization (LOUO) remains strong post-merge, consistent with the
dropout-fix result. No new action required immediately; next steps are
whatever the user decides based on these numbers (e.g., promote LOUO models
out of `/tmp`, chase the anaconda-leakage import noise, or gather more
data from additional participants if pooling is ever to become meaningful
with >2 people).
