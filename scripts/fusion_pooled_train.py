#!/usr/bin/env python3
"""
fusion_pooled_train.py
-----------------------
IMU + front-camera-silhouette FUSION model for holding-hand classification,
with pooled and leave-one-user-out (LOUO) training as its only modes (D1
design, docs/superpowers/specs/2026-07-20-pooled-fusion-training-design.md).

No per-participant mode -- fusion is introduced fresh alongside pooling, so
there is no legacy per-participant fusion model to preserve (unlike
train_hand_classifier.py's --pooled/--pooled-louo, which is additive next to
its existing per-participant IMU-only training).

Feature-level fusion: a frozen VGG16 silhouette feature vector (via
train_hand_classifier.preprocess/segment/extract_features, CACHED per image
since segmentation+VGG16 is the only slow stage) projected to 128-d,
concatenated with a trainable Conv1D IMU-window embedding, through a small
fusion head. See build_fusion_model() below.

Row eligibility: unlike train_hand_classifier.py's --use-imu fusion (which
zero-fills a missing IMU series), this script DROPS any row without a real,
readable IMU series for its session -- zero-filling either modality would
teach the fusion head to partially ignore it, corrupting the fusion-vs-
IMU-only comparison this script exists to make. Every eval in this script
(fusion AND its IMU-only comparison model) runs on the IDENTICAL filtered
row set.

Usage:
    .venv-ml/bin/python scripts/fusion_pooled_train.py \\
        Model-Training-Test/hand_manifest_combined.csv \\
        --images-root Model-Training-Test/ --out Model-Training-Test/models/ \\
        --pooled --pooled-louo --epochs 30
    .venv-ml/bin/python scripts/fusion_pooled_train.py --demo --pooled --epochs 1
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

import numpy as np

_SCRIPTS_DIR = Path(__file__).parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

REPO = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO / "Model-Training-Test" / "cache" / "img_features"

IMU_WINDOW = 50   # samples, ~1.0s at 50Hz -- matches the shipped model
IMU_CAUSAL = True  # trailing window -- matches what the live model can compute


# ---------------------------------------------------------------------------
# Feature cache
# ---------------------------------------------------------------------------

def image_feature_cache_path(image_path: str) -> Path:
    """Deterministic cache path for one image's VGG16 feature vector, keyed
    by the image's own filename stem -- stable across which participant or
    training mode is running, and across re-merges of the same export.
    """
    stem = Path(image_path).stem
    return CACHE_DIR / f"{stem}.npy"


def cached_image_feature(image_path: str, refresh: bool = False) -> "np.ndarray":
    """VGG16 silhouette feature vector for `image_path` (via
    train_hand_classifier.preprocess/segment/extract_features), computed
    once and cached to disk. A cache hit skips torch and keras entirely.
    Raises whatever preprocess()/segment()/extract_features() would raise on
    a genuinely unreadable image -- callers (eligible_records()) catch that
    and drop the row rather than silently zero-filling it.
    """
    path = image_feature_cache_path(image_path)
    if not refresh and path.exists():
        return np.load(path)

    from train_hand_classifier import preprocess, segment, extract_features
    img = preprocess(image_path)
    sil = segment(img)
    feat = extract_features(sil)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    np.save(path, feat)
    return feat


# ---------------------------------------------------------------------------
# Row eligibility
# ---------------------------------------------------------------------------

def eligible_records(
    records: "list[dict]", refresh_cache: bool = False
) -> "tuple[list[dict], dict[str, int]]":
    """Filter `records` (from hand_dataset.load_dataset_records) down to rows
    with BOTH a readable image and a readable IMU series -- fusion training
    drops incomplete rows rather than zero-filling either branch (see module
    docstring). Also excludes 'unknown'-label rows (never usable for
    training, not counted as "dropped" -- that count is reserved for rows
    that WOULD have been usable but for a missing modality).

    Returns (kept_records, dropped_counts) where dropped_counts is
    {participant_key: n_dropped}, printed by main() so a bad merge (e.g. a
    session recorded without IMU) is visible per participant, not silent.
    """
    import imu_sequence

    imu_ok_cache: "dict[str | None, bool]" = {}
    kept: "list[dict]" = []
    dropped: "dict[str, int]" = {}

    for rec in records:
        if rec["label"] == "unknown":
            continue
        imu_path = rec.get("imu_path")
        if imu_path not in imu_ok_cache:
            imu_ok_cache[imu_path] = (
                imu_path is not None and imu_sequence.load_imu_series(imu_path) is not None
            )
        if not imu_ok_cache[imu_path]:
            dropped[rec["participant_key"]] = dropped.get(rec["participant_key"], 0) + 1
            continue
        try:
            cached_image_feature(rec["image_path"], refresh=refresh_cache)
        except Exception:
            dropped[rec["participant_key"]] = dropped.get(rec["participant_key"], 0) + 1
            continue
        kept.append(rec)

    return kept, dropped


# ---------------------------------------------------------------------------
# Fusion model architecture
# ---------------------------------------------------------------------------

def build_fusion_model(
    image_feature_dim: int, imu_window: int, imu_channels: int, n_classes: int
):
    """Two-branch feature-level fusion:
      image_features (image_feature_dim,) --Dense(128)--> image_128
      imu_window (imu_window, imu_channels)
        --Conv1D(32,5)->BN->ReLU->Conv1D(64,5)->GlobalAvgPool->Dropout(0.5)--> imu_64
      concat(image_128, imu_64) --Dense(128, relu)--> Dense(n_classes, softmax)

    image_feature_dim is read from the actual cached feature vectors at call
    time (25088-d paper-faithful VGG16-conv-flatten, or 1024-d in the no-
    keras 32x32-flatten fallback -- see train_hand_classifier.extract_
    features) rather than assumed, since it depends on which optional deps
    are installed. The IMU branch mirrors imu_sequence._train_conv1d's
    architecture up to (not including) its softmax head, so it starts from
    the same proven shape as the shipped IMU-only model.

    Compiled with Adam / sparse_categorical_crossentropy, ready for .fit().
    """
    try:
        from tensorflow import keras as tfkeras
        Input, layers, Model = tfkeras.Input, tfkeras.layers, tfkeras.Model
    except Exception:
        import keras as k
        Input, layers, Model = k.Input, k.layers, k.Model

    img_in = Input(shape=(image_feature_dim,), name="image_features")
    img_x = layers.Dense(128, activation="relu", name="image_projection")(img_in)

    imu_in = Input(shape=(imu_window, imu_channels), name="imu_window")
    imu_x = layers.Conv1D(32, 5, padding="same")(imu_in)
    imu_x = layers.BatchNormalization()(imu_x)
    imu_x = layers.ReLU()(imu_x)
    imu_x = layers.Conv1D(64, 5, padding="same")(imu_x)
    imu_x = layers.GlobalAveragePooling1D(name="imu_embedding")(imu_x)
    imu_x = layers.Dropout(0.5)(imu_x)

    fused = layers.Concatenate()([img_x, imu_x])
    fused = layers.Dense(128, activation="relu")(fused)
    out = layers.Dense(n_classes, activation="softmax")(fused)

    model = Model(inputs=[img_in, imu_in], outputs=out)
    model.compile(optimizer="adam", loss="sparse_categorical_crossentropy",
                  metrics=["accuracy"])
    return model


def train_fusion_model(
    img_feats: "np.ndarray", imu_windows: "np.ndarray", labels: "list[str]",
    epochs: int = 10,
):
    """Trains build_fusion_model() end-to-end (image projection + IMU encoder
    + fusion head all update; only the frozen VGG16 backbone that produced
    img_feats does not). Attaches ._hand_classes = sorted(unique labels),
    same convention as train()/train_imu_sequence_model(), so the model is
    savable via train_hand_classifier._save_model unchanged.
    """
    unique_labels = sorted(set(labels))
    label_to_idx = {l: i for i, l in enumerate(unique_labels)}
    y = np.array([label_to_idx[l] for l in labels])

    model = build_fusion_model(
        image_feature_dim=img_feats.shape[1],
        imu_window=imu_windows.shape[1],
        imu_channels=imu_windows.shape[2],
        n_classes=len(unique_labels),
    )
    model.fit([img_feats, imu_windows], y, epochs=epochs, batch_size=32, verbose=0)
    model._hand_classes = unique_labels
    print(f"Trained fusion model  (n={len(labels)}, classes={unique_labels}, "
          f"epochs={epochs})")
    return model


def predict_labels_fusion(
    model, img_feats: "np.ndarray", imu_windows: "np.ndarray", classes: "list[str]"
) -> "list[str]":
    """Decode the fusion model's two-input softmax output to string labels.
    Separate from train_hand_classifier._predict_labels because that
    function's contract is single-input (features: np.ndarray); the fusion
    model takes a [image_features, imu_window] list.
    """
    probs = model.predict([img_feats, imu_windows], verbose=0)
    idx = np.asarray(probs).argmax(axis=1)
    return [classes[i] for i in idx]


if __name__ == "__main__":
    print("fusion_pooled_train.py: CLI not yet implemented (Task 6)", file=sys.stderr)
    sys.exit(1)
