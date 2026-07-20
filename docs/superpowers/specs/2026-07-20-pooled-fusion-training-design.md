# Pooled + Leave-One-User-Out Training with IMU+Silhouette Fusion

Status: approved by Jimmy 2026-07-20 (Sections 1 and 2 confirmed in
conversation; revised same day to sweep window sizes per mentor guidance
instead of assuming a fixed default — see Evaluation protocol).

## Context

The shipped holding-hand posture model (`Model-Training-Test/models/<participant>/`)
is trained strictly per participant — `train_hand_classifier.py` groups manifest
rows by `participant_key` and fits one model per group. It is IMU-only
(`--imu-seq`): a Conv1D over 50-sample causal windows of the 12-channel IMU
stream, anchored to each labeled frame's timestamp. No model has ever seen
pooled multi-user data, and the camera image pixels are not used by this
model at all — a labeled frame's only role in training is (a) its label and
(b) its timestamp, which locates a 1-second IMU window to train on.

Measured cross-user transfer (`scripts/cross_user_eval.py`, 2026-07-15,
reproduced 2026-07-17): anonymous→jimmy 95.3% frame / 90.4% windowed(15s);
jimmy→anonymous 97.4% / 91.4%. Within-user is near-ceiling (~99.5%/100%).
The gap between within-user and cross-user is the open problem this design
addresses two ways: (1) pool multiple users' data instead of training
per-person, and (2) see whether adding the front-camera silhouette back in
(fused with IMU) closes the gap further, since silhouette shape plausibly
carries user-independent grip cues that a single person's IMU quirks do not.

Two participants currently exist (Anonymous 2,249 frames, Jimmy 1,041
frames, both on iPhone 14 Pro Max — see `.claude/process/
2026-07-15-cross-user-eval.md`). With exactly 2 participants,
leave-one-user-out (LOUO) training reduces to training on the other single
person — mathematically identical to the cross-user numbers already
measured. The pooling question (does training on *multiple* other people's
data generalize better than any one of them alone) cannot be tested until a
3rd participant's export is merged (`scripts/merge_hand_export.sh`). This
design's code does not require that — it produces correct results with 2
participants — but the result is provisional until pooling has ≥2 people to
pool.

Frame capture rate changed 2 → 30 fps during unrelated work on the live
predictor's smoothing (see `.claude/process/
2026-07-17-30fps-imu-capture-vote-retune.md`). This has no effect on
training (the model never sees fps, only per-frame IMU windows), but it
does affect the *windowed accuracy* evaluation metric, whose window has
historically been specified as a raw frame count (`window_size=30`)
calibrated to mean "15 s" at the old 2 Hz rate. Section on evaluation below
fixes this so old-rate and new-rate sessions are scored on equal footing.

This design also carries forward the mentor guidance that already drove the
live-predictor smoothing work: test multiple window sizes, and if windowed
accuracy already beats per-frame accuracy at a small window, prefer the
smaller window over a larger one. That guidance was previously applied only
to the live app's vote window (`dense_window_sweep.py` → 1.5 s); the
evaluation protocol below applies the same sweep-and-select methodology to
this offline pooled/LOUO/fusion metric independently, rather than assuming
the live app's answer transfers. The frame-rate half of the guidance (~30
fps) is already satisfied by the prior work and needs no further changes
here.

## Goals

- Add pooled and leave-one-user-out (LOUO) training/eval modes, for both the
  existing IMU-only model and a new IMU+silhouette fusion model.
- Success criterion: fusion should beat IMU-only on the cross-user/pooled
  metric specifically (fusion is not expected or required to beat IMU-only
  within-user, where IMU-only is already near-ceiling).
- Decision gate: pooled/LOUO windowed accuracy must beat the single-user
  cross-user baseline before a pooled model is exported/shipped (D3/D4 in
  the runbook). This design covers D1 (the code) and produces the numbers
  D2 needs for that gate; shipping the winning model is a later step.

## Non-goals

- **No on-device / live changes.** Fusion is offline-only. The live demo
  (`PosturePredictor.swift`) stays IMU-only Core ML at 30 Hz; feeding camera
  frames into it, or running segmentation on-device, is out of scope. (If
  fusion later proves worth shipping live, that is new design work — Apple
  Vision person-segmentation would replace FCN-ResNet101, which is not
  phone-friendly.)
- **No new data collection is required by this design's code.** More
  participants make the pooling *result* more meaningful (see Context) but
  are not a code dependency.
- **No changes to `train_hand_classifier.py`'s existing per-participant
  training path.** It keeps working exactly as today; pooled/LOUO are
  additive modes.

## Data flow and feature cache

Reuses tested pipeline stages rather than re-implementing them:
`hand_dataset.load_dataset_records` (manifest → records), `preprocess` /
`segment` / `extract_features` from `train_hand_classifier.py` (FCN-ResNet101
→ binary silhouette → VGG16 feature vector — 25088-d, the flattened 7×7×512
conv output; `extract_features()` does not pass through VGG16's FC layers),
and `imu_sequence` for
the per-frame causal 50×12 IMU windows (same as the shipped model).

Segmentation + VGG16 is the only slow stage, so each image's feature vector
is computed once and cached to
`Model-Training-Test/cache/img_features/<image-uuid>.npy`, keyed by the
image's filename (stable across reruns and across which participant's model
is being trained). A cache hit skips torch and keras entirely. Merging a new
participant later only computes that participant's new files. A
`--refresh-cache` flag forces recomputation (e.g. after a segmentation code
change).

**Row eligibility.** Fusion training requires both modalities to be real
data, not filler. A row is **dropped** (not zero-filled), with a per-participant
dropped-row count printed, when either: the image is missing/unreadable, or
its IMU window would be the `imu_sequence` zero-fill fallback (no readable
IMU series for that session). Zero-filling either branch would teach the
fusion head to partially ignore it, which would corrupt exactly the
comparison this design exists to make. The IMU-only baseline computed
*inside the same run* uses this identical filtered row set, so every
fusion-vs-IMU-only comparison in the output table is over identical frames —
apples to apples.

## Fusion model architecture

Feature-level fusion (approach A from the design discussion — chosen over a
trainable end-to-end silhouette CNN, which is more prone to overfitting on
2 participants' worth of data, and over late-probability-fusion, which
tests whether the two signals disagree usefully but does not let them learn
jointly):

- **Image branch:** cached VGG16 feature vector (25088-d paper-faithful, or
  1024-d in the no-keras 32×32-flatten fallback — the branch reads its input
  dimension from the actual cached vectors at run time rather than assuming
  one) → `Dense(128)` projection layer (trainable; image features themselves
  stay frozen — they come from a fixed pretrained backbone).
- **IMU branch:** same Conv1D encoder architecture as the shipped
  `--imu-seq` model, with its softmax head removed — trainable end-to-end,
  producing a ~64-d embedding.
- **Fusion head:** `concatenate([image_128, imu_64])` → `Dense(128, relu)`
  → `Dense(3, softmax)`. Projecting the image vector down to 128 before
  concatenation keeps it from swamping the smaller IMU embedding.
- Trained jointly (image projection + IMU encoder + fusion head all update;
  only the frozen VGG16 backbone itself does not).

## Evaluation protocol

Both models — IMU-only and fusion — get evaluated the same two new ways,
in addition to each script's existing per-participant training:

- **LOUO (leave-one-user-out):** for each participant P, train on every
  *other* participant's train-split (time-ordered 80%, same
  `split_train_eval_indices` convention as today), evaluate on P's full
  data (100% unseen). This is the "new user" number.
- **Pooled:** train one model on all participants' train-splits combined.
  This is the candidate shippable artifact (subject to the decision gate
  passing).

### Time-based windowed accuracy (fixes the 2 Hz calibration)

`windowed_accuracy()` itself (in `train_hand_classifier.py`) is unchanged —
it already takes a plain frame-count `window_size` and stays a generic,
tested utility. What changes is how callers compute that count:

- Windows never cross a session boundary (same rule
  `scripts/dense_window_sweep.py` already established for the live vote
  replay — a session is one IMU CSV / one `imu_path` group).
- For each session, infer its empirical capture rate as the **median
  inter-frame interval** between that session's consecutive labeled frames
  (via `captured_at_iso`) — not a hardcoded 2 or 30. This makes the
  evaluation correct regardless of future capture-rate changes, with no
  further code changes needed.
- A given time window `w` seconds converts to a per-session frame count as
  `round(w / median_dt)`, floor 1.
- `windowed_accuracy()` is called once per session with that session's own
  frame count, then combined into one number as a frame-count-weighted mean
  across sessions (mirrors `dense_window_sweep.py`'s per-session
  accumulation pattern). Sessions with too few frames for even a 1-frame
  window fall back to frame accuracy only for that session's contribution
  (same short-session handling `windowed_accuracy` already has, just
  applied per-session instead of per-participant).

### Window-size sweep, not a fixed default

Per the mentor's guidance (test multiple window sizes; if windowed accuracy
already beats per-frame accuracy at a small window, prefer the smaller
window over a larger one), the pooled/LOUO/fusion eval does **not** assume
a single window. It reports windowed accuracy across a grid of candidate
seconds values — `WINDOW_SECONDS_GRID = [0, 0.1, 0.5, 1.0, 1.5, 3.0, 5.0,
10.0, 15.0]` (0 = per-frame accuracy; 15.0 kept for continuity with the
original 30-frame/2 Hz HandyTrak metric) — for every {model, target} combo,
in the same table-per-window-size shape `window_sweep.py` and
`dense_window_sweep.py` already use.

**Selection rule**, applied per model (IMU-only and fusion get their own
answer, which may differ from each other and from the live app's 1.5 s):
walk the grid from smallest to largest; take the smallest window whose
windowed accuracy is within a small tolerance (0.002, matching
`dense_window_sweep.py`'s precedent) of the best accuracy anywhere in the
grid. This is the same rule already applied once to tune the live
predictor's `voteWindowSize` — applying it here too means the offline
metric's window is *derived from this data*, not assumed from the live
app's unrelated latency/stability trade-off. Report the chosen window
alongside the full grid so the reasoning is auditable, not just the
final number.

`--window-seconds` becomes a grid (or a single override for ad-hoc runs);
existing `--window-size` (raw frame count) stays available for anyone
reproducing the original paper-style 30-frame/2 Hz metric directly.

### Recomputed baseline

The existing single-user cross-user numbers (0.904 / 0.914 windowed) were
measured at the old 30-frame/15 s window and are not directly comparable to
a swept, session-rate-aware metric. Before D2's decision gate is evaluated,
the single-user cross-user baseline is **recomputed across the same
`WINDOW_SECONDS_GRID`** (same session-median-rate logic above) so the gate
compares equivalent quantities at whichever window the selection rule picks.
Concretely: `scripts/cross_user_eval.py` gains the grid sweep and switches
its hardcoded `VOTE_WINDOW = 30` to the per-session time-based computation —
it already loads the trained per-participant models and runs the same A→B
evaluation, so this is a small edit to that script, not a retrain and not
new code elsewhere.

## Decision gate (feeds D2)

Pooled/LOUO windowed accuracy, at each model's own selected window from the
sweep, must beat the recomputed single-user cross-user baseline at its
selected window before a pooled model proceeds to D3 (train final) / D4
(export to Core ML). Separately, fusion is judged against IMU-only on the
identical LOUO split at each model's own selected window: fusion is "worth
it" only if its cross-user/LOUO windowed accuracy beats IMU-only's, on the
same row-eligibility-filtered frames. Within-user numbers are reported for
continuity but do not gate anything (IMU-only is already near-ceiling
there). If the selected windows for IMU-only vs. fusion differ, that
difference is itself worth reporting (e.g. fusion needing less temporal
smoothing would be a second, independent point in its favor beyond raw
accuracy).

## Where the code lives

- **`scripts/train_hand_classifier.py`**: two new flags, `--pooled` and
  `--pooled-louo`, added to the existing per-participant training loop
  (additive — existing per-participant behavior is unchanged when neither
  flag is passed). Produces the IMU-only pooled/LOUO numbers using the
  time-based windowed accuracy above.
- **`scripts/fusion_pooled_train.py`** (new): implements the fusion model
  from scratch with pooled/LOUO as its only modes (no per-participant mode
  — fusion is introduced fresh alongside pooling, so there is no legacy
  per-participant fusion model to preserve). Owns the feature cache and
  row-eligibility filtering described above.
- Both scripts print their own comparison table (frame acc / windowed
  acc(1.5s) / per-participant breakdown), consistent with how
  `cross_user_eval.py` and `window_sweep.py` already self-report — no
  separate combiner script.

## Testing / validation plan

- Unit-level: a small synthetic-data smoke test for the time-based window
  conversion (fixed synthetic inter-frame gaps → known expected frame
  count per grid entry), for the selection rule (synthetic accuracy-by-window
  arrays with a known smallest-within-tolerance answer), and for the
  row-eligibility filter (rows with a missing image or all-zero IMU window
  are dropped, counts match expected).
- Integration: run both new scripts against the real
  `hand_manifest_combined.csv` (2 participants today) end-to-end. The
  concrete regression check is at the **data level, not the accuracy
  level**: with 2 participants, LOUO's train-index set for held-out
  participant X must equal the *other* participant's own train-split
  indices (same `split_train_eval_indices` call the per-participant loop
  already uses), and LOUO's eval-index set for X must equal X's full
  known-label indices — both exactly checkable, deterministic set
  equality, no training involved. Trained *accuracy* will be close to but
  not bit-identical to the existing `cross_user_eval.py` numbers, because
  Conv1D training is stochastic (no fixed random seed anywhere in this
  codebase) — a fresh training run on identical data is not expected to
  reproduce the old run's numbers to the decimal. A large accuracy gap
  (not a small one) on identical index sets means a bug; index-set
  mismatch means a bug in the new grouping/windowing code regardless of
  accuracy.
- Cache correctness: run once, note wall-clock time; run again, confirm
  cache hits (near-zero image-stage time) and identical output numbers.

## Open questions / deferred work

- Live/on-device fusion (Vision-based segmentation, feeding camera frames
  into `PosturePredictor`) — explicitly deferred, see Non-goals.
- A 3rd+ participant's data — not a dependency of this design, but the
  pooling *result* stays provisional (LOUO ≡ single-user cross-user) until
  it exists.
