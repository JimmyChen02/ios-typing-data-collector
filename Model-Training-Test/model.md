# Holding-Hand Model — Results Log

**How to train:** see [`README.md`](README.md) in this folder (simple steps:
setup → export data → train → export Core ML → bundle).

This file records training results only:
- the **auto-generated block** below keeps the single best run (written by
  `train_hand_classifier.py --md-out Model-Training-Test/model.md`);
- the **manual log** at the bottom gets one entry per run — add date/time,
  command variant, data, and the held-out numbers after every training run.

<!-- TRAIN_RESULTS_START -->
<!-- BEST_WINDOWED_ACC=0.836650 -->
## Best training run so far (auto-generated)

_Generated 2026-07-01 16:11 UTC by `train_hand_classifier.py` (mode=both, epochs=2). This section keeps the BEST run (highest mean held-out windowed accuracy); it is overwritten only when a later run beats it._

| Participant | n_train | n_eval | Train acc | Test frame acc | Test windowed acc | Centroid |
|---|---|---|---|---|---|---|
| jimmy|chen | 439 | 111 | 0.866 | 0.649 | 0.805 | 0.333 |
| tran| | 416 | 105 | 0.974 | 0.914 | 0.868 | 0.562 |
| **MEAN** | 855 | 216 | 0.920 | 0.781 | 0.837 | 0.448 |

**Headline — held-out windowed test accuracy: 83.7%**  ·  test frame acc 78.1%  ·  centroid baseline 44.8%

**jimmy|chen — per-class test accuracy:** both=0.405, left=0.541, right=1.000
**jimmy|chen — confusion (true→pred):** both->both:15, both->left:14, both->right:8, left->both:8, left->left:20, left->right:9, right->right:37

**tran| — per-class test accuracy:** both=1.000, left=1.000, right=0.743
**tran| — confusion (true→pred):** both->both:35, left->left:35, right->both:9, right->right:26

_Train acc = in-sample; Test = held-out 20% (time-ordered split); windowed = sliding-window-30 majority vote (HandyTrak metric); Centroid = zero-training baseline._
<!-- TRAIN_RESULTS_END -->

---

## Results log (all runs, newest first)

Manually maintained — unlike the auto-generated "best run" block above, every
run gets an entry here.

### 2026-07-07 14:25 — IMU-seq causal, 30 epochs ← current bundled model
- Data: `hand_export_Anonymous_` — 379 frames (127 L / 128 R / 124 both), 302 train / 77 eval
- Command: `--imu-seq --imu-causal --imu-window 50 --epochs 30` (re-run of the 14:10 recipe)
- **TEST frame-acc 1.000 · windowed-acc 1.000** · all classes perfect
- Exported to `posture_imu.mlpackage` and added to the Xcode project (repo root) — this exact model ships in the app bundle.

### 2026-07-07 14:10 — IMU-seq causal, 30 epochs
- Data: `hand_export_Anonymous_` — 379 frames (127 L / 128 R / 124 both), 302 train / 77 eval
- Command: `--imu-seq --imu-causal --imu-window 50 --epochs 30`
- **TEST frame-acc 0.974 · windowed-acc 1.000** · train 0.993
- Per-class: both=1.000, left=0.923, right=1.000 (confusion: left→right ×2, rest perfect)
- Exported to `posture_imu.mlpackage` (input `imu_window`, outputs `classLabel`/`classProbability`) — this is the model bundled for live on-device prediction.

### 2026-07-07 14:06 — IMU-seq causal, 10 epochs (re-run)
- Same data/command as 2026-07-06 run below.
- TEST frame-acc 0.740 · windowed-acc 0.479 · train 0.629; per-class right collapsed to 0.385.
- Lesson: at 10 epochs the small Conv1D is highly sensitive to random initialization — identical command, wildly different result than the day before. Use ≥30 epochs.

### 2026-07-06 — IMU-seq causal, 10 epochs (first real IMU run)
- Data: `hand_export_Anonymous_` — 379 frames (127 L / 128 R / 124 both), 302 train / 77 eval
- Command: `--imu-seq --imu-causal --imu-window 50 --epochs 10`
- TEST frame-acc 1.000 · windowed-acc 1.000 · train 0.980; all classes perfect.
- Also surfaced + fixed two Core ML export bugs (input name `input_layer`→`imu_window`; probability output `classLabel_probs`→`classProbability`).

### 2026-07-01 16:11 UTC — Image HandyNet, 2 epochs (best image run, see auto block)
- Data: Jimmy 439/111 + Tran 416/105 frames (front-camera photos)
- Command: `--mode both --epochs 2` (image pipeline)
- Jimmy: TEST frame 0.649 · windowed 0.805 (weak on both/left) · Tran: frame 0.914 · windowed 0.868
- Mean windowed 0.837 vs centroid baseline 0.448.

### (earlier) — Image HandyNet, 2 epochs (first real run, single participant)
- Data: `jimmy|chen` only (iPhone 14 Pro Max) — 520 frames balanced (174 both / 174 left / 173 right), 414 train / 105 eval
- Command: `--mode both --epochs 2` (image pipeline)
- TEST frame-acc 0.771 · **windowed-acc 0.829** · centroid baseline 0.333 (collapsed to predicting "both")
- Reading: the CNN beat the zero-training geometric baseline by ~50 points — real signal, not a geometric trick; in the ballpark of HandyTrak's ~89% (which used far more data + tuning).

_Held-out = last 20% of frames per class in capture order (time-ordered split, no shuffle). Windowed = 30-frame sliding majority vote. Within-user only — cross-user generalization not yet measured._

---

## Next steps (rough priority)

1. **Prove it generalizes — add participants.** Collect 2–4 more people and
   retrain (one model each); a consistent average across people is what makes
   the result defensible.
2. **The research payoff — connect the two halves.** Use the holding-hand
   prediction to select a **per-hand Gaussian keyboard**: grip changes thumb
   reach → changes tap distribution → the optimal Gaussian key boundaries
   differ by hand. (Requires holding-hand labels during typing — a future
   increment.)
