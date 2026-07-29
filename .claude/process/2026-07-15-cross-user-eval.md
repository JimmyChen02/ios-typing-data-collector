# 2026-07-15 — Cross-user ("mock user") eval + shipped-model provenance

## What was attempted
Question from Jimmy: how much data is the hand model trained on, how accurate
is it, and how good is classification on a user it never saw ("mock user")?

## What was done
1. **Dataset census** — `hand_manifest_combined.csv` has 3,290 labeled frames
   (Anonymous 2,249: 746 both / 748 left / 755 right; Jimmy 1,041: 348/346/347).
   Both participants captured on iPhone 14 Pro Max.
2. **V3 retrain reproduction** — reran the documented pipeline (`--imu-seq
   --imu-causal --imu-window 50 --epochs 30`) with `--out` pointed at a scratch
   dir so committed models were untouched. Reproduced the auto-block numbers
   exactly: MEAN test frame 0.995 / windowed 1.000. Stable at 30 epochs.
3. **New script `scripts/cross_user_eval.py`** — read-only eval of the
   committed `.keras` models on the *other* participant's full (100% unseen)
   data, reusing the training code's own window builder + metrics.
   Results: anonymous_→Jimmy frame 0.953 / windowed 0.904; jimmy_→Anonymous
   frame 0.974 / windowed 0.914. Weakest class `right` (confusion right→both).
   Windowed < frame cross-user because errors are temporally clustered.
4. **Provenance check on `posture_imu.mlpackage`** — compared its predictions
   (via coremltools) to both keras models on 40 random windows: 40/40 argmax
   agreement with `anonymous_`, wild disagreement with `jimmy_`. **The bundled
   app model is trained on Anonymous data only** — every other live user is a
   mock user and should expect the ~0.90 windowed numbers, not 1.00.
5. **model.md corrections** — the intro note wrongly called the auto block
   "image-era": the `imu=off` tag comes from `--use-imu` (fusion), not
   `--imu-seq` (`train_hand_classifier.py:1254`), and the block's numbers match
   the V3 IMU-seq `summary.json` exactly. Also the "current bundled model"
   marker on the 2026-07-07 entry was stale (V3 replaced the mlpackage on
   2026-07-09). Both fixed; cross-user + reproduction entries added to the
   results log; "cross-user not yet measured" note updated.

## Errors hit / gotchas
- The numpy 1.x/2.x ImportError spam (documented in model.md gotchas) also
  fires on plain `coremltools` import — still harmless, output still usable.
- Loading a saved `.keras` model loses the `_hand_classes` attribute that
  `_predict_labels` relies on — decode argmax against `labels.json`
  (alphabetical: both/left/right) instead.
- `ct.models.MLModel(...).predict()` works on macOS directly; input key is
  `imu_window` shaped (1, 50, 12), probabilities under `classProbability`.

## Key facts for future agents
- Training is strictly per participant (`train_hand_classifier.py:996` groups
  by `participant_key`; slice at :1076). One command → N disjoint models.
  Nothing ever trains on pooled multi-user data — a pooled / leave-one-user-out
  mode would be new work (roadmap next-step #1).
- Cross-user baseline (2 users, same device/protocol): ~0.95–0.97 frame,
  ~0.90–0.91 windowed — competitive with HandyTrak's ~0.89 paper number.

## Outcome
model.md updated (2 new results-log entries + 3 corrections),
`scripts/cross_user_eval.py` added and verified to reproduce the numbers.
Nothing committed (not requested). No builds — build_log.md untouched.

## Addendum (same day) — vote-window sweep (mentor request)
- New `scripts/window_sweep.py`: windowed accuracy at vote windows 1..60 for
  all four (model, eval-set) combos. Headline: w=3 dominates w=30 everywhere
  (within-user 100% at 1.5 s latency instead of 15 s; cross-user +5–6 points
  because big votes commit to error bursts). Logged in model.md results log.
- Verified PosturePredictor.swift does NO live smoothing — raw 2 Hz labels.
  A live 3-vote majority is the obvious cheap follow-up if wanted.
- Frame-rate context for the "30 fps" idea: IMU already streams at 50 Hz;
  the 2 Hz cap is the PosturePredictor timer (predictionInterval 0.5 s) and,
  for data collection, HandBurstCapture's 0.5 s camera throttle (HandyTrak
  parity). Raising prediction rate needs no new sensors or model changes.
