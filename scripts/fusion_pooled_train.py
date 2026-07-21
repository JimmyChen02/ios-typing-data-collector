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


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def _fmt(v: float) -> str:
    import math
    return f"{v:.3f}" if not math.isnan(v) else "   nan"


def main() -> None:
    args = _parse_args()

    if not (args.pooled or args.pooled_louo):
        print("Error: pass --pooled and/or --pooled-louo (fusion has no "
              "per-participant mode — see the D1 design's Non-goals).")
        sys.exit(1)

    if args.demo:
        from hand_dataset import _make_demo_manifest_and_images
        tmp = Path(tempfile.mkdtemp(prefix="fusion_demo_"))
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

    from hand_dataset import load_dataset_records
    all_records = load_dataset_records(manifest_path, images_root)
    kept, dropped = eligible_records(all_records, refresh_cache=args.refresh_cache)
    print(f"Loaded {len(all_records)} records; {len(kept)} eligible "
          f"(both image and IMU readable), {sum(dropped.values())} dropped")
    for p_key, n in sorted(dropped.items()):
        print(f"  dropped {n} row(s) for participant {p_key!r}")

    if not kept:
        print("No eligible rows — nothing to train. Exiting.")
        return

    import imu_sequence
    imu_windows, _imu_labels, _imu_sort_keys = imu_sequence.build_sequence_dataset(
        kept, window=IMU_WINDOW, causal=IMU_CAUSAL
    )
    img_feats = np.stack(
        [cached_image_feature(r["image_path"]) for r in kept], axis=0
    )

    participant_to_indices: "dict[str, list[int]]" = {}
    for i, rec in enumerate(kept):
        participant_to_indices.setdefault(rec["participant_key"], []).append(i)

    from train_hand_classifier import split_train_eval_indices, _predict_labels, _save_model

    participant_splits: "dict[str, tuple[list[int], list[int], list[int]]]" = {}
    for p_key, p_indices in participant_to_indices.items():
        labels_ = [kept[i]["label"] for i in p_indices]
        keys_ = [kept[i]["sort_key"] for i in p_indices]
        local_train, local_eval = split_train_eval_indices(keys_, labels_, train_frac=0.8)
        train_labels_here = [labels_[li] for li in local_train]
        if len(set(train_labels_here)) < 2:
            print(f"  skipping participant {p_key!r} (< 2 distinct labels in train split)")
            continue
        abs_train = [p_indices[li] for li in local_train]
        abs_eval = [p_indices[li] for li in local_eval]
        # (train, local held-out 20%, full known data). Pooled evaluates on
        # the local eval slot (continuity number, not literally unseen — the
        # model saw other frames from the same participant); LOUO evaluates
        # on the full slot for the held-out participant (genuinely 100%
        # unseen — the decision-relevant number). Conflating these two was a
        # real data-leakage bug in an earlier draft: using the full set for
        # pooled eval let it include frames the model was directly trained
        # on, inflating pooled's reported accuracy. See
        # .superpowers/sdd/task-3-report.md's "Fix: pooled-eval data
        # leakage" section for the equivalent fix already applied to
        # train_hand_classifier.py's _run_pooled_and_louo.
        participant_splits[p_key] = (abs_train, abs_eval, p_indices)

    if len(participant_splits) < 2:
        print("Fewer than 2 usable participants after filtering — pooled/LOUO "
              "need at least 2. Nothing to do.")
        return

    import window_grid

    def _train_and_eval(train_idx: "list[int]", eval_idx: "list[int]", tag: str) -> None:
        train_labels = [kept[i]["label"] for i in train_idx]
        fusion_model = train_fusion_model(
            img_feats[train_idx], imu_windows[train_idx], train_labels, epochs=args.epochs
        )
        imu_only_model = imu_sequence.train_imu_sequence_model(
            imu_windows[train_idx], train_labels, epochs=args.epochs
        )
        unique_labels = sorted(set(train_labels))
        eval_labels = [kept[i]["label"] for i in eval_idx]

        fusion_preds = predict_labels_fusion(
            fusion_model, img_feats[eval_idx], imu_windows[eval_idx], unique_labels
        )
        imu_only_preds = _predict_labels(imu_only_model, imu_windows[eval_idx])

        models = {"fusion": fusion_model, "imu_only": imu_only_model}
        for name, preds in (("fusion", fusion_preds), ("imu_only", imu_only_preds)):
            frame_acc = float(np.mean(np.array(preds) == np.array(eval_labels)))
            grid = window_grid.sweep_window_sizes(kept, eval_idx, preds, eval_labels)
            selected = window_grid.select_window(grid)
            win_acc = grid[selected] if selected is not None else float("nan")
            print(f"  [{tag}] {name}: n_train={len(train_idx)} n_eval={len(eval_idx)} "
                  f"frame-acc={frame_acc:.3f} windowed-acc={_fmt(win_acc)} "
                  f"(selected window={selected}s)")
        return models, unique_labels

    def _save(prefix: str, model, unique_labels: "list[str]") -> None:
        p_out_dir = out_dir / prefix
        p_out_dir.mkdir(parents=True, exist_ok=True)
        with (p_out_dir / "labels.json").open("w", encoding="utf-8") as fh:
            json.dump(unique_labels, fh, indent=2)
        _save_model(model, p_out_dir)
        print(f"  saved: {p_out_dir}")

    if args.pooled:
        print("\n=== Pooled ===")
        pooled_train_idx = [i for (t, _e, _k) in participant_splits.values() for i in t]
        pooled_eval_idx = [i for (_t, e, _k) in participant_splits.values() for i in e]
        assert not (set(pooled_train_idx) & set(pooled_eval_idx)), \
            "pooled eval set must not overlap pooled train set"
        models, unique_labels = _train_and_eval(pooled_train_idx, pooled_eval_idx, "pooled")
        _save("fusion_pooled_", models["fusion"], unique_labels)
        _save("imu_only_pooled_", models["imu_only"], unique_labels)

    if args.pooled_louo:
        print("\n=== Leave-one-user-out ===")
        for held_out_key in sorted(participant_splits):
            train_idx = [
                i for p_key, (t, _e, _k) in participant_splits.items()
                if p_key != held_out_key for i in t
            ]
            eval_idx = participant_splits[held_out_key][2]  # FULL data, 100% unseen
            models, unique_labels = _train_and_eval(
                train_idx, eval_idx, f"LOUO held_out={held_out_key!r}"
            )
            safe_key = re.sub(r"[^a-z0-9]+", "_", held_out_key) or "participant"
            _save(f"fusion_louo_{safe_key}", models["fusion"], unique_labels)
            _save(f"imu_only_louo_{safe_key}", models["imu_only"], unique_labels)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest", nargs="?",
        help="Path to the hand manifest CSV. Omit with --demo.",
    )
    parser.add_argument(
        "--images-root", default=".",
        help="Directory that image_relative_path/imu_relative_path values are resolved against.",
    )
    parser.add_argument(
        "--out", default="fusion_model_out",
        help="Output directory for the trained models and labels.json files.",
    )
    parser.add_argument(
        "--demo", action="store_true",
        help="Run end-to-end on synthetic data (no real data needed).",
    )
    parser.add_argument(
        "--pooled", action="store_true",
        help="Train one fusion + one IMU-only model on ALL participants' "
             "pooled train-splits.",
    )
    parser.add_argument(
        "--pooled-louo", action="store_true",
        help="Leave-one-user-out: for each participant, train fusion + "
             "IMU-only models on every OTHER participant's train-split and "
             "evaluate on that participant's FULL data (100%% unseen).",
    )
    parser.add_argument(
        "--epochs", type=int, default=10,
        help="Training epochs for both the fusion and IMU-only models (default 10).",
    )
    parser.add_argument(
        "--refresh-cache", action="store_true",
        help="Recompute cached VGG16 image features instead of reusing "
             "Model-Training-Test/cache/img_features/*.npy.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    main()
