# Holding-Hand Model — Results Log

**How to train:** the quick retrain pipeline lives below (`Retrain pipeline`
section); the long-form guide is still [`README.md`](README.md) in this folder.

This file records training results only:
- the **auto-generated block** below keeps the single best run (written by
  `train_hand_classifier.py --md-out Model-Training-Test/model.md`);
- the **manual log** at the bottom gets one entry per run — add date/time,
  command variant, data, and the held-out numbers after every training run.

## Retrain pipeline (verified, repo root)

1. Merge a new app export zip:
   ```
   bash scripts/merge_hand_export.sh ~/Downloads/hand_export_<name>.zip
   ```
   Note it lands a provenance copy under `Model-Training-Test/exports/`,
   appends rows to `hand_manifest_combined.csv`, copies `hand_images/` +
   `imu/`, and refuses double-merges.

2. Train:
   ```
   .venv-ml/bin/python scripts/train_hand_classifier.py \
       Model-Training-Test/hand_manifest_combined.csv \
       --images-root Model-Training-Test/ \
       --out Model-Training-Test/models/ \
       --imu-seq --imu-causal --imu-window 50 --epochs 30
   ```
   Note: use ≥30 epochs (10 is unstable); `--imu-causal` is required for
   live-use export.

3. Check `Model-Training-Test/models/summary.json` —
   `handynet_windowed_acc` is the headline metric. The model lands at
   `Model-Training-Test/models/<participant_slug>/hand_model.keras` +
   `labels.json`.

4. Export to Core ML (output MUST be repo-root `posture_imu.mlpackage` —
   that is the exact resource the Xcode project bundles and
   `PosturePredictor` loads by name):
   ```
   .venv-ml/bin/python scripts/export_imu_coreml.py \
       --model Model-Training-Test/models/<slug>/hand_model.keras \
       --labels Model-Training-Test/models/<slug>/labels.json \
       --window 50 \
       --out posture_imu.mlpackage
   ```
   Success requires the export to print `Classes: ['both', 'left', 'right']`.

5. Rebuild the app and verify on the Live Posture Demo screen:
   ```
   xcodebuild -scheme TypingResearch \
       -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.3.1' build
   ```
   Per repo convention, update `build_log.md` for this build.

**Gotchas:**
- numpy 1.x/2.x `ImportError` spam from the anaconda base leaking through
  `--system-site-packages` is HARMLESS (optional pandas/pyarrow/numexpr/
  bottleneck probes). Success markers are `[PAPER-FAITHFUL] ... importable`
  and `Core ML model saved`. Optional silence:
  `.venv-ml/bin/pip install pandas pyarrow numexpr bottleneck`.
- No normalization between train and serve — raw IMU windows both sides.

The auto-generated "best run" block below is image-era and does not reflect
the currently shipped IMU model (the 2026-07-07 100% windowed run in the
manual log is what ships).

<!-- TRAIN_RESULTS_START -->
<!-- BEST_WINDOWED_ACC=1.000000 -->
## Best training run so far (auto-generated)

_Generated 2026-07-09 17:08 UTC by `train_hand_classifier.py` (mode=handynet, epochs=30, imu=off). This section keeps the BEST run (highest mean held-out windowed accuracy); it is overwritten only when a later run beats it._

| Participant | n_train | n_eval | Train acc | Test frame acc | Test windowed acc | Centroid |
|---|---|---|---|---|---|---|
| anonymous| | 1798 | 451 | 0.999 | 1.000 | 1.000 |    nan |
| jimmy| | 831 | 210 | 1.000 | 0.990 | 1.000 |    nan |
| **MEAN** | 2629 | 661 | 0.999 | 0.995 | 1.000 |    nan |

**Headline — held-out windowed test accuracy: 100.0%**  ·  test frame acc 99.5%  ·  centroid baseline nan

**anonymous| — per-class test accuracy:** both=1.000, left=1.000, right=1.000
**anonymous| — confusion (true→pred):** both->both:150, left->left:150, right->right:151

**jimmy| — per-class test accuracy:** both=1.000, left=1.000, right=0.971
**jimmy| — confusion (true→pred):** both->both:70, left->left:70, right->both:2, right->right:68

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
