# 2026-07-17 — 30 fps capture + guided-burst IMU + vote-window retune (runbook B3/B4)

## What was attempted
Continue the posture-demo runbook from B3. Jimmy's direction on arrival at
B4: live prediction at 30 Hz (was already in the working tree from the
previous session), camera capture at 30 fps, and "capture IMUs as well" —
scoped via Q&A to: IMU recording added to the guided burst capture
(HandCaptureView), camera 2 → 30 fps in BOTH capture flows, and the B4
vote-window re-sweep written + run now.

## What was done
1. **30 fps for real, not nominally** — three latent caps would have eaten
   a bare `targetFPS = 30`: the `.photo` preset (per-frame CIImage→CGImage
   of full-res buffers can't sustain tens of fps → auto-drop to 720p above
   10 fps), a fresh `CIContext` per frame (now one shared instance), and
   the strict `elapsed >= 1/30` throttle gate (PTS deltas are exactly
   1/30 s at native rate; float jitter dropped every other frame → 8 ms
   tolerance). JPEG encode+write moved off the main actor to a serial
   background queue in both saveFrame paths; `capturedAt`/index stamped
   synchronously so sort keys and IMU alignment are unaffected.
2. **Guided-burst IMU** — per-condition `MotionRecorder` recording started
   lazily at the FIRST delivered frame, because
   `imu_sequence.build_sequence_dataset` anchors IMU t=0 to the group's
   MIN `capturedAt`; starting before camera warm-up would shift every
   window by the warm-up gap. Found in passing: the old code linked guided
   samples to `imu/<sessionId>.csv` — the session recording that STOPPED
   before the burst began — so all guided-burst frames were unusable as
   IMU-seq training data. Per-condition CSVs fix that. Discard/skip/early
   dismiss deletes the CSVs; Save & Continue sets `phase = .done` before
   `onComplete` so the onDisappear cleanup can't nuke saved CSVs.
3. **B4 sweep** — new `scripts/dense_window_sweep.py`: 33.3 ms steps over
   each session IMU CSV (same anchor as training), causal 50×12 windows,
   committed .keras models, and a verbatim Python replay of
   PosturePredictor's vote (majority of last w, tie keeps published).
   Result: cross-user accuracy FLAT for w=1..30 (~0.965 — consecutive
   windows overlap ~96%, votes correlated, exactly why w=3@2Hz didn't
   transfer), rising slightly at w≥45. Stability (published-label
   switches/min) improves monotonically: 7.1 (w=1) → 2.3 (w=45).
   **Picked w=45**: best accuracy (0.9671 mean cross) AND steadiest within
   the ≤1.5 s latency budget; majority flips ~0.75 s after a clean grip
   change. `voteWindowSize` 3 → 45.

## Errors hit / gotchas
- **This machine has no iPhone 16 simulator** (CLAUDE.md's build command is
  from trantran's machine). Use `name=iPhone 17 Pro`. Worse: piping
  xcodebuild to `tail`/`grep` masks its exit code — two builds "passed"
  with exit 0 while actually dying on "Unable to find a device". Use
  `set -o pipefail` (or check for `BUILD SUCCEEDED`) always.
- The scripts venv for ML work is **`.venv-ml/`**, not `venv/` (which has
  no python binary on this machine). The numpy 1.x/2.x ImportError spam on
  import is the known harmless gotcha from model.md.
- `windowed_accuracy`-style metrics can't see flicker: at 30 Hz, accuracy
  alone recommended w=1. Adding switches/min flipped the recommendation to
  w=45 — accuracy is the wrong sole objective for a smoothing constant.

## Outcome
`** BUILD SUCCEEDED **` (iPhone 17 Pro sim), no warnings in touched files;
build_log.md updated. Not committed (not requested). Remaining from B3:
on-device live verify (label steady, grip change follows in ~1–2 s — needs
a phone with the bundled model; w=45 now makes the 1.5 s upper bound the
expected worst case). Disk-rate note for the researcher: 30 fps × 720p
JPEG ≈ 3–6 MB/s while capture runs (~300–500 MB per guided run; a long
posture training run can reach GBs).
