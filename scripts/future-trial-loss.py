#!/usr/bin/env python3
"""
Compute average future-trial overlap loss for classic-keyboard touch regions.

For each trial count N, this script:

    1. Builds a cumulative reference set from trials {1..N}
    2. Compares that reference against every future trial {N+1}, {N+2}, ... {T}
    3. Averages the resulting losses

Similarity is normalized weighted-Jaccard overlap on grid-cell histograms:

    similarity = sum(min(p_A, p_B)) / sum(max(p_A, p_B))

where p_A and p_B are per-cell normalized tap densities.

Loss is defined as:

    loss = 1 - weighted_mean_similarity
"""

from __future__ import annotations

import argparse
import csv
import string
from collections import defaultdict
from pathlib import Path


LETTER_KEYS = set(string.ascii_lowercase)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", help="Path to a cleaned keystroke CSV")
    parser.add_argument(
        "--grid-size",
        type=int,
        default=50,
        help="Number of bins per axis for tap histograms (default: 50)",
    )
    parser.add_argument(
        "--label-column",
        choices=["expected_char", "key_label"],
        default="expected_char",
        help="Column used to group taps into keys (default: expected_char)",
    )
    parser.add_argument(
        "--exclude-space",
        action="store_true",
        help="Exclude the space key from the analysis",
    )
    parser.add_argument(
        "--min-taps",
        type=int,
        default=5,
        help="Minimum taps required on each side before a key contributes (default: 5)",
    )
    parser.add_argument(
        "--output-prefix",
        default=None,
        help="Prefix for output CSVs. Defaults to <input_stem>_future_trial_loss",
    )
    return parser.parse_args()


def safe_int(value: str | None) -> int | None:
    try:
        return int(value) if value not in (None, "") else None
    except ValueError:
        return None


def safe_float(value: str | None) -> float | None:
    try:
        return float(value) if value not in (None, "") else None
    except ValueError:
        return None


def canonical_label(raw: str, include_space: bool) -> str | None:
    if raw == " ":
        return "space" if include_space else None
    key = raw.strip().lower()
    if key in LETTER_KEYS:
        return key
    if include_space and key == "space":
        return "space"
    return None


def load_rows(csv_path: Path, label_column: str, include_space: bool) -> list[dict]:
    rows: list[dict] = []
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("session_mode") != "classic":
                continue
            if row.get("event_type") != "insert":
                continue
            if row.get("is_outlier") != "0":
                continue

            session_idx = safe_int(row.get("study_session_index"))
            trial_index = safe_int(row.get("trial_index"))
            tap_x = safe_float(row.get("tap_norm_x"))
            tap_y = safe_float(row.get("tap_norm_y"))
            timestamp_ms = safe_float(row.get("timestamp_ms"))
            label = canonical_label(row.get(label_column, ""), include_space)

            if session_idx is None or tap_x is None or tap_y is None or label is None:
                continue

            rows.append(
                {
                    "study_session_index": session_idx,
                    "trial_index": trial_index if trial_index is not None else 0,
                    "trial_id": (row.get("trial_id") or "").strip(),
                    "timestamp_ms": timestamp_ms if timestamp_ms is not None else 0.0,
                    "label": label,
                    "tap_norm_x": tap_x,
                    "tap_norm_y": tap_y,
                }
            )
    return rows


def build_trial_sequence(rows: list[dict]) -> tuple[list[int], dict[int, dict]]:
    by_trial: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for row in rows:
        key = (row["study_session_index"], row["trial_index"])
        by_trial[key].append(row)

    ordered_trials = sorted(
        by_trial.items(),
        key=lambda item: (
            item[0][0],
            item[0][1],
            min(r["timestamp_ms"] for r in item[1]),
        ),
    )

    sequence: list[int] = []
    metadata: dict[int, dict] = {}
    for ordinal, (trial_key, trial_rows) in enumerate(ordered_trials, start=1):
        session_idx, trial_index = trial_key
        trial_id = next((r["trial_id"] for r in trial_rows if r["trial_id"]), "")
        sequence.append(ordinal)
        metadata[ordinal] = {
            "study_session_index": session_idx,
            "trial_index": trial_index,
            "trial_id": trial_id,
        }
        for row in trial_rows:
            row["unit_id"] = ordinal

    return sequence, metadata


def build_histogram(points: list[tuple[float, float]], grid_size: int) -> dict[tuple[int, int], int]:
    histogram: dict[tuple[int, int], int] = defaultdict(int)
    for x, y in points:
        col = min(max(int(x * grid_size), 0), grid_size - 1)
        row = min(max(int(y * grid_size), 0), grid_size - 1)
        histogram[(row, col)] += 1
    return dict(histogram)


def compute_weighted_jaccard(
    hist_a: dict[tuple[int, int], int],
    hist_b: dict[tuple[int, int], int],
) -> float | None:
    total_a = sum(hist_a.values())
    total_b = sum(hist_b.values())
    if total_a == 0 or total_b == 0:
        return None

    union_cells = set(hist_a) | set(hist_b)
    numerator = 0.0
    denominator = 0.0
    for cell in union_cells:
        p_a = hist_a.get(cell, 0) / total_a
        p_b = hist_b.get(cell, 0) / total_b
        numerator += min(p_a, p_b)
        denominator += max(p_a, p_b)

    if denominator == 0.0:
        return None
    return numerator / denominator


def group_key_points(rows: list[dict]) -> dict[tuple[int, str], list[tuple[float, float]]]:
    grouped: dict[tuple[int, str], list[tuple[float, float]]] = defaultdict(list)
    for row in rows:
        grouped[(row["unit_id"], row["label"])].append((row["tap_norm_x"], row["tap_norm_y"]))
    return grouped


def mean(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def weighted_mean(values: list[tuple[float, int]]) -> float | None:
    if not values:
        return None
    total_weight = sum(weight for _, weight in values)
    if total_weight == 0:
        return None
    return sum(value * weight for value, weight in values) / total_weight


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def compare_groups(
    grouped: dict[tuple[int, str], list[tuple[float, float]]],
    labels: list[str],
    group_a: list[int],
    group_b: list[int],
    grid_size: int,
    min_taps: int,
) -> tuple[float | None, float | None, int]:
    similarities: list[float] = []
    weighted_pairs: list[tuple[float, int]] = []

    for label in labels:
        points_a: list[tuple[float, float]] = []
        points_b: list[tuple[float, float]] = []

        for unit_id in group_a:
            points_a.extend(grouped.get((unit_id, label), []))
        for unit_id in group_b:
            points_b.extend(grouped.get((unit_id, label), []))

        n_a = len(points_a)
        n_b = len(points_b)
        if n_a < min_taps or n_b < min_taps:
            continue

        hist_a = build_histogram(points_a, grid_size)
        hist_b = build_histogram(points_b, grid_size)
        similarity = compute_weighted_jaccard(hist_a, hist_b)
        if similarity is None:
            continue

        similarities.append(similarity)
        weighted_pairs.append((similarity, n_a + n_b))

    return mean(similarities), weighted_mean(weighted_pairs), len(similarities)


def main() -> None:
    args = parse_args()
    csv_path = Path(args.csv_path)
    if not csv_path.exists():
        raise SystemExit(f"Input CSV not found: {csv_path}")

    rows = load_rows(
        csv_path=csv_path,
        label_column=args.label_column,
        include_space=not args.exclude_space,
    )
    if not rows:
        raise SystemExit("No usable rows after filtering. Check your CSV and options.")

    trial_ids, metadata = build_trial_sequence(rows)
    if len(trial_ids) < 2:
        raise SystemExit("Need at least two trials to compute future-trial loss.")

    labels = sorted({row["label"] for row in rows}, key=lambda key: (key == "space", key))
    grouped = group_key_points(rows)

    summary_rows: list[dict] = []
    for current_n in range(1, len(trial_ids)):
        reference_trials = trial_ids[:current_n]
        future_trials = trial_ids[current_n:]

        future_weighted_losses: list[float] = []
        future_mean_losses: list[float] = []

        for future_trial in future_trials:
            mean_similarity, weighted_similarity, num_keys = compare_groups(
                grouped=grouped,
                labels=labels,
                group_a=reference_trials,
                group_b=[future_trial],
                grid_size=args.grid_size,
                min_taps=args.min_taps,
            )

            mean_loss = None if mean_similarity is None else 1.0 - mean_similarity
            weighted_loss = None if weighted_similarity is None else 1.0 - weighted_similarity

            if weighted_loss is not None:
                future_weighted_losses.append(weighted_loss)
            if mean_loss is not None:
                future_mean_losses.append(mean_loss)

        avg_future_weighted_loss = mean(future_weighted_losses)
        avg_future_mean_loss = mean(future_mean_losses)

        summary_rows.append(
            {
                "num_trials": current_n,
                "num_future_trials": len(future_trials),
                "similarity": (
                    "" if avg_future_weighted_loss is None else f"{1.0 - avg_future_weighted_loss:.6f}"
                ),
                "loss": (
                    "" if avg_future_weighted_loss is None else f"{avg_future_weighted_loss:.6f}"
                ),
                "avg_future_weighted_loss": (
                    "" if avg_future_weighted_loss is None else f"{avg_future_weighted_loss:.6f}"
                ),
                "avg_future_mean_loss": (
                    "" if avg_future_mean_loss is None else f"{avg_future_mean_loss:.6f}"
                ),
            }
        )

    output_prefix = args.output_prefix or f"{csv_path.stem}_future_trial_loss"
    output_base = csv_path.parent / output_prefix
    summary_path = output_base.with_name(output_base.name + "_summary.csv")

    write_csv(
        summary_path,
        fieldnames=[
            "num_trials",
            "num_future_trials",
            "similarity",
            "loss",
            "avg_future_weighted_loss",
            "avg_future_mean_loss",
        ],
        rows=summary_rows,
    )

    print(f"Input CSV: {csv_path}")
    print(f"Usable rows: {len(rows)}")
    print(f"Trials found: {trial_ids}")
    print(f"Concise future-loss summary: {summary_path}")


if __name__ == "__main__":
    main()
