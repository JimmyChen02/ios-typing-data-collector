# Posture Demo / Video Recipe

End-to-end recipe for the "video/demo of the classification model working"
deliverable (D3): collect labeled posture-training data on-device, train the
IMU sequence model offline, convert it to Core ML, reinstall, and screen-record
the live camera-preview overlay's posture tag updating in real time while you
type in each posture.

This exercises all three deliverables on one branch:
- **D2** — the "Posture training run" capture flow + live camera-preview
  overlay.
- **D1** — the IMU sequence model (`scripts/imu_sequence.py`,
  `train_hand_classifier.py --imu-seq`).
- **D3** — Core ML export (`scripts/export_imu_coreml.py`) +
  `PosturePredictor` wiring.

---

## 1. Collect a posture-training run (D2)

On-device, from the app's setup screen:

1. Fill in participant info as usual (or leave defaults).
2. Tap **"Posture Training Run"** (below the normal "Start Study" button).
3. On the picker screen, choose a posture — **Left**, **Right**, or **Mid
   (Both hands)**.
4. Type normally for the session. In the background, the app:
   - Continues logging keystrokes exactly as in a normal session (data
     integrity unaffected — see the D2 spec).
   - Starts a background ~2 Hz front-camera burst (`HandBurstCapture`) and
     saves one JPEG + one `HandSample` row per frame, all labeled with the
     posture you picked.
   - Records device motion at 50 Hz to `Documents/imu/<sessionId>.csv`
     (`MotionRecorder`, already running for every session).
5. Optionally tap the small camera icon (top-right of the typing screen) to
   open the live preview overlay and confirm frames are being captured. The
   tag shows `<posture> (declared)` until a Core ML model is bundled (step 4
   below wires up the real live prediction).
6. Repeat steps 2–5 for each posture (Left, Right, Mid) you want training
   data for — each run is a separate one-session study, so run it three
   times (once per posture) for a balanced dataset.
7. On the "Collection Complete" screen, tap **"Hand Data Zip (CSV + Images)"**
   to export the manifest CSV + all JPEGs + all IMU CSVs as one `.zip`.
   AirDrop or save it to your Mac and unzip it, e.g. into
   `~/Downloads/posture_export/`.

---

## 2. Train the causal IMU sequence model (D1)

From the repository root, using the isolated ML venv:

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py \
    ~/Downloads/posture_export/hand_manifest_<participant>.csv \
    --images-root ~/Downloads/posture_export/ \
    --out ~/Downloads/posture_model/ \
    --imu-seq --imu-causal --imu-window 50 --epochs 10 \
    --md-out ~/Downloads/posture_model/results.md
```

- `--imu-causal` is required here (not just `--imu-seq`): the live on-device
  model can only see past + current samples (a trailing window), so the
  *exported* model must be trained on the same causal window shape it will
  serve at inference time — the D1 spec's documented train/serve asymmetry
  (offline eval may use the centered window; the Core ML export always uses
  causal).
- This produces `~/Downloads/posture_model/<participant_key>/hand_model.keras`
  and `labels.json`.

No real data yet? Sanity-check the whole pipeline with synthetic data first:

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py --demo --imu-seq --imu-causal
```

---

## 3. Export to Core ML (D3)

```bash
.venv-ml/bin/python scripts/export_imu_coreml.py \
    --model ~/Downloads/posture_model/<participant_key>/hand_model.keras \
    --labels ~/Downloads/posture_model/<participant_key>/labels.json \
    --window 50 \
    --out ~/Downloads/posture_model/posture_imu.mlpackage
```

Requires `coremltools` (see `requirements-ml.txt`):

```bash
.venv-ml/bin/pip install 'coremltools>=7.0'
```

If `coremltools` is not installed, the script prints a clear install
instruction and exits non-zero — it never crashes with a raw traceback.

---

## 4. Bundle the model and reinstall

1. Drag `posture_imu.mlpackage` into the Xcode project navigator (into the
   `TypingResearch` target, "Copy items if needed" checked, added to the
   `TypingResearch` target's **Copy Bundle Resources** build phase).
   - The resource name **must** stay `posture_imu` (no extension change) —
     `PosturePredictor.modelResourceName` looks for exactly this name.
   - Xcode compiles `.mlpackage` → `.mlmodelc` automatically at build time;
     `PosturePredictor` looks for either extension in the bundle.
2. Build and run on a physical device (Simulator has no meaningful IMU
   signal — device motion readings are flat/synthetic there).
   ```sh
   xcodebuild -scheme TypingResearch -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   (Use a physical-device destination for the actual demo recording — the
   command above is the standard CI build-verification target.)

---

## 5. Record the demo

1. Launch the app on-device, start a normal typing session (posture training
   run or a regular study — the live overlay works in either, but only
   posture-training-run sessions currently expose the camera toggle button;
   see `TrialView`'s `isPostureTrainingRun` guard).
2. Tap the camera icon to open the live preview overlay.
3. Confirm the tag now shows a live-predicted posture with a confidence
   percentage (no `(declared)` suffix — `PosturePredictor.isModelAvailable`
   is true once the bundled model loads).
4. Screen-record (Control Center → Screen Recording) while holding the phone
   in each posture (left, right, both) and typing a few words in each —
   the tag should update roughly every 0.5s (~2 Hz) as the rolling causal
   IMU window slides forward.
5. Stop the recording; this is the "video/demo of the classification model
   working" deliverable.

---

## Notes / known limitations

- **IMU-only inference (OPEN QUESTION 1 = A).** The live tag is predicted
  from motion alone — no camera frame is used for inference, only for the
  display-only preview. This means the deployed model does not depend on the
  user declaring which hand they're using; only the *training* label (D2's
  declared posture) does.
- **Vision pipeline not converted.** FCN-ResNet101 + VGG16 (the image
  HandyNet path) are intentionally NOT part of this Core ML export — too
  heavy for interactive on-device inference. See `export_imu_coreml.py`'s
  docstring for the full rationale.
- **Simulator.** `HandBurstCapture` degrades gracefully (no frames, no
  crash) and `PosturePredictor` stays a no-op (`.unknown`) if no model is
  bundled or CoreMotion has nothing meaningful to report — record the actual
  demo on a physical device.
