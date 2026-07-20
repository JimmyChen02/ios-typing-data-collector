"""Cross-user ("mock user") evaluation of the committed holding-hand models.

Loads each trained model from Model-Training-Test/models/<slug>/ and
evaluates it on every participant's data:

  - on the OTHER participant(s): 100% unseen — simulates a brand-new user
    (the models are trained strictly per participant; see the per-participant
    loop in train_hand_classifier.py, so cross-user data is never trained on);
  - on its OWN participant: only the held-out 20% (same time-ordered
    per-condition split as training), as a within-user reference.

No training happens here and nothing is written — read-only evaluation.
Reuses the training code's own window builder (imu_sequence, window=50
causal — matches the shipped model) and metric helpers, so the numbers are
directly comparable to model.md / models/summary.json.

Run from the repo root:
    .venv-ml/bin/python scripts/cross_user_eval.py

First run/result: 2026-07-15 — see the results log in
Model-Training-Test/model.md (frame ~0.95-0.97, windowed ~0.90-0.91 on a
fully unseen person; `right` is the weakest class cross-user).
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
    _per_class_and_confusion,
    split_train_eval_indices,
    windowed_accuracy,
)

import window_grid  # noqa: E402
import keras  # noqa: E402

MODELS_DIR = REPO / "Model-Training-Test" / "models"
MANIFEST = REPO / "Model-Training-Test" / "hand_manifest_combined.csv"
IMAGES_ROOT = REPO / "Model-Training-Test"
WINDOW = 50          # IMU window (samples) — matches the shipped model


def slug(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", key)


def evaluate(records, indices, model, classes, feats, true_labels):
    probs = model.predict(feats, verbose=0)
    pred = [classes[j] for j in np.asarray(probs).argmax(axis=1)]
    frame_acc = float(np.mean(np.array(pred) == np.array(true_labels)))
    per_class, conf = _per_class_and_confusion(true_labels, pred, classes)
    grid = window_grid.sweep_window_sizes(records, indices, pred, true_labels)
    selected = window_grid.select_window(grid)
    win_acc = grid[selected] if selected is not None else float("nan")
    return frame_acc, win_acc, selected, grid, per_class, conf


def main() -> None:
    records = load_dataset_records(str(MANIFEST), str(IMAGES_ROOT))
    X, _, _ = imu_sequence.build_sequence_dataset(records, window=WINDOW, causal=True)
    print(f"Loaded {len(records)} records; windows shape {X.shape}\n")

    groups: "dict[str, list[int]]" = defaultdict(list)
    for i, rec in enumerate(records):
        if rec["label"] != "unknown":
            groups[rec["participant_key"]].append(i)
    for key in groups:  # capture/time order within each participant
        groups[key].sort(key=lambda i: records[i]["sort_key"])

    loaded = {}
    for key in groups:
        mdir = MODELS_DIR / slug(key)
        model_path = mdir / "hand_model.keras"
        if not model_path.exists():
            print(f"NOTE: no committed model for participant {key!r} "
                  f"({model_path} missing) — skipping as a model, still "
                  "used as eval data.")
            continue
        model = keras.models.load_model(model_path)
        with (mdir / "labels.json").open() as fh:
            classes = json.load(fh)
        loaded[key] = (model, classes)
        print(f"Loaded model {mdir.name}: classes={classes}")

    rows = []
    for model_key in sorted(loaded):
        model, classes = loaded[model_key]
        for target_key in sorted(groups):
            idxs = groups[target_key]
            if target_key == model_key:
                # Fair self-reference: only the held-out 20% (same split as training).
                labels_ = [records[i]["label"] for i in idxs]
                keys_ = [records[i]["sort_key"] for i in idxs]
                _, local_eval = split_train_eval_indices(keys_, labels_, train_frac=0.8)
                idxs = [idxs[li] for li in local_eval]
                tag = "SELF held-out 20%"
            else:
                tag = "MOCK USER (100% unseen)"
            true = [records[i]["label"] for i in idxs]
            fa, wa, sel, grid, pc, conf = evaluate(records, idxs, model, classes, X[idxs], true)
            rows.append((model_key, target_key, tag, len(idxs), fa, wa, sel))
            print(f"\n=== model[{slug(model_key)}] -> data[{slug(target_key)}]"
                  f"  ({tag}, n={len(idxs)}) ===")
            print(f"  frame-acc={fa:.3f}   windowed-acc={wa:.3f}"
                  f"  (selected window={sel}s)")
            print("  window grid: " + ", ".join(
                f"{s}s={a:.3f}" if a == a else f"{s}s=nan"
                for s, a in sorted(grid.items())))
            print("  per-class: " + ", ".join(f"{c}={v:.3f}" for c, v in pc.items()))
            conf_str = ", ".join(f"{t}->{p}:{n}" for (t, p), n in sorted(conf.items()))
            print(f"  confusion (true->pred): {conf_str}")

    print("\n" + "=" * 88)
    print(f"{'model':<14}{'evaluated on':<14}{'condition':<26}{'n':>6}"
          f"{'frame':>9}{'windowed':>10}{'sel(s)':>8}")
    print("-" * 88)
    for mk, tk, tag, n, fa, wa, sel in rows:
        print(f"{slug(mk):<14}{slug(tk):<14}{tag:<26}{n:>6}{fa:>9.3f}"
              f"{wa:>10.3f}{sel!s:>8}")
    print("=" * 88)


if __name__ == "__main__":
    main()
