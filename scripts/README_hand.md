# Holding-Hand Classification (HandyTrak-style)

This document describes the offline pipeline for collecting and training
holding-hand labels from the TypingResearch iOS app.

Reference paper: **HandyTrak: Recognizing the Holding Hand on a Commodity
Smartphone from Body Silhouette Images** — Lim, Lin, Tweneboah, Zhang (SciFi
Lab, Cornell). UIST 2021.

---

## What is captured

The app presents a front-camera capture sheet (`HandCaptureView`) at the
`BetweenSessionView` boundary after each typing session. The researcher:

1. Holds the phone naturally (as during typing).
2. Takes a selfie-style photo — the sensor is the **front-facing camera**;
   the subject is the user's upper-body silhouette (head + shoulder outline),
   NOT a close-up of the hand on the device.
3. Confirms the holding hand from a picker (Left / Right / Both / Unknown).
4. Taps "Save" (photo is optional — label-only records are supported).

---

## Manifest CSV schema

Exported from the app via the "Hand data" button in `SummaryView`.

| Column | Description |
|--------|-------------|
| `participant_first` | Participant first name |
| `participant_last` | Participant last name |
| `study_id` | UUID for this study run |
| `session_id` | UUID for the session (may be empty) |
| `study_session_index` | 0-based session index (-1 if not session-scoped) |
| `captured_at_iso` | ISO 8601 capture timestamp |
| `holding_hand` | `left` / `right` / `both` / `unknown` |
| `image_relative_path` | Path relative to `Documents/` (e.g. `hand_images/<uuid>.jpg`) |
| `image_pixel_width` | JPEG pixel width (0 if no photo) |
| `image_pixel_height` | JPEG pixel height (0 if no photo) |
| `camera_position` | `front` (forward-compatible for back-cam tests) |
| `device_model` | e.g. `iPhone 16 Pro` |
| `system_version` | e.g. `18.0` |
| `notes` | Free text (usually empty) |

---

## Offline pipeline

### 1. Export from the app

In the `SummaryView` export section, tap **Hand data** to share:
- `hand_manifest_<name>.csv` — the manifest CSV described above
- All captured `.jpg` images

Save these to a directory, for example `~/Downloads/hand_export/`.

### 2. Inspect the dataset

```sh
python3 scripts/hand_dataset.py ~/Downloads/hand_export/hand_manifest.csv \
    --images-root ~/Downloads/hand_export/
```

Or run a quick sanity check with synthetic data:

```sh
python3 scripts/hand_dataset.py --demo
```

### 3. Train the classifier

```sh
python3 scripts/train_hand_classifier.py \
    ~/Downloads/hand_export/hand_manifest.csv \
    --images-root ~/Downloads/hand_export/ \
    --out ~/Downloads/hand_model/
```

Or run end-to-end on synthetic data:

```sh
python3 scripts/train_hand_classifier.py --demo
```

Outputs written to `--out`:
- `hand_model.keras` (if keras/tensorflow available) or `hand_model.pkl`
- `labels.json` — the ordered class list

---

## Pipeline details

### Stage 1 — preprocess

Load the JPEG, convert to RGB, resize to 224×224, normalise to float32 [0, 1].

### Stage 2 — segment (paper: FCN-ResNet101)

**Paper-faithful path** (requires `torch` + `torchvision`): runs a pretrained
FCN-ResNet101 segmentation network on the image and extracts the "person"
class probability map, thresholded at 0.5 to produce a binary body silhouette
(white = body, black = background).

**Lightweight fallback** (numpy only): luminance-based Otsu-style threshold.
Clearly marked in code as a stand-in for FCN-ResNet101.

```sh
pip install torch torchvision   # for paper-faithful segmentation
```

### Stage 3 — extract_features (paper: VGG16 backbone)

**Paper-faithful path** (requires `tensorflow` / `keras`): passes the silhouette
through a pretrained VGG16 backbone (frozen weights, `include_top=False`) to
produce a 25088-d feature vector (7×7×512 flattened).

**Lightweight fallback**: downscale silhouette to 32×32 and flatten to 1024-d.

```sh
pip install tensorflow   # for paper-faithful features
```

### Stage 4 — train (paper: HandyNet)

**Paper-faithful path** (requires `tensorflow` / `keras`): HandyNet =
frozen VGG16 backbone + `Flatten` + `Dropout(p=0.5)` + `Dense(3, softmax)`.
Trained for **2 epochs** (paper-faithful value, HandyTrak §4.1), Adam,
batch size 32.  Override with `--epochs N`.

**Fallback 1** (requires `scikit-learn`): `LogisticRegression` on the
extracted features.

**Fallback 2** (pure numpy): nearest-centroid classifier.  Always runs.

```sh
pip install scikit-learn   # for LogisticRegression fallback
```

### Option B — per-participant HandyNet (implemented)

Training is per-participant.  Samples for each participant are grouped by
`participant_first|participant_last` (lowercased + stripped) and sorted by
`study_session_index` → `captured_at_iso` → `image_relative_path`.

The first 80 % of frames (per condition, in time order) go to **train**; the
last 20 % go to **eval**.  No shuffling.  Evaluation reports:
- Frame-level held-out accuracy (honest, not in-sample).
- **Windowed accuracy**: 2 Hz sliding-window of size 30, majority-vote per
  window — this is the paper's evaluation metric (HandyTrak §4.2).

A `[PAPER-FAITHFUL]` or `[FALLBACK — not paper results]` banner is printed at
startup indicating whether `torch`+`tensorflow` were both importable.

### Option C — centroid baseline (implemented)

Zero-training geometric sanity check: the horizontal centroid of the
foreground pixels in the silhouette is used to predict `left` / `right` /
`both`.  Run alongside HandyNet to confirm that centroid-x carries signal
(data-separability check).  Not the paper's classifier.

---

## Data sufficiency — how to actually train per-user TODAY

HandyTrak trains a CNN head **per user per condition** on hundreds of frames.
One still per session is far too sparse.

Three concrete supported paths, in priority order:

1. **External / borrowed dataset (this increment — iOS stays frozen).**
   Any directory of JPEGs + a 14-column manifest in the documented schema
   works unchanged.  See "External dataset layout" below.

2. **Synthetic demo path** (`--demo`): 2 users × 3 conditions × 20 frames,
   for pipeline plumbing / CI only — NOT a results claim.

3. **Future — burst capture**: replace the single-still flow with AVFoundation
   burst (~15 frames at 2 Hz per label confirmation) so the iOS app itself
   generates hundreds of frames / user / condition.

---

## External dataset layout

Any directory organised as follows is supported without modification:

```
<images-root>/
    hand_images/
        <uuid1>.jpg
        <uuid2>.jpg
        ...
    hand_manifest.csv    ← 14-column CSV, schema as above
```

Required manifest columns (all 14 must be present, even if empty):

| Column | Used by pipeline |
|--------|-----------------|
| `participant_first` | Participant grouping key (lowercased) |
| `participant_last`  | Participant grouping key (lowercased) |
| `study_session_index` | Time-order sort key (integer; unparseable → sort last) |
| `captured_at_iso`   | Tiebreaker for sort order |
| `image_relative_path` | Path under `--images-root` |
| `holding_hand`      | Label: `left` / `right` / `both` / `unknown` |
| remaining 8 columns | Present but not used in training |

Grouping key: `f"{participant_first}|{participant_last}"` lowercased + stripped.
Time order within a participant: `study_session_index` asc → `captured_at_iso` → `image_relative_path`.

---

## Exact commands

### Inspect dataset

```sh
python3 scripts/hand_dataset.py ~/Downloads/hand_export/hand_manifest.csv \
    --images-root ~/Downloads/hand_export/
```

### Train per-user HandyNet + centroid baseline (held-out windowed eval)

```sh
python3 scripts/train_hand_classifier.py \
    ~/Downloads/hand_export/hand_manifest.csv \
    --images-root ~/Downloads/hand_export/ \
    --out ~/Downloads/hand_model/ \
    --mode both --train-frac 0.8 --window-size 30 --epochs 2
```

### Centroid-only separability sanity check (no torch/tf needed)

```sh
python3 scripts/train_hand_classifier.py \
    ~/Downloads/hand_export/hand_manifest.csv \
    --images-root ~/Downloads/hand_export/ \
    --out ~/Downloads/hand_model/ \
    --mode centroid
```

### CI / plumbing (no real data needed)

```sh
python3 scripts/train_hand_classifier.py --demo
```

### Install optional heavy deps for `[PAPER-FAITHFUL]` run

```sh
pip install torch torchvision tensorflow scikit-learn
```

### Safe install path (recommended — preserves numpy 2.x in the anaconda base)

On this machine `torch`, `torchvision`, `scikit-learn`, `numpy`, and `Pillow`
are already present in the anaconda base env. Only `tensorflow`/`keras` is
missing. However, TensorFlow's pip resolver may try to constrain numpy, which
could silently downgrade numpy 2.x in the base env and affect other scripts.
The safe path is an isolated venv (`--system-site-packages` makes the already-
installed torch/torchvision/numpy/Pillow/scikit-learn visible inside it, so
only TensorFlow is actually downloaded and added).

> **Apple Silicon / numpy-2 note**: use `tensorflow>=2.16,<2.20` — this is the
> first range with Python 3.12 support and numpy 2.x compatibility on arm64
> (the old `tensorflow-macos` wheel is deprecated and merged into the generic
> `tensorflow` package since 2.16). See `requirements-ml.txt` for the pinned
> range.

**Step 1 — create venv and install (one time, ~1 GB download):**

```sh
bash scripts/setup_ml_env.sh --prefetch-weights
```

This creates `.venv-ml/` at the repo root (isolated from the anaconda base),
installs TensorFlow, and pre-downloads the FCN-ResNet101 and VGG16 weights
(~700 MB total) into the torch hub and `~/.keras/models` caches so the first
training run is not surprised by a large mid-run download.

**Step 2 — activate and run:**

```sh
source .venv-ml/bin/activate
python scripts/train_hand_classifier.py --demo
```

Expected output starts with:

```
[PAPER-FAITHFUL] torch + tensorflow/keras both importable — FCN-ResNet101 segmentation and VGG16 HandyNet will be used.
```

**To prefetch weights independently (without reinstalling):**

```sh
.venv-ml/bin/python scripts/fetch_pretrained_weights.py
```

Use `--fcn-only` or `--vgg-only` to download a single weight set.

---

## Output layout

```
<out>/
    summary.json                      ← per-participant table (all modes)
    <participant_key>/
        hand_model.keras              ← HandyNet (if tensorflow present)
        hand_model.pkl                ← fallback (pickle)
        labels.json                   ← ordered class list, e.g. ["both","left","right"]
```

`participant_key` is the filesystem-safe version of `first|last`
(characters other than `[a-z0-9]` replaced with `_`).

The `[PAPER-FAITHFUL]` / `[FALLBACK — not paper results]` banner at runtime
tells the researcher whether torch + tensorflow were both importable and the
paper path was followed.

---

## Future work

- **IMU fusion** — `MotionRecorder` is wired but OFF by default; enabling it
  and fusing IMU with image features is left for a future increment.
- **On-device Core ML** conversion and inference.
- **Landscape-mode** capture.

---

## Citation

Lim, J., Lin, J., Tweneboah, A., & Zhang, X. (2021). **HandyTrak: Recognizing
the Holding Hand on a Commodity Smartphone from Body Silhouette Images**.
In *Proceedings of the 34th Annual ACM Symposium on User Interface Software
and Technology (UIST '21)*. ACM. https://doi.org/10.1145/3472749.3474738
