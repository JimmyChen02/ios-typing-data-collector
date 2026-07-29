"""Sweep the majority-vote window size for the committed hand models.

Same data/model/metric machinery as scripts/cross_user_eval.py, but instead
of the fixed 30-frame vote window, evaluates windowed accuracy at a range of
window sizes for all four (model, eval-set) combinations. Per-frame accuracy
is the window-size-1 row by construction.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from hand_dataset import load_dataset_records  # noqa: E402
import imu_sequence  # noqa: E402
from train_hand_classifier import (  # noqa: E402
    split_train_eval_indices,
    windowed_accuracy,
)

import keras  # noqa: E402

WINDOW_SIZES = [1, 3, 5, 10, 15, 20, 30, 45, 60]


def slug(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", key)


def main() -> None:
    records = load_dataset_records(
        str(REPO / "Model-Training-Test/hand_manifest_combined.csv"),
        str(REPO / "Model-Training-Test"),
    )
    X, _, _ = imu_sequence.build_sequence_dataset(records, window=50, causal=True)

    groups: dict[str, list[int]] = defaultdict(list)
    for i, rec in enumerate(records):
        if rec["label"] != "unknown":
            groups[rec["participant_key"]].append(i)
    for key in groups:
        groups[key].sort(key=lambda i: records[i]["sort_key"])

    loaded = {}
    for key in groups:
        mdir = REPO / "Model-Training-Test/models" / slug(key)
        model = keras.models.load_model(mdir / "hand_model.keras")
        with (mdir / "labels.json").open() as fh:
            classes = json.load(fh)
        loaded[key] = (model, classes)

    combos = []  # (name, pred_labels, true_labels)
    for model_key in sorted(loaded):
        model, classes = loaded[model_key]
        for target_key in sorted(groups):
            idxs = groups[target_key]
            if target_key == model_key:
                labels_ = [records[i]["label"] for i in idxs]
                keys_ = [records[i]["sort_key"] for i in idxs]
                _, local_eval = split_train_eval_indices(keys_, labels_, train_frac=0.8)
                idxs = [idxs[li] for li in local_eval]
                name = f"{slug(model_key)[:-1]}->self(20%)"
            else:
                name = f"{slug(model_key)[:-1]}->{slug(target_key)[:-1]}(cross)"
            true = [records[i]["label"] for i in idxs]
            probs = loaded[model_key][0].predict(X[idxs], verbose=0)
            pred = [classes[j] for j in np.asarray(probs).argmax(axis=1)]
            combos.append((name, pred, true))

    header = f"{'vote window':>12}{'latency@2Hz':>12}" + "".join(f"{n:>22}" for n, _, _ in combos)
    print(header)
    print("-" * len(header))
    for w in WINDOW_SIZES:
        cells = []
        for _, pred, true in combos:
            acc = windowed_accuracy(pred, true, window_size=w) if w > 1 else float(
                np.mean(np.array(pred) == np.array(true)))
            cells.append(f"{acc:>22.3f}")
        print(f"{w:>12}{w/2:>10.1f}s" + "".join(cells))


if __name__ == "__main__":
    main()
