# Model Training — How To

Trains a **holding-posture classifier** (left / right / both hands) from data
collected by the TypingResearch iOS app.

There are two pipelines — you usually want the **IMU sequence model**, because
it is fast to train and is the one that ships in the app for live on-device
prediction:

| Pipeline | Flag | Input | Used for |
|---|---|---|---|
| **IMU sequence** | `--imu-seq` | 1-second windows of the 50 Hz motion stream (12 channels) | **Core ML export → live in-app prediction** |
| Image (HandyNet) | *(default)* | Front-camera photos → body silhouette → VGG16 features | Offline paper-faithful classifier (slow, ~10–20 min) |

Results from every run are logged in [`model.md`](model.md).

---

## Step 0 — One-time environment setup

```bash
bash scripts/setup_ml_env.sh --prefetch-weights
```

Creates `.venv-ml/` at the repo root (isolated TensorFlow install, ~1 GB) and
pre-downloads the pretrained weights. Run all later commands with
`.venv-ml/bin/python` from the **repo root**.

## Step 1 — Collect and export data from the app

1. Run the study in the app; the guided capture between sessions walks the
   participant through **left → right → both** (photos at ~2 Hz + IMU stream).
2. On the "Collection Complete" screen, tap **"Hand Data Zip (CSV + Images)"**
   and AirDrop/save the `.zip` to your Mac.

## Step 2 — Put the data in this folder

1. Unzip the export **untouched** into
   `Model-Training-Test/exports/<participant>_<YYYY-MM-DD>/` (provenance —
   never edit these).
2. Merge into the flat training layout the trainer reads (filenames are
   UUIDs, so collisions are impossible):
   - `hand_images/*` → `Model-Training-Test/hand_images/`
   - `imu/*` → `Model-Training-Test/imu/`
   - manifest rows (skip the header) → append to
     `Model-Training-Test/hand_manifest_combined.csv`

> **Gotcha:** the image folder must be named exactly `hand_images`
> (underscore, not hyphen) and sit inside the `--images-root` directory.

Images, manifests, and IMU CSVs are gitignored — only code, docs, and models
are tracked.

## Step 3 — Train

**IMU sequence model (the one that ships in the app):**

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out Model-Training-Test/models_imu/ \
    --imu-seq --imu-causal --imu-window 50 --epochs 30 \
    --md-out Model-Training-Test/model.md
```

- `--imu-causal` is **required** if you plan to export for live use: the
  on-device model only sees past samples, so training must match.
- Use **≥ 30 epochs** — at 10 the small Conv1D is unstable (identical runs
  have swung from 100% to 48% accuracy).

**Image pipeline (offline alternative, slow):**

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py \
    Model-Training-Test/hand_manifest_combined.csv \
    --images-root Model-Training-Test/ \
    --out Model-Training-Test/models/ \
    --mode both --epochs 2
```

Segmentation looks frozen for 10–20 minutes on CPU — it is working. Wait for
the `[PAPER-FAITHFUL]` banner at startup.

**No real data yet?** Sanity-check the pipeline with synthetic data:

```bash
.venv-ml/bin/python scripts/train_hand_classifier.py --demo --imu-seq --imu-causal
```

## Step 4 — Read the results

- The script prints a per-participant accuracy table and writes
  `<out>/summary.json`.
- **Headline metric:** held-out *windowed* accuracy (30-frame sliding-window
  majority vote — the HandyTrak paper's metric). The centroid column is a
  zero-training baseline (~33% = chance).
- `--md-out` auto-records the best run in [`model.md`](model.md); also add a
  short entry to the manual results log there for every run.

Outputs under `--out`:

```
models_imu/
    summary.json                  ← accuracy table for all participants
    <participant_key>/
        hand_model.keras          ← trained model
        labels.json               ← ordered class list
```

## Step 5 — Export to Core ML and bundle in the app (IMU model only)

```bash
.venv-ml/bin/python scripts/export_imu_coreml.py \
    --model Model-Training-Test/models_imu/<participant_key>/hand_model.keras \
    --labels Model-Training-Test/models_imu/<participant_key>/labels.json \
    --window 50 \
    --out posture_imu.mlpackage
```

Then drag `posture_imu.mlpackage` into the Xcode project (TypingResearch
target, Copy Bundle Resources). The resource name **must stay `posture_imu`**
— `PosturePredictor` looks for exactly that name. Full details:
[`docs/POSTURE_DEMO.md`](../docs/POSTURE_DEMO.md).

---

## How training works (in one paragraph)

The trainer groups manifest rows per participant, splits each condition's
frames **80/20 in time order** (no shuffle — the test set is "later moments
the model never saw"), turns each sample into features (IMU: a `(50, 12)`
window of motion samples ending at the photo timestamp; image: frozen
FCN-ResNet101 silhouette → frozen VGG16 features), and trains only a **small
classifier head** on top — which is why a few hundred samples per person is
enough. Every frame inherits the label of the condition it was captured in,
so honest holding during each labeled window is the main data-quality lever.
Models are **per-participant** — a single cross-person model performs poorly.

## Useful knobs

| Flag | Effect |
|---|---|
| `--epochs N` | Train longer (IMU: use ≥ 30) |
| `--imu-window N` | IMU samples per input window (default 50 ≈ 1 s at 50 Hz). *Not* the same as `--window-size` (evaluation majority-vote window, default 30) |
| `--mode handynet` / `--mode centroid` | Image pipeline: skip the baseline / run only the baseline |
| `--md-out FILE` | Auto-record the best run in a markdown file. Use a *different* file for image vs. IMU runs if comparing — each file keeps only one best-run block |
| `> train.log 2>&1 &` | Run in the background and watch the log |

## More detail

- [`model.md`](model.md) — results log (all runs) + auto-generated best run
- [`scripts/README_hand.md`](../scripts/README_hand.md) — full pipeline
  internals, manifest schema, fallback ladder, external-dataset layout
- [`docs/HAND_DATA_COLLECTION.md`](../docs/HAND_DATA_COLLECTION.md) —
  collection protocol (lighting, framing, durations, participant counts)
- [`docs/POSTURE_DEMO.md`](../docs/POSTURE_DEMO.md) — Core ML export + live
  in-app demo, end to end
