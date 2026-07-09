# Hand Data Collection Protocol

How to collect a real, trainable holding-hand dataset using the
iOS Typing Data Collector app, following the HandyTrak (UIST 2021)
data-collection approach.

---

## Conditions

Each participant must complete **all three** holding-hand conditions so the
classifier can learn a three-class label:

| Condition | `holding_hand` value in manifest |
|-----------|----------------------------------|
| Left hand only  | `left`  |
| Right hand only | `right` |
| Both hands      | `both`  |

The app guides the participant through these conditions in the order
**left → right → both** inside a single sheet during the between-session
break.

---

## Duration and Frame Count

- **~60 seconds per condition** at **~2 Hz** = **~120 frames per condition**
- **~360 frames per participant** across all three conditions

These values are controlled by two named constants at the top of
`TypingResearch/Views/HandCaptureView.swift`:

```swift
private let captureSeconds: Int   = 60    // seconds per condition
private let targetFPS:      Double = 2.0  // frames per second
```

Change either constant to tune duration or frame density without touching
any other code.

The Python trainer's sliding-window-30 + majority-vote evaluation needs
enough frames for an 80/20 time split; 120 frames/condition comfortably
supports this.

---

## Recommended Number of Participants

- **Minimum 1** — produces a per-user model for that participant (the
  pipeline trains one model per user, so even a single participant yields
  a meaningful result).
- **3–5 participants** — gives a defensible, generalisable result and lets
  you see variance across individuals.
- Each participant completes one run of the full typing study to the
  between-session screen, then the guided 3-condition camera burst.

---

## Lighting, Pose and Framing Notes

These guidelines follow the HandyTrak paper:

- **Lighting**: use even, front-facing ambient light. Avoid strong backlight
  (window behind the participant) which collapses the silhouette.
- **Background**: a plain, static background helps the FCN-ResNet101 person
  segmentation generalize; avoid busy, cluttered scenes.
- **Framing**: the app captures the full front-camera field of view at photo
  preset — keep the **upper body visible** (face, shoulders, arms, and hands
  holding the phone). Do not crop or hold the phone too close.
- **Position**: hold the phone at natural typing height and distance, the way
  you would actually type.
- **Posture**: vary between standing and sitting across participants if
  feasible; collect one consistent posture per condition (do not switch
  mid-burst).
- **Stability**: keep the phone as still as possible during each condition
  (one hand label the whole 60 s). The throttled 2 Hz capture already
  reduces motion blur, but sharp frames improve segmentation quality.
- **Vary grip**: if the dataset permits it, collect some participants with a
  middle-centric grip and some with a skewed grip — HandyTrak notes that
  the centroid-based baseline is sensitive to grip position.

---

## Export from the App

1. Complete the typing study until the **"Collection Complete"** (or
   "Study Complete") summary screen appears.
2. Tap **"Hand Data Zip (CSV + Images)"** in the export section.
3. In the share sheet, AirDrop (or save to Files) **both**:
   - the `manifest_hand_<participant>.csv` file
   - the `hand_images/` folder (one JPEG per frame)
4. On the Mac, place the CSV file and the `hand_images/` folder in the
   same parent directory, e.g.:

   ```
   my_study/
     manifest_hand_alice.csv
     hand_images/
       <uuid1>.jpg
       <uuid2>.jpg
       ...
   ```

---

## Training Command

The current (IMU) retrain pipeline lives in `Model-Training-Test/model.md`;
full internals in `scripts/README_hand.md`.

To run the built-in synthetic demo (no collected data required):

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py --demo
```

---

## Reading Results

The script prints a `[PAPER-FAITHFUL]` banner followed by a per-user
accuracy table, then writes `models/summary.json`.

Each row in `summary.json` contains:

| Field | Meaning |
|-------|---------|
| `participant` | Participant identifier |
| `n_train` | Number of training frames used |
| `n_eval` | Number of held-out evaluation frames |
| `handynet_frame_acc` | Per-frame accuracy of the HandyNet CNN |
| `handynet_windowed_acc` | Sliding-window-30 + majority-vote accuracy (the headline HandyTrak metric) |
| `centroid_frame_acc` | Per-frame accuracy of the zero-training centroid baseline |

**The `handynet_windowed_acc` is the primary metric** reported in the
HandyTrak paper. The `centroid_*` fields are the sanity baseline — a
purely geometric classifier that requires no training.

---

## How the Manifest Encodes Time Order

The Python trainer sorts each condition's frames by
`(study_session_index, captured_at_iso, image_relative_path)`
(see `scripts/hand_dataset.py` line 198).

- `study_session_index` is written as the per-frame counter (0, 1, 2, …)
  **reset to 0 at the start of each condition**, giving the trainer a
  strictly-increasing, tie-free primary sort key within each
  (participant, label) block.
- `captured_at_iso` is the wall-clock timestamp of each frame, which
  increases monotonically under normal conditions.
- Together these two fields guarantee a clean 80/20 time split regardless
  of system clock precision.

No changes to the manifest schema, the Python scripts, or the SwiftData
model are required to support multi-frame capture — the existing 14-column
schema already supports many rows per participant.
