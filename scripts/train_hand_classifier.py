#!/usr/bin/env python3
"""
train_hand_classifier.py
------------------------
Implements the HandyTrak (UIST '21) pipeline shape for holding-hand
classification from front-camera upper-body silhouette images.

Pipeline stages (preprocess -> segment -> classify):
  1. preprocess   — load + resize to 224×224
  2. segment      — human-body silhouette extraction
  3. extract_features — feature vector from silhouette
  4. train        — HandyNet-style classifier

Paper-faithful vs. lightweight fallback
----------------------------------------
  segment()
    Paper-faithful:  FCN-ResNet101 (torchvision) person-class mask → binary
                     silhouette.  Requires: torch, torchvision.
    Fallback:        Luminance-based Otsu-style threshold to binary mask.
                     Comment below marks this clearly.

  extract_features()
    Paper-faithful:  VGG16 backbone feature extraction.  Requires:
                     tensorflow / keras.
    Fallback:        Downscale silhouette to 32×32 and flatten.

  train()
    Paper-faithful:  Frozen VGG16 + dropout(0.5) + softmax-3 ("HandyNet").
                     Requires: tensorflow / keras.
    Fallback (1):    LogisticRegression from scikit-learn.
    Fallback (2):    Nearest-centroid classifier (pure numpy).

The script always runs end-to-end regardless of which optional libraries are
present.  A [PAPER-FAITHFUL] or [FALLBACK] banner is printed at startup
indicating whether torch+tf were both importable.

Per-participant training (Option B): models are trained per user per condition
with a time-ordered first-80%/last-20% held-out split. A 2 Hz sliding-window
+ majority-vote evaluation (window size 30) reports windowed accuracy.

Centroid baseline (Option C): zero-training geometric sanity check — reports
whether the horizontal centroid of the silhouette carries label signal.

Usage:
    python3 scripts/train_hand_classifier.py <manifest.csv> \\
        --images-root <dir> --out <model_dir> \\
        --mode both --train-frac 0.8 --window-size 30 --epochs 2
    python3 scripts/train_hand_classifier.py --demo
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pickle
import re
import sys
import tempfile
import warnings
from pathlib import Path

# ---------------------------------------------------------------------------
# Optional heavy dependencies — imported lazily inside functions so the script
# always loads even when none of them are installed.
# ---------------------------------------------------------------------------

def _try_import_torch():
    try:
        import torch
        import torchvision
        return torch, torchvision
    except Exception:
        return None, None


def _try_import_keras():
    try:
        import tensorflow as tf
        from tensorflow import keras
        return tf, keras
    except Exception:
        try:
            import keras  # standalone keras 3.x
            return None, keras
        except Exception:
            return None, None


def _try_import_sklearn():
    try:
        from sklearn.linear_model import LogisticRegression
        return LogisticRegression
    except Exception:
        # ImportError or binary-incompatibility ValueError — treat as absent
        return None


# ---------------------------------------------------------------------------
# Required lightweight dependency: numpy + Pillow
# ---------------------------------------------------------------------------
try:
    import numpy as np
except ImportError:
    raise ImportError("numpy is required.\nInstall with:  pip install numpy")

try:
    from PIL import Image
except ImportError:
    raise ImportError("Pillow is required.\nInstall with:  pip install pillow")

# ---------------------------------------------------------------------------
# Local helper
# ---------------------------------------------------------------------------
# Import load_dataset from hand_dataset.py in the same scripts/ directory.
_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from hand_dataset import (
    load_dataset,
    load_dataset_records,
    _make_demo_manifest_and_images,
)

# imu_sequence is imported lazily inside main() (only needed for --imu-seq)
# to keep this file's import-time surface unchanged for callers that never
# touch the IMU-sequence path.

# ---------------------------------------------------------------------------
# Module-level constants
# ---------------------------------------------------------------------------

# Default epochs (paper-faithful value per HandyTrak §4.1)
_DEFAULT_EPOCHS = 2

# Centroid baseline thresholds (tunable — see centroid_baseline_predict docstring)
_CENTROID_LEFT_THRESH  = 0.42
_CENTROID_RIGHT_THRESH = 0.58

# 12 IMU channels (excludes t_ms), 4 stats each → 48-d summary vector
_IMU_CHANNELS = [
    "attitude_roll", "attitude_pitch", "attitude_yaw",
    "grav_x", "grav_y", "grav_z",
    "acc_x", "acc_y", "acc_z",
    "rot_x", "rot_y", "rot_z",
]
_IMU_FEATURE_DIM = 48  # 12 channels × {mean, std, min, max}


# ---------------------------------------------------------------------------
# Pipeline stage 1 — preprocess
# ---------------------------------------------------------------------------

def preprocess(image_path: str) -> "np.ndarray":
    """Load *image_path* and normalize to float32 224×224×3 (values in [0, 1]).

    Returns a numpy array of shape (224, 224, 3).
    """
    img = Image.open(image_path).convert("RGB")
    img = img.resize((224, 224), Image.BILINEAR)
    arr = np.array(img, dtype=np.float32) / 255.0
    return arr


# ---------------------------------------------------------------------------
# Pipeline stage 2 — segment
# ---------------------------------------------------------------------------

def segment(image: "np.ndarray") -> "np.ndarray":
    """Extract a binary human-body silhouette from *image* (224×224×3 float32).

    Returns a binary numpy array of shape (224, 224) with dtype uint8
    (255 = body / foreground, 0 = background).

    Paper-faithful path (requires torch + torchvision):
        Runs FCN-ResNet101 pretrained on COCO; takes the "person" class
        probability map and thresholds at 0.5 to produce a binary mask.

    Fallback (no torch/torchvision):
        Luminance-based Otsu-style threshold.  This is a stand-in for
        FCN-ResNet101 segmentation and will NOT reproduce the paper's results.
    """
    torch, torchvision = _try_import_torch()

    if torch is not None and torchvision is not None:
        # --- Paper-faithful path ---
        try:
            return _segment_fcn(image, torch, torchvision)
        except Exception as exc:
            warnings.warn(
                f"FCN-ResNet101 segmentation failed ({exc}); falling back to "
                "luminance threshold.",
                stacklevel=2,
            )

    # --- Fallback: luminance threshold (NOT the paper's real segmenter) ---
    # Convert to greyscale luminance via BT.601 coefficients
    luma = (0.299 * image[:, :, 0] +
            0.587 * image[:, :, 1] +
            0.114 * image[:, :, 2])

    # Otsu-style threshold: split at mean luminance as a simple approximation
    threshold = float(luma.mean())
    # Foreground (body) assumed to be darker than the bright background typical
    # of a selfie scenario.  This heuristic is intentionally simple.
    mask = (luma < threshold).astype(np.uint8) * 255
    return mask


# Cache the heavy FCN-ResNet101 model + transform so they are built ONCE and
# reused across every frame (rebuilding per image was the main RAM/speed sink).
_FCN_CACHE: dict = {}


def _get_fcn_model(torch, torchvision):
    """Lazily build and cache the FCN-ResNet101 segmentation model + transform."""
    if "model" not in _FCN_CACHE:
        from torchvision import transforms
        from torchvision.models.segmentation import (
            fcn_resnet101, FCN_ResNet101_Weights,
        )
        weights = FCN_ResNet101_Weights.DEFAULT
        model = fcn_resnet101(weights=weights)
        model.eval()
        _FCN_CACHE["model"] = model
        _FCN_CACHE["transform"] = transforms.Compose([
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406],
                                 std=[0.229, 0.224, 0.225]),
        ])
    return _FCN_CACHE["model"], _FCN_CACHE["transform"]


def _segment_fcn(
    image: "np.ndarray",
    torch,
    torchvision,
) -> "np.ndarray":
    """FCN-ResNet101 segmentation (paper-faithful, requires torch/torchvision)."""
    model, transform = _get_fcn_model(torch, torchvision)

    pil_image = Image.fromarray((image * 255).astype(np.uint8))
    tensor = transform(pil_image).unsqueeze(0)

    with torch.no_grad():
        output = model(tensor)["out"]  # shape: (1, 21, H, W)

    # Class 15 = "person" in the COCO VOC-style palette used by torchvision
    PERSON_CLASS = 15
    person_prob = torch.softmax(output, dim=1)[0, PERSON_CLASS].numpy()  # (H, W)
    binary = (person_prob > 0.5).astype(np.uint8) * 255
    return binary


def segment_batch(images: "list[np.ndarray]") -> "np.ndarray":
    """Batched segment(): runs FCN-ResNet101 on N images (each 224x224x3
    float32) in ONE forward pass instead of N. Returns (N, 224, 224) uint8,
    identical values to calling segment() once per image (verified by
    tests/test_hand_pipeline.py::TestBatchedInference) -- purely a speed
    optimization for bulk pre-caching (see fusion_pooled_train.py), not a
    behavior change. segment() itself is unchanged and still the right
    choice for a single image.

    Falls back to `segment()` per image (same as segment()'s own fallback
    trigger conditions) if torch/torchvision are unavailable or the batched
    call fails for any reason -- a single malformed image in the batch
    raises out of the batched torch call, so this fallback also protects
    against ANY batch containing a bad image, not just missing deps.
    """
    torch, torchvision = _try_import_torch()
    if torch is not None and torchvision is not None:
        try:
            return _segment_fcn_batch(images, torch, torchvision)
        except Exception as exc:
            warnings.warn(
                f"Batched FCN-ResNet101 segmentation failed ({exc}); "
                "falling back to segment() per image.",
                stacklevel=2,
            )
    return np.stack([segment(img) for img in images], axis=0)


def _segment_fcn_batch(
    images: "list[np.ndarray]", torch, torchvision
) -> "np.ndarray":
    """Batched FCN-ResNet101 segmentation (paper-faithful path)."""
    model, transform = _get_fcn_model(torch, torchvision)

    tensors = torch.stack([
        transform(Image.fromarray((img * 255).astype(np.uint8)))
        for img in images
    ])  # (N, 3, 224, 224)

    with torch.no_grad():
        output = model(tensors)["out"]  # (N, 21, H, W)

    PERSON_CLASS = 15
    person_prob = torch.softmax(output, dim=1)[:, PERSON_CLASS].numpy()  # (N, H, W)
    binary = (person_prob > 0.5).astype(np.uint8) * 255
    return binary


# ---------------------------------------------------------------------------
# Pipeline stage 3 — extract_features
# ---------------------------------------------------------------------------

def extract_features(silhouette: "np.ndarray") -> "np.ndarray":
    """Extract a feature vector from a binary silhouette (224×224, uint8).

    Paper-faithful path (requires tensorflow/keras):
        Passes the silhouette (replicated to 3 channels, normalised) through
        a pretrained VGG16 backbone with the classification head removed,
        returning the 25088-dimensional feature vector (7×7×512 flattened).

    Fallback:
        Downscales the silhouette to 32×32 and flattens to a 1024-d vector.
    """
    _, keras = _try_import_keras()

    if keras is not None:
        try:
            return _features_vgg16(silhouette, keras)
        except Exception as exc:
            warnings.warn(
                f"VGG16 feature extraction failed ({exc}); falling back to "
                "32×32 flatten.",
                stacklevel=2,
            )

    # --- Fallback: 32×32 flatten ---
    pil = Image.fromarray(silhouette).resize((32, 32), Image.BILINEAR)
    arr = np.array(pil, dtype=np.float32) / 255.0
    return arr.flatten()


# Cache the VGG16 backbone so it is built ONCE and reused across every frame
# (rebuilding a ~500 MB network per image was catastrophic for RAM and speed).
_VGG16_CACHE: dict = {}


def _get_vgg16_backbone():
    """Lazily build and cache the frozen VGG16 backbone + preprocess_input."""
    if "backbone" not in _VGG16_CACHE:
        try:
            from tensorflow.keras.applications import VGG16
            from tensorflow.keras.applications.vgg16 import preprocess_input
        except ImportError:
            from keras.applications import VGG16
            from keras.applications.vgg16 import preprocess_input
        _VGG16_CACHE["backbone"] = VGG16(
            weights="imagenet", include_top=False, input_shape=(224, 224, 3))
        _VGG16_CACHE["preprocess_input"] = preprocess_input
    return _VGG16_CACHE["backbone"], _VGG16_CACHE["preprocess_input"]


def _features_vgg16(silhouette: "np.ndarray", keras) -> "np.ndarray":
    """VGG16 backbone features (paper-faithful, requires keras/tensorflow)."""
    backbone, preprocess_input = _get_vgg16_backbone()

    # Replicate single-channel silhouette to 3 channels (VGG16 expects RGB)
    rgb = np.stack([silhouette, silhouette, silhouette], axis=-1).astype(np.float32)

    # Resize to 224×224 if needed (should already be, but be safe)
    if rgb.shape[:2] != (224, 224):
        pil = Image.fromarray(rgb.astype(np.uint8)).resize((224, 224))
        rgb = np.array(pil, dtype=np.float32)

    x = preprocess_input(rgb[np.newaxis, ...])  # (1, 224, 224, 3)
    features = backbone.predict(x, verbose=0)  # (1, 7, 7, 512)
    return features.flatten()


def extract_features_batch(silhouettes: "list[np.ndarray]") -> "np.ndarray":
    """Batched extract_features(): runs VGG16 on N silhouettes in ONE
    forward pass instead of N. Returns (N, 25088) [paper-faithful] or
    (N, 1024) [fallback], numerically equivalent to calling
    extract_features() once per silhouette (verified by tests/
    test_hand_pipeline.py::TestBatchedInference) -- purely a speed
    optimization for bulk pre-caching (see fusion_pooled_train.py), not a
    behavior change. extract_features() itself is unchanged and still the
    right choice for a single silhouette.

    Falls back to `extract_features()` per silhouette (same as extract_
    features()'s own fallback trigger conditions) if keras/tensorflow are
    unavailable or the batched call fails for any reason -- a single
    malformed silhouette raises out of the batched keras call, so this
    fallback also protects against ANY batch containing a bad input, not
    just missing deps.
    """
    _, keras = _try_import_keras()
    if keras is not None:
        try:
            return _features_vgg16_batch(silhouettes, keras)
        except Exception as exc:
            warnings.warn(
                f"Batched VGG16 feature extraction failed ({exc}); "
                "falling back to extract_features() per image.",
                stacklevel=2,
            )
    return np.stack([extract_features(s) for s in silhouettes], axis=0)


def _features_vgg16_batch(silhouettes: "list[np.ndarray]", keras) -> "np.ndarray":
    """Batched VGG16 backbone features (paper-faithful path)."""
    backbone, preprocess_input = _get_vgg16_backbone()

    rgb_batch = []
    for silhouette in silhouettes:
        rgb = np.stack([silhouette, silhouette, silhouette], axis=-1).astype(np.float32)
        if rgb.shape[:2] != (224, 224):
            pil = Image.fromarray(rgb.astype(np.uint8)).resize((224, 224))
            rgb = np.array(pil, dtype=np.float32)
        rgb_batch.append(rgb)

    x = preprocess_input(np.stack(rgb_batch, axis=0))  # (N, 224, 224, 3)
    features = backbone.predict(x, verbose=0)  # (N, 7, 7, 512)
    return features.reshape(features.shape[0], -1)  # (N, 25088)


# ---------------------------------------------------------------------------
# IMU feature extraction (feature-level fusion, see --use-imu)
# ---------------------------------------------------------------------------

_warned_imu_reasons: set = set()


def imu_summary_features(imu_path: "str | None") -> "np.ndarray":
    """Return a 48-d float32 vector: [mean,std,min,max] per IMU channel,
    channels in _IMU_CHANNELS order (stats grouped per channel:
    ch0_mean,ch0_std,ch0_min,ch0_max, ch1_mean,...).

    imu_path None, missing file, unreadable, or header-only (no data rows)
    → zeros(48). Warns once per distinct failure reason. Reads the CSV with
    csv.DictReader; ignores unexpected extra columns; missing expected column
    → that channel's 4 stats are 0. Non-numeric cells are skipped per-cell.
    """
    def _warn_once(reason: str, msg: str) -> None:
        if reason not in _warned_imu_reasons:
            warnings.warn(msg, stacklevel=2)
            _warned_imu_reasons.add(reason)

    if not imu_path:
        _warn_once("no_path", "imu_summary_features: no IMU path provided for "
                   "one or more samples — using zeros(48).")
        return np.zeros(_IMU_FEATURE_DIM, dtype=np.float32)

    path = Path(imu_path)
    if not path.exists():
        _warn_once("missing_file", f"imu_summary_features: IMU file not found "
                   f"({path}) — using zeros(48) for affected samples.")
        return np.zeros(_IMU_FEATURE_DIM, dtype=np.float32)

    import csv as _csv

    channel_values: dict[str, list[float]] = {ch: [] for ch in _IMU_CHANNELS}
    try:
        with path.open(newline="", encoding="utf-8") as fh:
            reader = _csv.DictReader(fh)
            for row in reader:
                for ch in _IMU_CHANNELS:
                    raw = row.get(ch)
                    if raw is None:
                        continue
                    try:
                        channel_values[ch].append(float(raw))
                    except (ValueError, TypeError):
                        continue  # skip non-numeric cell
    except Exception as exc:
        _warn_once("unreadable", f"imu_summary_features: could not read IMU "
                   f"CSV ({path}): {exc} — using zeros(48).")
        return np.zeros(_IMU_FEATURE_DIM, dtype=np.float32)

    if all(len(v) == 0 for v in channel_values.values()):
        _warn_once("header_only", f"imu_summary_features: IMU CSV has no "
                   f"data rows ({path}) — using zeros(48).")
        return np.zeros(_IMU_FEATURE_DIM, dtype=np.float32)

    stats: list[float] = []
    for ch in _IMU_CHANNELS:
        vals = channel_values[ch]
        if not vals:
            stats.extend([0.0, 0.0, 0.0, 0.0])
            continue
        arr = np.array(vals, dtype=np.float64)
        stats.extend([
            float(np.mean(arr)),
            float(np.std(arr, ddof=0)),
            float(np.min(arr)),
            float(np.max(arr)),
        ])

    return np.array(stats, dtype=np.float32)


# ---------------------------------------------------------------------------
# Pipeline stage 4 — train
# ---------------------------------------------------------------------------

def train(features: "np.ndarray", labels: list[str], epochs: int = _DEFAULT_EPOCHS) -> object:
    """Train a holding-hand classifier.

    Parameters
    ----------
    features : np.ndarray, shape (N, D)
    labels   : list of str, length N
    epochs   : int, number of training epochs (default 2, paper-faithful)

    Returns a fitted model object.

    Paper-faithful path (requires tensorflow/keras):
        HandyNet: frozen VGG16 backbone + Flatten + Dropout(0.5) + Dense(3,
        activation='softmax').  This is the architecture described in the
        HandyTrak paper.

    Fallback 1 (requires scikit-learn):
        LogisticRegression with l-bfgs solver, max_iter=1000.

    Fallback 2 (pure numpy):
        Nearest-centroid classifier — computes per-class feature centroids and
        assigns test points to the nearest centroid by Euclidean distance.
        This always runs successfully and is the guaranteed fallback.
    """
    unique_labels = sorted(set(labels))
    label_to_idx = {l: i for i, l in enumerate(unique_labels)}
    y = np.array([label_to_idx[l] for l in labels])

    _, keras = _try_import_keras()
    if keras is not None:
        try:
            return _train_handynet(features, y, unique_labels, keras, epochs=epochs)
        except Exception as exc:
            warnings.warn(
                f"HandyNet training failed ({exc}); falling back to "
                "LogisticRegression or nearest-centroid.",
                stacklevel=2,
            )

    LogisticRegression = _try_import_sklearn()
    if LogisticRegression is not None:
        try:
            clf = LogisticRegression(max_iter=1000, multi_class="multinomial",
                                     solver="lbfgs")
            clf.fit(features, y)
            clf._hand_classes = unique_labels  # store for prediction
            print(f"Trained LogisticRegression  (n={len(labels)}, "
                  f"classes={unique_labels})")
            return clf
        except Exception as exc:
            warnings.warn(
                f"LogisticRegression failed ({exc}); falling back to "
                "nearest-centroid.",
                stacklevel=2,
            )

    # --- Fallback 2: nearest-centroid (pure numpy) ---
    return _train_nearest_centroid(features, y, unique_labels)


def _train_handynet(features, y, unique_labels, keras, epochs: int = _DEFAULT_EPOCHS):
    """HandyNet: frozen VGG16 + Flatten + Dropout(0.5) + softmax-3.

    batch_size=32 and epochs=2 are the paper-faithful values (HandyTrak §4.1).
    """
    try:
        from tensorflow.keras.applications import VGG16
        from tensorflow import keras as tfkeras
        Dropout = tfkeras.layers.Dropout
        Dense = tfkeras.layers.Dense
        Flatten = tfkeras.layers.Flatten
        Model = tfkeras.Model
        Input = tfkeras.Input
    except ImportError:
        from keras.applications import VGG16
        from keras.layers import Dropout, Dense, Flatten, Input
        from keras import Model

    # The features passed here are already the VGG16 backbone outputs (flattened),
    # so HandyNet's classification head is a simple MLP on top.
    n_classes = len(unique_labels)
    n_features = features.shape[1]

    try:
        from tensorflow import keras as tfkeras
        inp = tfkeras.Input(shape=(n_features,))
        x = tfkeras.layers.Dropout(0.5)(inp)
        out = tfkeras.layers.Dense(n_classes, activation="softmax")(x)
        model = tfkeras.Model(inputs=inp, outputs=out)
        model.compile(optimizer="adam",
                      loss="sparse_categorical_crossentropy",
                      metrics=["accuracy"])
    except Exception:
        import keras as k
        inp = k.Input(shape=(n_features,))
        x = k.layers.Dropout(0.5)(inp)
        out = k.layers.Dense(n_classes, activation="softmax")(x)
        model = k.Model(inputs=inp, outputs=out)
        model.compile(optimizer="adam",
                      loss="sparse_categorical_crossentropy",
                      metrics=["accuracy"])

    # Paper values: batch_size=32, epochs=2 (HandyTrak §4.1)
    model.fit(features, y, epochs=epochs, batch_size=32, verbose=0)
    model._hand_classes = unique_labels
    print(f"Trained HandyNet head  (n={len(y)}, classes={unique_labels}, "
          f"epochs={epochs}, batch_size=32)")
    return model


class _NearestCentroidClassifier:
    """Pure-numpy nearest-centroid classifier (guaranteed fallback)."""

    def __init__(self, centroids: "np.ndarray", classes: list[str]) -> None:
        self.centroids = centroids
        self.classes = classes
        self._hand_classes = classes

    def predict(self, X: "np.ndarray") -> "np.ndarray":
        dists = np.linalg.norm(X[:, np.newaxis, :] - self.centroids[np.newaxis, :, :], axis=2)
        return np.array([self.classes[i] for i in np.argmin(dists, axis=1)])

    def score(self, X: "np.ndarray", y_labels: list[str]) -> float:
        preds = self.predict(X)
        return float(np.mean(preds == np.array(y_labels)))


def _train_nearest_centroid(
    features: "np.ndarray",
    y: "np.ndarray",
    unique_labels: list[str],
) -> _NearestCentroidClassifier:
    centroids = []
    for idx in range(len(unique_labels)):
        mask = y == idx
        centroid = features[mask].mean(axis=0) if mask.any() else np.zeros(features.shape[1])
        centroids.append(centroid)
    centroids_arr = np.stack(centroids, axis=0)
    clf = _NearestCentroidClassifier(centroids_arr, unique_labels)
    print(f"Trained nearest-centroid  (n={len(y)}, classes={unique_labels})")
    return clf


# ---------------------------------------------------------------------------
# Accuracy helpers
# ---------------------------------------------------------------------------

def _predict_labels(model, features: "np.ndarray") -> list[str]:
    """Decode model predictions to a list of string labels.

    Handles _NearestCentroidClassifier (string array), keras softmax output
    (N, C float array → argmax → classes list), and sklearn integer predictions.
    """
    if isinstance(model, _NearestCentroidClassifier):
        return list(model.predict(features))

    preds_raw = model.predict(features)
    preds_arr = np.array(preds_raw)

    if preds_arr.ndim == 2:
        # keras softmax output: shape (N, C)
        pred_indices = preds_arr.argmax(axis=1)
        classes = model._hand_classes
        return [classes[i] for i in pred_indices]
    elif preds_arr.dtype.kind in ("i", "u"):
        # sklearn integer predictions
        classes = model._hand_classes
        return [classes[i] for i in preds_arr]
    else:
        # string predictions (e.g. _NearestCentroidClassifier on older path)
        return list(preds_arr)


def _per_class_and_confusion(
    true_labels: list[str],
    pred_labels: list[str],
    classes: list[str],
) -> tuple[dict[str, float], dict[tuple[str, str], int]]:
    """Return (per_class_recall, confusion).

    per_class_recall: {class -> accuracy among frames whose TRUE label is class}.
    confusion:        {(true_label, pred_label) -> count}.
    """
    confusion: dict[tuple[str, str], int] = {}
    correct = {c: 0 for c in classes}
    total   = {c: 0 for c in classes}
    for t, p in zip(true_labels, pred_labels):
        confusion[(t, p)] = confusion.get((t, p), 0) + 1
        if t in total:
            total[t] += 1
            if t == p:
                correct[t] += 1
    per_class = {
        c: (correct[c] / total[c] if total[c] else float("nan"))
        for c in classes
    }
    return per_class, confusion


def _compute_accuracy(model, features: "np.ndarray", labels: list[str]) -> float:
    """Return accuracy for the fitted *model* on the given features/labels."""
    try:
        pred_labels = _predict_labels(model, features)
        return float(np.mean(np.array(pred_labels) == np.array(labels)))
    except Exception as exc:
        warnings.warn(f"Could not compute accuracy: {exc}", stacklevel=2)
        return float("nan")


# ---------------------------------------------------------------------------
# Section 1c — time-ordered per-condition split (UNSHUFFLED)
# ---------------------------------------------------------------------------

def split_train_eval_indices(
    sort_keys: list,
    labels: list[str],
    train_frac: float = 0.8,
) -> tuple[list[int], list[int]]:
    """Return (train_idx, eval_idx) as lists of integer indices into the sample arrays.

    HandyTrak split: per CONDITION (label value), take the first `train_frac`
    of frames IN TIME ORDER as train and the remaining last (1-train_frac) as
    eval.  NO shuffling.  Frames within a condition are ordered by `sort_keys`.

    sort_keys : list of comparable tuples, one per sample, defining time order.
    labels    : list[str] parallel to sort_keys (already excludes 'unknown').
    train_frac: fraction of each condition's frames used for training.

    Edge cases:
    - A condition with < 2 frames → all frames go to TRAIN (cannot form an eval
      split); a UserWarning is emitted.
    - Empty input → returns ([], []).
    """
    if not sort_keys:
        return [], []

    from collections import defaultdict
    condition_indices: dict[str, list[int]] = defaultdict(list)
    for i, lbl in enumerate(labels):
        condition_indices[lbl].append(i)

    train_idx: list[int] = []
    eval_idx:  list[int] = []

    for cond, indices in condition_indices.items():
        # Sort indices by their sort_key (time order)
        sorted_indices = sorted(indices, key=lambda i: sort_keys[i])
        n = len(sorted_indices)
        if n < 2:
            warnings.warn(
                f"Condition '{cond}' has only {n} frame(s) — all go to TRAIN; "
                "no eval frames for this condition.",
                stacklevel=2,
            )
            train_idx.extend(sorted_indices)
        else:
            split_at = math.floor(n * train_frac)
            # Guard: if floor gives 0 (n==1 already handled above), push 1 to train
            if split_at == 0:
                split_at = 1
            train_idx.extend(sorted_indices[:split_at])
            eval_idx.extend(sorted_indices[split_at:])

    return train_idx, eval_idx


# ---------------------------------------------------------------------------
# Section 1d — 2 Hz sliding-window + majority-vote evaluation
# ---------------------------------------------------------------------------

def sliding_window_majority_vote(
    per_frame_pred_labels: list[str],
    window_size: int = 30,
) -> list[str]:
    """Collapse per-frame predicted labels into per-window labels via majority vote.

    Returns list[str] of length max(0, len(per_frame_pred_labels) - window_size + 1)
    (one label per sliding window, stride 1).  Tie-break: choose the label that
    is alphabetically first among the tied maxima (deterministic).

    This is the paper's runtime aggregation (size-30 window over the 2 Hz
    frame stream, HandyTrak §4.2).
    """
    n = len(per_frame_pred_labels)
    if n < window_size:
        if n > 0:
            warnings.warn(
                f"sliding_window_majority_vote: only {n} frames but "
                f"window_size={window_size} — no windows produced.",
                stacklevel=2,
            )
        return []

    result: list[str] = []
    for start in range(n - window_size + 1):
        window = per_frame_pred_labels[start: start + window_size]
        # Count votes
        counts: dict[str, int] = {}
        for lbl in window:
            counts[lbl] = counts.get(lbl, 0) + 1
        max_count = max(counts.values())
        # Tie-break: alphabetically first among tied labels
        majority = min(lbl for lbl, c in counts.items() if c == max_count)
        result.append(majority)
    return result


def windowed_accuracy(
    per_frame_pred_labels: list[str],
    per_frame_true_labels: list[str],
    window_size: int = 30,
) -> float:
    """Window-level accuracy: a window is correct if its majority-vote label
    equals the majority of the TRUE labels in that same window.

    Returns float in [0, 1] (nan if no windows).  Used to report the
    paper-style windowed accuracy (HandyTrak §4.2).
    """
    n = len(per_frame_pred_labels)
    if n < window_size:
        if n > 0:
            warnings.warn(
                f"windowed_accuracy: only {n} frames but window_size={window_size} "
                "— returning nan.",
                stacklevel=2,
            )
        return float("nan")

    pred_windows  = sliding_window_majority_vote(per_frame_pred_labels, window_size)
    true_windows  = sliding_window_majority_vote(per_frame_true_labels, window_size)

    if not pred_windows:
        return float("nan")

    correct = sum(p == t for p, t in zip(pred_windows, true_windows))
    return correct / len(pred_windows)


# ---------------------------------------------------------------------------
# Section 1e — Option C centroid baseline (zero-training, geometric)
# ---------------------------------------------------------------------------

def centroid_baseline_predict(
    silhouette: "np.ndarray",
    left_thresh:  float = _CENTROID_LEFT_THRESH,
    right_thresh: float = _CENTROID_RIGHT_THRESH,
) -> str:
    """Zero-training geometric baseline (HandyTrak sanity check, NOT the paper classifier).

    Compute the horizontal centroid (normalized x in [0, 1]) of foreground
    (==255) pixels in the binary silhouette (224x224 uint8).  Map:
        centroid_x < left_thresh  -> 'right'   (body leans right of frame =>
                                       phone in right hand pulls torso; see note)
        centroid_x > right_thresh -> 'left'
        otherwise                 -> 'both'
    Returns one of 'left' / 'right' / 'both'.

    NOTE on left/right mapping: this is a HEURISTIC and the front camera mirrors
    the image.  Do NOT over-invest in which side is which.  The baseline's job
    is a SEPARABILITY SANITY CHECK (does centroid-x carry signal?), not accuracy.
    Thresholds are exposed as module constants _CENTROID_LEFT_THRESH /
    _CENTROID_RIGHT_THRESH and can be overridden for experimentation.

    Empty silhouette (no foreground pixels) -> 'both', with a UserWarning.
    """
    fg_pixels = np.argwhere(silhouette == 255)  # shape (N, 2): rows are (row, col)
    if fg_pixels.size == 0:
        warnings.warn(
            "centroid_baseline_predict: silhouette has no foreground pixels; "
            "returning 'both'.",
            stacklevel=2,
        )
        return "both"

    # Normalized horizontal centroid (column direction)
    h, w = silhouette.shape
    centroid_x = float(fg_pixels[:, 1].mean()) / w

    if centroid_x < left_thresh:
        return "right"
    elif centroid_x > right_thresh:
        return "left"
    else:
        return "both"


def centroid_baseline_eval(
    silhouettes: list["np.ndarray"],
    true_labels: list[str],
) -> tuple[float, dict]:
    """Evaluate the centroid baseline on a list of silhouettes.

    Returns:
        accuracy (float): frame-level accuracy in [0, 1].
        confusion (dict): {(true_label, pred_label): count} summary.
    """
    if not silhouettes:
        return float("nan"), {}

    pred_labels = [centroid_baseline_predict(s) for s in silhouettes]
    confusion: dict[tuple[str, str], int] = {}
    for t, p in zip(true_labels, pred_labels):
        key = (t, p)
        confusion[key] = confusion.get(key, 0) + 1

    correct = sum(t == p for t, p in zip(true_labels, pred_labels))
    accuracy = correct / len(true_labels)
    return accuracy, confusion


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def _group_by_participant(records: list[dict]) -> "dict[str, list[int]]":
    """Return {participant_key -> [record indices]}, used by the --imu-seq
    all-zero-IMU sanity check in main()."""
    from collections import defaultdict
    out: dict[str, list[int]] = defaultdict(list)
    for i, rec in enumerate(records):
        out[rec["participant_key"]].append(i)
    return dict(out)


def _save_model(model, out_dir: Path) -> None:
    """Save model to out_dir as .keras or .pkl."""
    model_path_keras = out_dir / "hand_model.keras"
    model_path_pkl   = out_dir / "hand_model.pkl"
    saved = False

    _, keras_mod = _try_import_keras()
    if keras_mod is not None and hasattr(model, "save"):
        try:
            model.save(str(model_path_keras))
            print(f"    Model saved to: {model_path_keras}  (keras format)")
            saved = True
        except Exception as exc:
            warnings.warn(f"keras .save() failed ({exc}); using pickle.", stacklevel=2)

    if not saved:
        with model_path_pkl.open("wb") as fh:
            pickle.dump(model, fh)
        print(f"    Model saved to: {model_path_pkl}  (pickle format)")


def _run_pooled_and_louo(
    records: "list[dict]",
    participant_to_indices: "dict[str, list[int]]",
    features_arr: "np.ndarray",
    train_frac: float,
    epochs: int,
    out_dir: Path,
    do_pooled: bool,
    do_louo: bool,
) -> None:
    """Pooled + leave-one-user-out (LOUO) training for the IMU-sequence model.
    See docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md
    "Evaluation protocol". Reuses split_train_eval_indices per participant
    (same 80/20 time-ordered convention as the per-participant loop above)
    to get each participant's own train split, then unions those splits
    across participants for pooled training and leave-one-user-out training.

    The two modes use DIFFERENT, deliberately-different eval sets per
    participant — participant_splits stores both:
      - Pooled evaluates each participant on their own LOCAL 20% held-out
        split (`abs_eval` below) — the same held-out frames excluded from
        that participant's contribution to `abs_train`. This is a
        continuity/sanity number, not a genuinely "unseen" one: the pooled
        model still saw OTHER frames from the same participant during
        training (just not these specific eval frames). Using the
        participant's FULL known set here instead would leak, since
        `abs_train` is a subset of that full set and the pooled model would
        then be evaluated on data it was directly trained on.
      - LOUO evaluates the held-out participant on their FULL data (`known`
        below, 100% unseen) since no data from that participant appears
        anywhere in that round's training set (all training data comes from
        OTHER participants). This is the decision-relevant, genuinely-unseen
        number, matching cross_user_eval.py's "MOCK USER" evaluation.
    """
    import window_grid
    import imu_sequence

    participant_splits: "dict[str, tuple[list[int], list[int], list[int]]]" = {}
    for p_key, p_indices in participant_to_indices.items():
        known = [i for i in p_indices if records[i]["label"] != "unknown"]
        if not known:
            continue
        labels_ = [records[i]["label"] for i in known]
        keys_ = [records[i]["sort_key"] for i in known]
        local_train, local_eval = split_train_eval_indices(keys_, labels_, train_frac=train_frac)
        train_labels_here = [labels_[li] for li in local_train]
        if len(set(train_labels_here)) < 2:
            print(f"  pooled/LOUO: skipping participant {p_key!r} "
                  "(< 2 distinct labels in its train split)")
            continue
        abs_train = [known[li] for li in local_train]
        abs_eval = [known[li] for li in local_eval]
        participant_splits[p_key] = (abs_train, abs_eval, known)

    if len(participant_splits) < 2:
        print("  pooled/LOUO: fewer than 2 usable participants — skipping "
              "(pooling/LOUO requires at least 2).")
        return

    def _train_and_eval(train_idx: "list[int]", eval_idx: "list[int]", tag: str) -> dict:
        train_labels = [records[i]["label"] for i in train_idx]
        model = imu_sequence.train_imu_sequence_model(
            features_arr[train_idx], train_labels, epochs=epochs
        )
        eval_labels = [records[i]["label"] for i in eval_idx]
        eval_preds = _predict_labels(model, features_arr[eval_idx])
        frame_acc = float(np.mean(np.array(eval_preds) == np.array(eval_labels)))
        grid = window_grid.sweep_window_sizes(records, eval_idx, eval_preds, eval_labels)
        selected = window_grid.select_window(grid)
        win_acc = grid[selected] if selected is not None else float("nan")
        print(f"  [{tag}] n_train={len(train_idx)} n_eval={len(eval_idx)} "
              f"frame-acc={frame_acc:.3f} windowed-acc={_fmt(win_acc)} "
              f"(selected window={selected}s)")
        print("    grid: " + ", ".join(f"{s}s={_fmt(a)}" for s, a in sorted(grid.items())))
        return {"model": model}

    if do_pooled:
        print("\n=== Pooled (IMU-only) ===")
        pooled_train_idx = [i for (t, _e, _k) in participant_splits.values() for i in t]
        pooled_eval_idx = [i for (_t, e, _k) in participant_splits.values() for i in e]
        assert not (set(pooled_train_idx) & set(pooled_eval_idx)), (
            "pooled eval set must not overlap pooled train set"
        )
        result = _train_and_eval(pooled_train_idx, pooled_eval_idx,
                                  "pooled (own held-out per participant)")
        p_out_dir = out_dir / "pooled_"
        p_out_dir.mkdir(parents=True, exist_ok=True)
        unique_labels_p = sorted(set(records[i]["label"] for i in pooled_train_idx))
        with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
            json.dump(unique_labels_p, fh, indent=2)
        _save_model(result["model"], p_out_dir)
        print(f"  Pooled model saved to: {p_out_dir}")

    if do_louo:
        print("\n=== Leave-one-user-out (IMU-only) ===")
        for held_out_key in sorted(participant_splits):
            train_idx = [
                i for p_key, (t, _e, _k) in participant_splits.items()
                if p_key != held_out_key for i in t
            ]
            eval_idx = participant_splits[held_out_key][2]  # FULL data, 100% unseen
            result = _train_and_eval(train_idx, eval_idx, f"LOUO held_out={held_out_key!r}")
            safe_key = re.sub(r"[^a-z0-9]+", "_", held_out_key) or "participant"
            p_out_dir = out_dir / f"louo_{safe_key}"
            p_out_dir.mkdir(parents=True, exist_ok=True)
            unique_labels_p = sorted(set(records[i]["label"] for i in train_idx))
            with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
                json.dump(unique_labels_p, fh, indent=2)
            _save_model(result["model"], p_out_dir)
            print(f"  LOUO model (held out {held_out_key!r}) saved to: {p_out_dir}")


def main() -> None:
    args = _parse_args()

    # ---- Paper-faithful / fallback banner ----
    torch_ok = _try_import_torch()[0] is not None
    keras_ok  = _try_import_keras()[1] is not None
    if torch_ok and keras_ok:
        print("[PAPER-FAITHFUL] torch + tensorflow/keras both importable — "
              "FCN-ResNet101 segmentation and VGG16 HandyNet will be used.")
    else:
        missing = []
        if not torch_ok:
            missing.append("torch/torchvision")
        if not keras_ok:
            missing.append("tensorflow/keras")
        print(f"[FALLBACK — not paper results] Missing: {', '.join(missing)}. "
              "Lightweight substitutes will run.")

    # --imu-seq wins over --use-imu when both are passed (mutually informative,
    # not mutually exclusive at the parser level — resolved here per the spec).
    if args.imu_seq and args.use_imu:
        warnings.warn(
            "--imu-seq and --use-imu both passed; --imu-seq wins (the "
            "windowed IMU-sequence model is used; the 48-d IMU summary fusion "
            "path with image features is skipped).",
            stacklevel=2,
        )

    if (args.pooled or args.pooled_louo) and not args.imu_seq:
        print("Error: --pooled/--pooled-louo require --imu-seq (pooled "
              "training is only implemented for the IMU-sequence model).")
        sys.exit(1)

    # IMU fusion banner. NOTE: `_write_markdown_results` keeps only the single
    # BEST run by windowed accuracy — an image+IMU run and an image-only run
    # compete for the same block. To compare both, use DIFFERENT --md-out
    # paths (or --out dirs) for the two runs. (Same gotcha applies to
    # --imu-seq runs vs. image-only/fusion runs.)
    if args.imu_seq:
        print(f"IMU sequence model: ON (window={args.imu_window}, "
              f"causal={args.imu_causal})")
    elif args.use_imu:
        print(f"IMU fusion: ON ({_IMU_FEATURE_DIM}-d)")
    else:
        print("IMU fusion: OFF")

    if args.demo:
        print("\n-- demo mode: generating synthetic manifest and images --")
        tmp = Path(tempfile.mkdtemp(prefix="train_hand_demo_"))
        manifest_path, images_root = _make_demo_manifest_and_images(tmp)
        out_dir = tmp / "model"
        print(f"Manifest : {manifest_path}")
        print(f"Images   : {images_root}")
        print(f"Model out: {out_dir}")
    else:
        if not args.manifest:
            print("Error: provide a manifest CSV path, or use --demo")
            sys.exit(1)
        manifest_path = args.manifest
        images_root = args.images_root
        out_dir = Path(args.out)

    out_dir.mkdir(parents=True, exist_ok=True)

    mode        = args.mode
    train_frac  = args.train_frac
    window_size = args.window_size
    epochs      = args.epochs
    md_out      = args.md_out

    # ---- Step 1: Load dataset records ----
    records = load_dataset_records(manifest_path, images_root)

    if not records:
        print("No samples loaded. Exiting.")
        sys.exit(0)

    print(f"\nLoaded {len(records)} records from manifest")

    # ---- --imu-seq: build the windowed IMU-sequence feature array directly,
    # skipping preprocess/segment/VGG entirely (the slow stages). `mode` is
    # forced to "handynet" for the rest of main() since the IMU-sequence model
    # occupies the same "Option B" slot as HandyNet — no image features and
    # no silhouettes are needed (centroid baseline is image-only, so --mode
    # centroid/both would have nothing to evaluate under --imu-seq; the value
    # is overridden with a printed note rather than erroring).
    if args.imu_seq:
        import imu_sequence

        if mode != "handynet":
            print(f"  --imu-seq: overriding --mode {mode!r} -> 'handynet' "
                  "(the centroid baseline is image-only and has nothing to "
                  "evaluate under --imu-seq).")
            mode = "handynet"

        print(f"Stage 1-3 (skipped) — building IMU-sequence windows "
              f"(window={args.imu_window}, causal={args.imu_causal}) ...")
        features_arr, _seq_labels, _seq_sort_keys = imu_sequence.build_sequence_dataset(
            records, window=args.imu_window, causal=args.imu_causal
        )
        silhouettes: list = []
        need_features = True
        need_silhouettes = False
        print(f"  built {features_arr.shape[0]} windows of shape "
              f"{features_arr.shape[1:]}")

        # Flag participants whose IMU is entirely zero (all-missing) — a
        # zero-variance feature gives chance accuracy but must not crash.
        for p_key, p_idx in _group_by_participant(records).items():
            if all(not np.any(features_arr[i]) for i in p_idx):
                print(f"  NOTE: participant {p_key!r} has ALL-ZERO IMU "
                      "windows (no readable IMU for any frame) — training "
                      "will run but expect chance-level accuracy.")
    else:
        # ---- Steps 2+3: preprocess -> segment -> features, streamed per frame ----
        # Each frame is processed end-to-end and its large float image discarded
        # immediately, so peak RAM holds only the compact silhouettes/features —
        # not all raw 224x224x3 float arrays at once. Silhouettes are kept only when
        # the centroid baseline needs them; features only for the HandyNet path.
        need_features = mode in ("handynet", "both")
        need_silhouettes = mode in ("centroid", "both")
        print("Stage 1-3 — preprocess, segment"
              + (", extract features" if need_features else "") + " ...")

        silhouettes = []
        feature_list: list = []
        n_records = len(records)
        for i, r in enumerate(records):
            img = preprocess(r["image_path"])
            sil = segment(img)
            del img
            if need_silhouettes:
                silhouettes.append(sil)
            if need_features:
                img_feat = extract_features(sil)
                if args.use_imu:
                    imu_feat = imu_summary_features(r.get("imu_path"))
                    feat = np.concatenate([img_feat, imu_feat])
                else:
                    feat = img_feat
                feature_list.append(feat)
            if (i + 1) % 50 == 0 or (i + 1) == n_records:
                print(f"  processed {i + 1}/{n_records} frames", flush=True)

        features_arr = np.stack(feature_list, axis=0) if need_features else None

    # ---- Step 4: Group by participant ----
    from collections import defaultdict
    participant_to_indices: dict[str, list[int]] = defaultdict(list)
    for i, rec in enumerate(records):
        participant_to_indices[rec["participant_key"]].append(i)

    print(f"\nFound {len(participant_to_indices)} participant(s).\n")

    # ---- Step 5: Per-participant loop ----
    summary_rows: list[dict] = []

    for p_num, (p_key, p_indices) in enumerate(sorted(participant_to_indices.items())):
        # Sanitize key for filesystem use
        safe_key = re.sub(r"[^a-z0-9]+", "_", p_key)
        if not safe_key:
            safe_key = f"participant_{p_num}"

        print(f"=== Participant: {p_key!r}  (fs key: {safe_key!r}) ===")

        # Filter out 'unknown' labels
        known_indices = [i for i in p_indices if records[i]["label"] != "unknown"]
        if not known_indices:
            warnings.warn(
                f"participant {p_key!r}: no known-label samples — skipping.",
                stacklevel=2,
            )
            continue

        p_labels   = [records[i]["label"]    for i in known_indices]
        p_sort_keys = [records[i]["sort_key"] for i in known_indices]

        # Time-ordered split
        local_train, local_eval = split_train_eval_indices(
            p_sort_keys, p_labels, train_frac=train_frac
        )

        if not local_train:
            warnings.warn(
                f"participant {p_key!r}: empty train set — skipping.",
                stacklevel=2,
            )
            continue

        # Check distinct labels in train set
        train_labels_list = [p_labels[li] for li in local_train]
        if len(set(train_labels_list)) < 2:
            warnings.warn(
                f"participant {p_key!r}: < 2 distinct labels in train set "
                f"({set(train_labels_list)}) — skipping.",
                stacklevel=2,
            )
            continue

        eval_labels_list = [p_labels[li] for li in local_eval]

        # Absolute indices into the global arrays
        abs_train = [known_indices[li] for li in local_train]
        abs_eval  = [known_indices[li] for li in local_eval]

        n_train = len(abs_train)
        n_eval  = len(abs_eval)
        print(f"  n_train={n_train}  n_eval={n_eval}")

        p_out_dir = out_dir / safe_key
        p_out_dir.mkdir(parents=True, exist_ok=True)

        row: dict = {
            "participant":          p_key,
            "n_train":              n_train,
            "n_eval":               n_eval,
            "handynet_train_acc":   float("nan"),
            "handynet_frame_acc":   float("nan"),
            "handynet_windowed_acc": float("nan"),
            "centroid_frame_acc":   float("nan"),
            "imu_fusion":           bool(args.use_imu),
            "imu_seq":              bool(args.imu_seq),
        }

        # ---- Option B: HandyNet (image) OR IMU-sequence model (--imu-seq) ----
        # Both occupy the same "Option B" slot in the row/summary/markdown
        # writers below (handynet_* keys are reused for the IMU-sequence
        # model's metrics too, so the existing summary/markdown code needs no
        # changes — see the D1 spec's "reuse unchanged" instruction).
        if mode in ("handynet", "both") and features_arr is not None:
            train_feats = features_arr[abs_train]
            if args.imu_seq:
                model = imu_sequence.train_imu_sequence_model(
                    train_feats, train_labels_list, epochs=epochs
                )
            else:
                model = train(train_feats, train_labels_list, epochs=epochs)

            # Save model + labels
            unique_labels_p = sorted(set(train_labels_list))
            labels_path = p_out_dir / "labels.json"
            with labels_path.open("w", encoding="utf-8") as fh:
                json.dump(unique_labels_p, fh, indent=2)
            _save_model(model, p_out_dir)

            # TRAIN accuracy (in-sample) — for the train-vs-test overfitting gap
            train_preds = _predict_labels(model, train_feats)
            train_acc = float(np.mean(
                np.array(train_preds) == np.array(train_labels_list)
            ))
            row["handynet_train_acc"] = train_acc
            print(f"  HandyNet  TRAIN  frame-acc={train_acc:.3f}"
                  f"  (in-sample, n={n_train})")

            if abs_eval:
                eval_feats  = features_arr[abs_eval]
                eval_preds  = _predict_labels(model, eval_feats)
                frame_acc   = float(np.mean(
                    np.array(eval_preds) == np.array(eval_labels_list)
                ))
                win_acc = windowed_accuracy(eval_preds, eval_labels_list,
                                            window_size=window_size)
                row["handynet_frame_acc"]    = frame_acc
                row["handynet_windowed_acc"] = win_acc

                # Per-class accuracy (recall) + confusion on the held-out TEST set
                per_class, confusion = _per_class_and_confusion(
                    eval_labels_list, eval_preds, unique_labels_p
                )
                row["handynet_per_class_acc"] = per_class
                row["handynet_confusion"] = {
                    f"{t}->{p}": n for (t, p), n in confusion.items()
                }

                print(f"  HandyNet  TEST   frame-acc={frame_acc:.3f}  "
                      f"windowed-acc={_fmt(win_acc)}  (held-out, n={n_eval})")
                print("            TEST   per-class acc: " + ", ".join(
                    f"{c}={_fmt(per_class[c])}" for c in unique_labels_p))
                print("            TEST   confusion (true->pred): " + ", ".join(
                    f"{t}->{p}:{n}" for (t, p), n in sorted(confusion.items())))
                print(f"            overfit gap (train - test frame-acc) = "
                      f"{train_acc - frame_acc:+.3f}")
            else:
                print("  HandyNet  (no eval frames)")

        # ---- Option C: Centroid baseline ----
        if mode in ("centroid", "both"):
            eval_sils = [silhouettes[i] for i in abs_eval] if abs_eval else []
            if eval_sils:
                c_acc, c_conf = centroid_baseline_eval(eval_sils, eval_labels_list)
                row["centroid_frame_acc"] = c_acc
                print(f"  Centroid  frame-acc={c_acc:.3f}  "
                      f"confusion={c_conf}")
            else:
                print("  Centroid  (no eval frames)")

        summary_rows.append(row)
        print()

    # ---- Step 6: Aggregate summary ----
    if not summary_rows:
        print("No participants had sufficient data. Nothing to summarise.")
        return

    # HN-tr = HandyNet train (in-sample) acc; HN-fr/HN-win = held-out TEST acc;
    # Cnt-fr = centroid baseline (test). Compare HN-tr vs HN-fr for overfitting.
    print("=" * 72)
    print(f"{'Participant':<22} {'n_tr':>5} {'n_ev':>5} "
          f"{'HN-tr':>7} {'HN-fr':>7} {'HN-win':>7} {'Cnt-fr':>7}")
    print("-" * 72)
    for row in summary_rows:
        print(
            f"{row['participant']:<22} "
            f"{row['n_train']:>5} "
            f"{row['n_eval']:>5} "
            f"{_fmt(row.get('handynet_train_acc', float('nan'))):>7} "
            f"{_fmt(row['handynet_frame_acc']):>7} "
            f"{_fmt(row['handynet_windowed_acc']):>7} "
            f"{_fmt(row['centroid_frame_acc']):>7}"
        )

    # Mean row (over participants with non-nan values)
    def _nanmean(vals):
        v = [x for x in vals if not math.isnan(x)]
        return sum(v) / len(v) if v else float("nan")

    print("-" * 72)
    print(
        f"{'MEAN':<22} "
        f"{sum(r['n_train'] for r in summary_rows):>5} "
        f"{sum(r['n_eval']  for r in summary_rows):>5} "
        f"{_fmt(_nanmean([r.get('handynet_train_acc', float('nan')) for r in summary_rows])):>7} "
        f"{_fmt(_nanmean([r['handynet_frame_acc']    for r in summary_rows])):>7} "
        f"{_fmt(_nanmean([r['handynet_windowed_acc'] for r in summary_rows])):>7} "
        f"{_fmt(_nanmean([r['centroid_frame_acc']    for r in summary_rows])):>7}"
    )
    print("=" * 72)
    print("HN-tr=train(in-sample)  HN-fr/HN-win=held-out TEST  Cnt-fr=centroid baseline")

    summary_path = out_dir / "summary.json"
    with summary_path.open("w", encoding="utf-8") as fh:
        json.dump(summary_rows, fh, indent=2, default=str)
    print(f"\nSummary written to: {summary_path}")

    if md_out:
        if _write_markdown_results(Path(md_out), summary_rows, mode, epochs, _nanmean,
                                   imu_fusion=args.use_imu):
            print(f"Results chart written to: {md_out}")

    if args.imu_seq and (args.pooled or args.pooled_louo):
        _run_pooled_and_louo(
            records, participant_to_indices, features_arr,
            train_frac, epochs, out_dir, args.pooled, args.pooled_louo,
        )

    print("\nFuture work:")
    print("  - On-device Core ML conversion")
    print("  - Landscape-mode capture")


def _fmt(v: float) -> str:
    """Format float for the summary table; 'nan' if not a number."""
    return f"{v:.3f}" if not math.isnan(v) else "   nan"


def _write_markdown_results(md_path, summary_rows, mode, epochs, nanmean,
                            imu_fusion: bool = False) -> None:
    """Write/update an auto-generated results chart in a markdown file.

    Only the single BEST run is kept: the section records the run with the
    highest mean held-out windowed accuracy. A new run overwrites the block
    only when it beats the recorded best (parsed from an embedded score tag);
    otherwise the file is left untouched. The chart lives between HTML-comment
    markers so the rest of the file (hand-written notes) stays intact. If the
    markers are absent, the section is appended; if the file does not exist, it
    is created.

    NOTE: because only the single best run is kept, an image+IMU run and an
    image-only run compete for the same block — use different --md-out paths
    (or --out dirs) to compare both (see the fusion banner comment in main()).
    """
    import re
    from datetime import datetime, timezone

    START = "<!-- TRAIN_RESULTS_START -->"
    END   = "<!-- TRAIN_RESULTS_END -->"
    SCORE_TAG = "BEST_WINDOWED_ACC="
    md_path = Path(md_path)

    def _pct(v: float) -> str:
        return f"{v * 100:.1f}%" if not math.isnan(v) else "nan"

    cur_score = nanmean([r['handynet_windowed_acc'] for r in summary_rows])

    # Compare against the previously recorded best (if any) and bail out early
    # when the current run does not improve on it — keep the best, not the last.
    existing_text = md_path.read_text(encoding="utf-8") if md_path.exists() else None
    if existing_text and START in existing_text and END in existing_text:
        block = existing_text[existing_text.index(START):existing_text.index(END)]
        m = re.search(re.escape(SCORE_TAG) + r"([0-9.]+)", block)
        prev_score = float(m.group(1)) if m else None
        if prev_score is not None and (math.isnan(cur_score) or cur_score <= prev_score):
            print(f"{md_path}: kept existing best run "
                  f"(best windowed {_pct(prev_score)} >= this run {_pct(cur_score)}); "
                  "not overwriting.")
            return False

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    L: list[str] = [
        START,
        f"<!-- {SCORE_TAG}{cur_score:.6f} -->",
        "## Best training run so far (auto-generated)",
        "",
        f"_Generated {ts} by `train_hand_classifier.py` "
        f"(mode={mode}, epochs={epochs}, imu={'on' if imu_fusion else 'off'}). "
        f"This section keeps the BEST run "
        f"(highest mean held-out windowed accuracy); it is overwritten only "
        f"when a later run beats it._",
        "",
        "| Participant | n_train | n_eval | Train acc | Test frame acc "
        "| Test windowed acc | Centroid |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in summary_rows:
        L.append(
            f"| {r['participant']} | {r['n_train']} | {r['n_eval']} | "
            f"{_fmt(r.get('handynet_train_acc', float('nan')))} | "
            f"{_fmt(r['handynet_frame_acc'])} | "
            f"{_fmt(r['handynet_windowed_acc'])} | "
            f"{_fmt(r['centroid_frame_acc'])} |"
        )
    L.append(
        f"| **MEAN** | {sum(r['n_train'] for r in summary_rows)} | "
        f"{sum(r['n_eval'] for r in summary_rows)} | "
        f"{_fmt(nanmean([r.get('handynet_train_acc', float('nan')) for r in summary_rows]))} | "
        f"{_fmt(nanmean([r['handynet_frame_acc'] for r in summary_rows]))} | "
        f"{_fmt(nanmean([r['handynet_windowed_acc'] for r in summary_rows]))} | "
        f"{_fmt(nanmean([r['centroid_frame_acc'] for r in summary_rows]))} |"
    )
    L += [
        "",
        f"**Headline — held-out windowed test accuracy: "
        f"{_pct(nanmean([r['handynet_windowed_acc'] for r in summary_rows]))}**"
        f"  ·  test frame acc "
        f"{_pct(nanmean([r['handynet_frame_acc'] for r in summary_rows]))}"
        f"  ·  centroid baseline "
        f"{_pct(nanmean([r['centroid_frame_acc'] for r in summary_rows]))}",
        "",
    ]
    for r in summary_rows:
        pc = r.get("handynet_per_class_acc")
        cf = r.get("handynet_confusion")
        if pc:
            L.append(f"**{r['participant']} — per-class test accuracy:** "
                     + ", ".join(f"{k}={_fmt(v)}" for k, v in pc.items()))
        if cf:
            L.append(f"**{r['participant']} — confusion (true→pred):** "
                     + ", ".join(f"{k}:{v}" for k, v in sorted(cf.items())))
        if pc or cf:
            L.append("")
    L += [
        "_Train acc = in-sample; Test = held-out 20% (time-ordered split); "
        "windowed = sliding-window-30 majority vote (HandyTrak metric); "
        "Centroid = zero-training baseline._",
        END,
    ]
    section = "\n".join(L)

    if existing_text is not None:
        text = existing_text
        if START in text and END in text:
            new_text = (text[: text.index(START)]
                        + section
                        + text[text.index(END) + len(END):])
        else:
            sep = "" if text.endswith("\n") else "\n"
            new_text = f"{text}{sep}\n{section}\n"
    else:
        new_text = section + "\n"

    md_path.write_text(new_text, encoding="utf-8")
    return True


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest",
        nargs="?",
        help="Path to the hand manifest CSV. Omit with --demo.",
    )
    parser.add_argument(
        "--images-root",
        default=".",
        help="Directory that image_relative_path values are resolved against.",
    )
    parser.add_argument(
        "--out",
        default="hand_model_out",
        help="Output directory for the model and labels.json.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Run end-to-end on synthetic data (no real data needed).",
    )
    parser.add_argument(
        "--mode",
        choices=["handynet", "centroid", "both"],
        default="both",
        help="Training mode: handynet (Option B), centroid (Option C), or both. "
             "Default: both.",
    )
    parser.add_argument(
        "--train-frac",
        type=float,
        default=0.8,
        help="Fraction of each condition's frames used for training (default 0.8).",
    )
    parser.add_argument(
        "--window-size",
        type=int,
        default=30,
        help="Sliding-window size for majority-vote evaluation (default 30).",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=_DEFAULT_EPOCHS,
        help=f"Number of HandyNet training epochs (default {_DEFAULT_EPOCHS}, "
             "paper-faithful).",
    )
    parser.add_argument(
        "--md-out",
        default=None,
        help="Optional path to a markdown file (e.g. Model-Training-Test/model.md). "
             "The final results chart is written into a delimited, auto-updated "
             "section of that file (replaced on each run; the rest of the file is "
             "preserved).",
    )
    parser.add_argument(
        "--use-imu",
        action="store_true",
        help="Concatenate a 48-d IMU summary vector onto the image features "
             "before the softmax head (feature-level fusion). Requires "
             "imu_relative_path in the manifest.",
    )
    parser.add_argument(
        "--imu-seq",
        action="store_true",
        help="Use the windowed IMU SEQUENCE model (scripts/imu_sequence.py) "
             "instead of image features entirely — skips preprocess/segment/"
             "VGG (the slow stages). Mutually informative with --use-imu: if "
             "both are passed, --imu-seq wins and a warning is printed.",
    )
    parser.add_argument(
        "--imu-window",
        type=int,
        default=50,
        help="IMU sequence window size in samples (default 50, ~1.0s at "
             "50 Hz). Only used with --imu-seq. NOTE: distinct from "
             "--window-size, which is the sliding-window MAJORITY-VOTE "
             "evaluation window (2 Hz frame stream, default 30) — the two "
             "windows measure different things and are not interchangeable.",
    )
    parser.add_argument(
        "--imu-causal",
        action="store_true",
        help="Use a causal TRAILING IMU window (prev+curr only) instead of "
             "the default centered window (prev+curr+future). Only used with "
             "--imu-seq. Trailing windows match what the on-device live "
             "model can compute (no future samples available at inference "
             "time); centered windows are for offline training/eval only.",
    )
    parser.add_argument(
        "--pooled",
        action="store_true",
        help="Also train one IMU-sequence model on ALL participants' pooled "
             "train-splits (saved to <out>/pooled_/). Requires --imu-seq.",
    )
    parser.add_argument(
        "--pooled-louo",
        action="store_true",
        help="Also run leave-one-user-out (LOUO): for each participant, train "
             "an IMU-sequence model on every OTHER participant's train-split "
             "and evaluate on that participant's FULL data (100%% unseen), "
             "saved to <out>/louo_<participant>/. Requires --imu-seq.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    main()
