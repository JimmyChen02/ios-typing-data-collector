#!/usr/bin/env python3
"""Retrain posture models on frame-skipped versions of the same image sessions.

The experiment answers a training-data question, not an inference-cadence
question. Dense (~30 fps) Jimmy sessions are the fixed source training pool.
For each requested target rate, the script keeps regularly spaced images from
those same sessions, trains fresh camera+IMU fusion and IMU-only models, and
evaluates both on the same untouched Anonymous participant frames.

Outputs are written incrementally so completed rates survive an interrupted run:

  results/posture_efficiency/training_frame_rate_results.csv
  results/posture_efficiency/training_frame_rate_summary.json

Example:
  .venv-ml/bin/python scripts/training_frame_rate_experiment.py --epochs 30
"""

from __future__ import annotations

import argparse
import csv
import gc
import json
import math
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from hand_dataset import load_dataset_records  # noqa: E402
import fusion_pooled_train as fusion  # noqa: E402
import imu_sequence  # noqa: E402


MANIFEST = REPO / "Model-Training-Test" / "hand_manifest_combined.csv"
DATA_ROOT = REPO / "Model-Training-Test"
OUTPUT_DIR = REPO / "results" / "posture_efficiency"
RESULTS_CSV = OUTPUT_DIR / "training_frame_rate_results.csv"
SUMMARY_JSON = OUTPUT_DIR / "training_frame_rate_summary.json"

TRAIN_PARTICIPANT = "jimmy|"
TEST_PARTICIPANT = "anonymous|"
MIN_DENSE_FPS = 20.0
DEFAULT_RATES = [30.0, 15.0, 10.0, 7.5, 6.0, 5.0, 3.0, 2.0, 1.0]
DEFAULT_SEEDS = [20260729, 20260730, 20260731]
IMU_WINDOW = 50


def parse_iso(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def session_fps(records: list[dict]) -> float | None:
    times = sorted(
        t for record in records
        if (t := parse_iso(record.get("captured_at_iso", ""))) is not None
    )
    if len(times) < 2:
        return None
    span = (times[-1] - times[0]).total_seconds()
    return (len(times) - 1) / span if span > 0 else None


def sampled_positions(length: int, source_fps: float, target_fps: float) -> list[int]:
    """Nearest source-frame positions for a regular target-fps schedule."""
    if length <= 1 or target_fps >= source_fps:
        return list(range(length))
    step = source_fps / target_fps
    positions = np.unique(np.rint(np.arange(0, length, step)).astype(int))
    return [int(i) for i in positions if i < length]


def downsample_sessions(
    sessions: list[tuple[list[dict], float]], target_fps: float
) -> list[dict]:
    selected: list[dict] = []
    for records, source_fps in sessions:
        positions = sampled_positions(len(records), source_fps, target_fps)
        selected.extend(records[i] for i in positions)
    return selected


def load_features(records: list[dict]) -> np.ndarray:
    return np.stack(
        [fusion.cached_image_feature(record["image_path"]) for record in records],
        axis=0,
    ).astype(np.float32, copy=False)


def accuracy(predictions: list[str], labels: list[str]) -> float:
    return float(np.mean(np.asarray(predictions) == np.asarray(labels)))


def set_seed(seed: int) -> None:
    import keras

    keras.utils.set_random_seed(seed)


def clear_backend() -> None:
    try:
        import keras

        keras.backend.clear_session()
    finally:
        gc.collect()


def existing_rows() -> list[dict[str, str]]:
    if not RESULTS_CSV.exists():
        return []
    with RESULTS_CSV.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_rows(rows: list[dict]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "training_fps",
        "training_images",
        "source_training_images",
        "training_fraction",
        "fusion_accuracy",
        "imu_only_accuracy",
        "fusion_train_seconds",
        "imu_train_seconds",
        "test_images",
        "seed",
        "epochs",
    ]
    with RESULTS_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def plot_frame_rate(rows: list[dict], path: Path) -> None:
    """Training-fps vs cross-user accuracy; fusion and IMU-only, y-axis 0-100%.

    `rows` may hold either freshly computed float values or strings read back
    from the CSV; both are coerced with float().
    """
    import matplotlib.pyplot as plt

    by_fps: dict[float, dict[str, list[float]]] = defaultdict(
        lambda: {"fusion": [], "imu": []}
    )
    for row in rows:
        fps = float(row["training_fps"])
        by_fps[fps]["fusion"].append(float(row["fusion_accuracy"]))
        by_fps[fps]["imu"].append(float(row["imu_only_accuracy"]))

    fps_values = sorted(by_fps)
    fusion_mean = [100 * np.mean(by_fps[f]["fusion"]) for f in fps_values]
    imu_mean = [100 * np.mean(by_fps[f]["imu"]) for f in fps_values]

    plt.style.use("seaborn-v0_8-whitegrid")
    fig, ax = plt.subplots(figsize=(7, 4.8), constrained_layout=True)
    ax.plot(fps_values, fusion_mean, marker="o", color="#2F6BFF",
            label="Camera + IMU fusion")
    ax.plot(fps_values, imu_mean, marker="s", color="#E4572E",
            label="IMU only")
    ax.set(
        xlabel="Training-image sampling rate (fps)",
        ylabel="Cross-user accuracy (%)",
        title="Training frame rate vs performance",
        ylim=(0, 100),
    )
    ax.legend(frameon=False)
    ax.grid(alpha=0.25)
    fig.savefig(path, dpi=180)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--rates", type=float, nargs="+", default=DEFAULT_RATES)
    parser.add_argument("--seeds", type=int, nargs="+", default=DEFAULT_SEEDS)
    parser.add_argument(
        "--restart",
        action="store_true",
        help="Discard completed-rate rows instead of resuming them.",
    )
    parser.add_argument(
        "--replot",
        action="store_true",
        help="Only redraw the plot from the existing results CSV; no training.",
    )
    args = parser.parse_args()

    if args.replot:
        rows = existing_rows()
        if not rows:
            raise SystemExit("No results CSV to plot yet.")
        plot_frame_rate(rows, OUTPUT_DIR / "training_frame_rate_performance.png")
        print(f"Wrote {OUTPUT_DIR / 'training_frame_rate_performance.png'}")
        return

    all_records = load_dataset_records(str(MANIFEST), str(DATA_ROOT))
    relevant = [
        record for record in all_records
        if record["participant_key"] in {TRAIN_PARTICIPANT, TEST_PARTICIPANT}
        and record["label"] != "unknown"
    ]
    kept, dropped = fusion.eligible_records(relevant, show_progress=False)
    if dropped:
        print(f"Dropped incomplete records: {dropped}")

    by_session: dict[str, list[dict]] = defaultdict(list)
    for record in kept:
        if record["participant_key"] == TRAIN_PARTICIPANT:
            by_session[record["imu_path"]].append(record)

    dense_sessions: list[tuple[list[dict], float]] = []
    for records in by_session.values():
        records.sort(key=lambda record: record["sort_key"])
        fps = session_fps(records)
        if fps is not None and fps >= MIN_DENSE_FPS:
            dense_sessions.append((records, fps))
    dense_sessions.sort(key=lambda item: item[0][0]["sort_key"])
    if not dense_sessions:
        raise RuntimeError("No dense Jimmy training sessions were found")

    source_train_records = [
        record for records, _fps in dense_sessions for record in records
    ]
    test_records = [
        record for record in kept if record["participant_key"] == TEST_PARTICIPANT
    ]
    test_records.sort(key=lambda record: record["sort_key"])
    if not test_records:
        raise RuntimeError("No Anonymous test records were found")

    test_labels = [record["label"] for record in test_records]
    test_imu, _, _ = imu_sequence.build_sequence_dataset(
        test_records, window=IMU_WINDOW, causal=True
    )
    print(f"Loading fixed test image features (n={len(test_records)}) ...")
    test_images = load_features(test_records)

    rows: list[dict] = [] if args.restart else existing_rows()
    completed = {
        (float(row["training_fps"]), int(row["epochs"]), int(row["seed"]))
        for row in rows
    }

    for target_fps in args.rates:
        pending_seeds = [
            seed for seed in args.seeds
            if (float(target_fps), args.epochs, seed) not in completed
        ]
        if not pending_seeds:
            print(f"Skipping completed rate {target_fps:g} fps for all seeds")
            continue

        train_records = downsample_sessions(dense_sessions, target_fps)
        train_labels = [record["label"] for record in train_records]
        counts = Counter(train_labels)
        if len(counts) < 2:
            raise RuntimeError(
                f"{target_fps:g} fps produced fewer than two training classes: {counts}"
            )
        print(
            f"\n=== Training rate {target_fps:g} fps ===\n"
            f"n_train={len(train_records)} of {len(source_train_records)} "
            f"({len(train_records) / len(source_train_records):.1%}); "
            f"classes={dict(sorted(counts.items()))}"
        )

        train_imu, _, _ = imu_sequence.build_sequence_dataset(
            train_records, window=IMU_WINDOW, causal=True
        )
        print("Loading selected training image features ...")
        train_images = load_features(train_records)

        classes = sorted(set(train_labels))
        for seed in pending_seeds:
            print(f"\nSeed {seed}")
            set_seed(seed)
            started = time.perf_counter()
            fusion_model = fusion.train_fusion_model(
                train_images, train_imu, train_labels, epochs=args.epochs
            )
            fusion_seconds = time.perf_counter() - started
            fusion_predictions = fusion.predict_labels_fusion(
                fusion_model, test_images, test_imu, classes
            )
            fusion_acc = accuracy(fusion_predictions, test_labels)
            print(
                f"Fusion: accuracy={fusion_acc:.4f}, "
                f"train_time={fusion_seconds:.1f}s"
            )
            del fusion_model
            clear_backend()

            set_seed(seed)
            started = time.perf_counter()
            imu_model = imu_sequence.train_imu_sequence_model(
                train_imu, train_labels, epochs=args.epochs
            )
            imu_seconds = time.perf_counter() - started
            imu_probs = imu_model.predict(test_imu, verbose=0, batch_size=512)
            imu_predictions = [
                classes[i] for i in np.asarray(imu_probs).argmax(axis=1)
            ]
            imu_acc = accuracy(imu_predictions, test_labels)
            print(
                f"IMU only: accuracy={imu_acc:.4f}, "
                f"train_time={imu_seconds:.1f}s"
            )
            del imu_model
            clear_backend()

            rows.append(
                {
                    "training_fps": target_fps,
                    "training_images": len(train_records),
                    "source_training_images": len(source_train_records),
                    "training_fraction": len(train_records) / len(source_train_records),
                    "fusion_accuracy": fusion_acc,
                    "imu_only_accuracy": imu_acc,
                    "fusion_train_seconds": fusion_seconds,
                    "imu_train_seconds": imu_seconds,
                    "test_images": len(test_records),
                    "seed": seed,
                    "epochs": args.epochs,
                }
            )
            rows.sort(
                key=lambda row: (
                    -float(row["training_fps"]),
                    int(row["seed"]),
                )
            )
            write_rows(rows)
        del train_images, train_imu
        clear_backend()

    final_rows = [
        row for row in rows
        if int(row["epochs"]) == args.epochs
        and float(row["training_fps"]) in set(args.rates)
        and int(row["seed"]) in set(args.seeds)
    ]
    aggregated = []
    for rate in args.rates:
        rate_rows = [
            row for row in final_rows
            if math.isclose(float(row["training_fps"]), rate)
        ]
        if not rate_rows:
            continue
        fusion_values = np.array(
            [float(row["fusion_accuracy"]) for row in rate_rows]
        )
        imu_values = np.array(
            [float(row["imu_only_accuracy"]) for row in rate_rows]
        )
        aggregated.append(
            {
                "training_fps": rate,
                "training_images": int(rate_rows[0]["training_images"]),
                "runs": len(rate_rows),
                "fusion_accuracy_mean": float(fusion_values.mean()),
                "fusion_accuracy_std": float(
                    fusion_values.std(ddof=1) if len(fusion_values) > 1 else 0.0
                ),
                "imu_only_accuracy_mean": float(imu_values.mean()),
                "imu_only_accuracy_std": float(
                    imu_values.std(ddof=1) if len(imu_values) > 1 else 0.0
                ),
            }
        )
    summary = {
        "question": "Effect of training-image sampling rate on cross-user accuracy",
        "training_participant": TRAIN_PARTICIPANT,
        "test_participant": TEST_PARTICIPANT,
        "dense_training_sessions": len(dense_sessions),
        "mean_source_training_fps": float(
            np.mean([fps for _records, fps in dense_sessions])
        ),
        "source_training_images": len(source_train_records),
        "fixed_test_images": len(test_records),
        "rates_fps": args.rates,
        "epochs": args.epochs,
        "seeds": args.seeds,
        "same_source_sessions_at_every_rate": True,
        "test_set_unchanged_at_every_rate": True,
        "results": final_rows,
        "aggregated_results": aggregated,
    }
    SUMMARY_JSON.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nWrote {RESULTS_CSV}")
    print(f"Wrote {SUMMARY_JSON}")

    plot_frame_rate(final_rows, OUTPUT_DIR / "training_frame_rate_performance.png")
    print(f"Wrote {OUTPUT_DIR / 'training_frame_rate_performance.png'}")


if __name__ == "__main__":
    main()
