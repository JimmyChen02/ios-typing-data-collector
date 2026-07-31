#!/usr/bin/env python3
"""Plot deployment accuracy versus vote-window duration and inference cadence.

This is a read-only evaluation of the saved cross-user models.  It uses only
dense (>=20 fps) Jimmy sessions and the LOUO-Jimmy models, which were trained
on Anonymous, so every evaluated frame is from an unseen participant.

Two comparisons are made on exactly the same frames:
  * camera + IMU fusion
  * IMU only

The cadence experiment simulates running inference less often (30, 15, 10,
... 1 times/s). Between inference calls, the last published label is held and
accuracy is still scored on every original frame. The vote window is fixed in
SECONDS, not frames, so cadence is the only changed variable.

Outputs:
  results/posture_efficiency/window_vs_performance.csv
  results/posture_efficiency/cadence_vs_performance.csv
  results/posture_efficiency/window_and_cadence_performance.png
  results/posture_efficiency/summary.json

Usage:
  .venv-ml/bin/python scripts/cadence_window_experiment.py
"""

from __future__ import annotations

import csv
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from hand_dataset import load_dataset_records  # noqa: E402
import imu_sequence  # noqa: E402

import keras  # noqa: E402

MANIFEST = REPO / "Model-Training-Test" / "hand_manifest_combined.csv"
DATA_ROOT = REPO / "Model-Training-Test"
MODELS_DIR = DATA_ROOT / "models"
CACHE_DIR = DATA_ROOT / "cache" / "img_features"
OUTPUT_DIR = REPO / "results" / "posture_efficiency"

TARGET = "jimmy|"
MIN_DENSE_FPS = 20.0
IMU_WINDOW = 50
WINDOW_SECONDS = [
    0.0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 7.5, 10.0, 15.0
]
CADENCES_HZ = [30.0, 15.0, 10.0, 7.5, 6.0, 5.0, 3.0, 2.0, 1.0]
NEAR_BEST_TOL = 0.002  # 0.2 percentage point
MAX_DEPLOYMENT_WINDOW_SECONDS = 1.5  # existing live responsiveness budget


def parse_iso(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def session_fps(records: list[dict], indices: list[int]) -> float | None:
    times = sorted(
        t for i in indices if (t := parse_iso(records[i].get("captured_at_iso", "")))
        is not None
    )
    if len(times) < 2:
        return None
    span = (times[-1] - times[0]).total_seconds()
    return (len(times) - 1) / span if span > 0 else None


def load_model(name: str):
    model_dir = MODELS_DIR / name
    model = keras.models.load_model(model_dir / "hand_model.keras")
    classes = json.loads((model_dir / "labels.json").read_text())
    return model, classes


def fusion_predictions(
    model,
    classes: list[str],
    records: list[dict],
    imu_windows: np.ndarray,
    batch_size: int = 128,
) -> list[str]:
    """Predict in batches so 20k 25,088-d image vectors are never in RAM."""
    output: list[str] = []
    for start in range(0, len(records), batch_size):
        stop = min(start + batch_size, len(records))
        image_features = np.stack([
            np.load(CACHE_DIR / f"{Path(r['image_path']).stem}.npy")
            for r in records[start:stop]
        ]).astype(np.float32, copy=False)
        probs = model.predict(
            [image_features, imu_windows[start:stop]],
            verbose=0,
            batch_size=batch_size,
        )
        output.extend(classes[i] for i in np.asarray(probs).argmax(axis=1))
    return output


def imu_predictions(model, classes: list[str], windows: np.ndarray) -> list[str]:
    probs = model.predict(windows, verbose=0, batch_size=512)
    return [classes[i] for i in np.asarray(probs).argmax(axis=1)]


def vote_stream(predictions: list[str], window_size: int) -> list[str]:
    """Trailing vote matching the app: a tie keeps the published label."""
    window_size = max(1, window_size)
    recent: list[str] = []
    counts: Counter = Counter()
    published = "unknown"
    result: list[str] = []
    for prediction in predictions:
        recent.append(prediction)
        counts[prediction] += 1
        if len(recent) > window_size:
            old = recent.pop(0)
            counts[old] -= 1
            if counts[old] == 0:
                del counts[old]
        max_count = max(counts.values())
        winners = [label for label, count in counts.items() if count == max_count]
        if len(winners) == 1:
            published = winners[0]
        elif published not in winners:
            published = prediction
        result.append(published)
    return result


def sampled_positions(length: int, source_fps: float, target_hz: float) -> list[int]:
    """Nearest frame positions for a regular target-hz inference schedule."""
    if length <= 1 or target_hz >= source_fps:
        return list(range(length))
    step = source_fps / target_hz
    positions = np.unique(np.rint(np.arange(0, length, step)).astype(int))
    return [int(i) for i in positions if i < length]


def replay_at_cadence(
    raw_predictions: list[str],
    source_fps: float,
    target_hz: float,
    vote_seconds: float,
) -> tuple[list[str], int]:
    """Subsample inference, vote sampled predictions, then hold between calls."""
    positions = sampled_positions(len(raw_predictions), source_fps, target_hz)
    sampled = [raw_predictions[i] for i in positions]
    window_frames = max(1, round(vote_seconds * target_hz))
    voted = vote_stream(sampled, window_frames)
    full = [voted[0]] * len(raw_predictions)
    for j, start in enumerate(positions):
        stop = positions[j + 1] if j + 1 < len(positions) else len(full)
        full[start:stop] = [voted[j]] * (stop - start)
    return full, len(positions)


def score_sessions(
    truth: list[str],
    raw: list[str],
    sessions: list[tuple[int, int, float]],
    *,
    vote_seconds: float,
    cadence_hz: float | None = None,
) -> dict[str, float]:
    correct = switches = calls = total = 0
    duration_seconds = 0.0
    for start, stop, fps in sessions:
        pred = raw[start:stop]
        if cadence_hz is None:
            voted = vote_stream(pred, max(1, round(vote_seconds * fps)))
            n_calls = len(pred)
        else:
            voted, n_calls = replay_at_cadence(pred, fps, cadence_hz, vote_seconds)
        actual = truth[start:stop]
        correct += sum(p == t for p, t in zip(voted, actual))
        switches += sum(a != b for a, b in zip(voted, voted[1:]))
        calls += n_calls
        total += len(actual)
        duration_seconds += len(actual) / fps
    return {
        "accuracy": correct / total,
        "switches_per_min": switches / (duration_seconds / 60.0),
        "inference_calls": calls,
        "evaluated_frames": total,
    }


def select_smallest_near_best(rows: list[dict], x_key: str) -> dict:
    best = max(row["accuracy"] for row in rows)
    eligible = [row for row in rows if row["accuracy"] >= best - NEAR_BEST_TOL]
    return min(eligible, key=lambda row: row[x_key])


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def plot(window_rows: list[dict], cadence_rows: list[dict], path: Path) -> None:
    import matplotlib.pyplot as plt

    plt.style.use("seaborn-v0_8-whitegrid")
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), constrained_layout=True)
    styles = {
        "Camera + IMU fusion": ("o", "#2F6BFF"),
        "IMU only": ("s", "#E4572E"),
    }
    for modality, (marker, color) in styles.items():
        wr = [r for r in window_rows if r["modality"] == modality]
        cr = [r for r in cadence_rows if r["modality"] == modality]
        axes[0].plot(
            [r["window_seconds"] for r in wr],
            [100 * r["accuracy"] for r in wr],
            marker=marker, color=color, label=modality,
        )
        axes[1].plot(
            [r["cadence_hz"] for r in cr],
            [100 * r["accuracy"] for r in cr],
            marker=marker, color=color, label=modality,
        )

    axes[0].set(
        xlabel="Trailing majority-vote window (seconds)",
        ylabel="Cross-user accuracy (%)",
        title="Window duration vs performance",
        ylim=(0, 100),
    )
    axes[1].set(
        xlabel="Inference cadence (calls/second)",
        ylabel="Cross-user accuracy (%)",
        title="Cadence vs performance (window duration held fixed)",
        ylim=(0, 100),
    )
    axes[1].invert_xaxis()
    for axis in axes:
        axis.legend(frameon=False)
        axis.grid(alpha=0.25)
    fig.suptitle(
        "Unseen Jimmy, dense sessions only — every point scored on the same frames",
        fontsize=12,
    )
    fig.savefig(path, dpi=180)
    plt.close(fig)


def main() -> None:
    all_records = load_dataset_records(str(MANIFEST), str(DATA_ROOT))
    by_session: dict[str, list[int]] = defaultdict(list)
    for i, record in enumerate(all_records):
        if record["participant_key"] == TARGET and record["label"] != "unknown":
            by_session[record["imu_path"]].append(i)

    dense_absolute: list[list[int]] = []
    for indices in by_session.values():
        indices.sort(key=lambda i: all_records[i]["sort_key"])
        fps = session_fps(all_records, indices)
        if fps is not None and fps >= MIN_DENSE_FPS:
            dense_absolute.append(indices)
    dense_absolute.sort(key=lambda xs: all_records[xs[0]]["sort_key"])
    if not dense_absolute:
        raise RuntimeError("No dense target sessions found")

    eval_records: list[dict] = []
    sessions: list[tuple[int, int, float]] = []
    for indices in dense_absolute:
        start = len(eval_records)
        eval_records.extend(all_records[i] for i in indices)
        stop = len(eval_records)
        fps = session_fps(all_records, indices)
        assert fps is not None
        sessions.append((start, stop, fps))

    missing_cache = [
        r["image_path"] for r in eval_records
        if not (CACHE_DIR / f"{Path(r['image_path']).stem}.npy").exists()
    ]
    if missing_cache:
        raise RuntimeError(f"{len(missing_cache)} evaluated images lack cached features")

    imu_windows, _, _ = imu_sequence.build_sequence_dataset(
        eval_records, window=IMU_WINDOW, causal=True
    )
    truth = [r["label"] for r in eval_records]

    fusion_model, fusion_classes = load_model("fusion_louo_jimmy_")
    imu_model, imu_classes = load_model("imu_only_louo_jimmy_")
    predictions = {
        "Camera + IMU fusion": fusion_predictions(
            fusion_model, fusion_classes, eval_records, imu_windows
        ),
        "IMU only": imu_predictions(imu_model, imu_classes, imu_windows),
    }

    window_rows: list[dict] = []
    chosen_windows: dict[str, float] = {}
    unconstrained_best_windows: dict[str, float] = {}
    for modality, raw in predictions.items():
        modality_rows = []
        for seconds in WINDOW_SECONDS:
            metrics = score_sessions(
                truth, raw, sessions, vote_seconds=seconds, cadence_hz=None
            )
            row = {"modality": modality, "window_seconds": seconds, **metrics}
            window_rows.append(row)
            modality_rows.append(row)
        unconstrained_best_windows[modality] = max(
            modality_rows, key=lambda row: row["accuracy"]
        )["window_seconds"]
        chosen_windows[modality] = select_smallest_near_best(
            [
                row for row in modality_rows
                if row["window_seconds"] <= MAX_DEPLOYMENT_WINDOW_SECONDS
            ],
            "window_seconds",
        )["window_seconds"]

    cadence_rows: list[dict] = []
    recommendations: dict[str, dict] = {}
    for modality, raw in predictions.items():
        modality_rows = []
        for cadence in CADENCES_HZ:
            metrics = score_sessions(
                truth,
                raw,
                sessions,
                vote_seconds=chosen_windows[modality],
                cadence_hz=cadence,
            )
            row = {
                "modality": modality,
                "cadence_hz": cadence,
                "fixed_window_seconds": chosen_windows[modality],
                **metrics,
            }
            cadence_rows.append(row)
            modality_rows.append(row)
        # Lowest cadence within tolerance of the best is the efficiency choice.
        recommendations[modality] = select_smallest_near_best(
            modality_rows, "cadence_hz"
        )

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT_DIR / "window_vs_performance.csv", window_rows)
    write_csv(OUTPUT_DIR / "cadence_vs_performance.csv", cadence_rows)
    plot(
        window_rows,
        cadence_rows,
        OUTPUT_DIR / "window_and_cadence_performance.png",
    )
    summary = {
        "evaluation": {
            "target": TARGET,
            "training_participant": "anonymous|",
            "dense_sessions": len(sessions),
            "evaluated_frames": len(eval_records),
            "mean_source_fps": float(np.mean([fps for _, _, fps in sessions])),
            "same_frames_for_both_modalities": True,
            "cadence_scored_at_source_rate_with_label_hold": True,
        },
        "near_best_tolerance_accuracy_points": NEAR_BEST_TOL,
        "unconstrained_accuracy_best_window_seconds": unconstrained_best_windows,
        "deployment_window_latency_cap_seconds": MAX_DEPLOYMENT_WINDOW_SECONDS,
        "selected_deployment_vote_window_seconds": chosen_windows,
        "recommended_minimum_cadence": recommendations,
    }
    (OUTPUT_DIR / "summary.json").write_text(json.dumps(summary, indent=2))

    print(json.dumps(summary, indent=2))
    print(f"\nWrote results to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
