# 2026-07-29 — Vote-window and inference-cadence efficiency experiment

## What was attempted

Turn the existing console-only window sweeps into a reproducible graph of
performance versus (a) majority-vote duration and (b) effective inference
rate, and run the same comparison for camera+IMU fusion and IMU-only.

## Method

- Added `scripts/cadence_window_experiment.py`.
- Evaluated only Jimmy's 10 dense recapture sessions: 16,946 frames at a mean
  measured 30.32 fps.
- Used `fusion_louo_jimmy_` and `imu_only_louo_jimmy_`. Both were trained on
  Anonymous, so Jimmy is an unseen participant.
- Both modalities use exactly the same frames and the same causal 50-sample
  IMU windows.
- Window sweep: 0–15 seconds; votes never cross session boundaries.
- Cadence sweep: 30, 15, 10, 7.5, 6, 5, 3, 2, and 1 inference calls/second.
  Lower rates are simulated by evenly skipping source frames, holding the
  last published label between calls, and still scoring all 16,946 source
  frames. This avoids making a low-rate condition look better by omitting
  difficult moments.
- The cadence comparison fixes the vote duration in seconds. Window selection
  for deployment is constrained to <=1.5 seconds for the existing live
  responsiveness budget, then takes the smallest duration within 0.2 accuracy
  point of the constrained best.

## Results

- Camera+IMU: raw/no-vote was best at 95.30%. A 3 Hz cadence scored 95.12%,
  only 0.18 percentage point below the best while using about 90% fewer model
  calls than 30 Hz.
- IMU-only: raw/no-vote was the best deployable (<=1.5 s) window at 93.27%.
  A 3 Hz cadence scored 93.10%, 0.19 point below the best cadence while using
  about 90% fewer calls.
- Accuracy-only, without a latency constraint, selected a 15-second IMU vote
  window (95.86%). This is not recommended for live use: a majority vote that
  long can take roughly half the window to recognize a clean posture change.
- The present 1.5-second vote lowered accuracy on this denser recapture for
  both saved models (fusion 94.74%, IMU 92.68%). This differs from the earlier
  sweep on the old data and is exactly why the experiment must be rerun on
  each deployment-representative dataset.

## Verification and outputs

- Full real-data run completed successfully.
- `python3 -m py_compile scripts/cadence_window_experiment.py` passed.
- Outputs are under ignored `results/posture_efficiency/`:
  `window_vs_performance.csv`, `cadence_vs_performance.csv`,
  `window_and_cadence_performance.png`, and `summary.json`.

