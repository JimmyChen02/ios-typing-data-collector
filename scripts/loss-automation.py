#!/usr/bin/env python3
"""
===================================================================================================


NOT USED ANYMORE (USE FUTURE TRIAL EVAL AS IT'S BETTER AT SEEING HOW CURR WILL PRED FUTURE


===================================================================================================


Compute progressive overlap loss for classic-keyboard touch regions. 

Trial/session comparisons are built in this order:

    {1} vs {1}
    {1} vs {2}
    {1,2} vs {3}
    {1,2,3} vs {4}

The default similarity metric is normalized weighted-Jaccard overlap on
grid-cell histograms:

    similarity = sum(min(p_A, p_B)) / sum(max(p_A, p_B))

where p_A and p_B are per-cell normalized tap densities.

Loss is defined as:

    loss = 1 - weighted_mean_similarity
"""

from __future__ import annotations
import argparse
import csv
import string
import time
from collections import defaultdict
from pathlib import Path


LETTER_KEYS = set(string.ascii_lowercase)

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", help="Path to a cleaned keystroke CSV")
    parser.add_argument(
        "--unit",
        choices=["trial", "session"],
        default="trial",
        help="Granularity for cumulative comparisons (default: trial)",
    )
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
        help="Exclude the space key from the IoU analysis",
    )
    parser.add_argument(
        "--min-taps",
        type=int,
        default=5,
        help="Minimum taps required on each side before IoU is reported (default: 5)",
    )
    parser.add_argument(
        "--output-prefix",
        default=None,
        help="Prefix for output CSVs. Defaults to <input_stem>_<unit>_overlap",
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

def build_unit_sequence(rows: list[dict], unit: str) -> tuple[list[int], dict[int, dict]]:
    if unit == "session":
        session_ids = sorted({row["study_session_index"] for row in rows})
        metadata = {
            session_id: {
                "display": f"session {session_id}",
                "study_session_index": session_id,
                "trial_index": "",
                "trial_id": "",
            }
            for session_id in session_ids
        }
        return session_ids, metadata

    # trial-level sequence ordered by (session, trial_index, first timestamp).
    # We intentionally ignore trial_id here so a stray row with a mismatched UUID
    # does not get split into its own pseudo-trial.
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
            "display": f"trial {ordinal}",
            "study_session_index": session_idx,
            "trial_index": trial_index,
            "trial_id": trial_id,
        }
        for row in trial_rows:
            row["unit_id"] = ordinal

    return sequence, metadata

def attach_session_unit_ids(rows: list[dict]) -> None:
    for row in rows:
        row["unit_id"] = row["study_session_index"]

def progressive_pairs(unit_ids: list[int]) -> list[tuple[list[int], list[int]]]:
    pairs: list[tuple[list[int], list[int]]] = []
    sorted_ids = sorted(unit_ids)
    if not sorted_ids:
        return pairs

    pairs.append(([sorted_ids[0]], [sorted_ids[0]]))
    for idx in range(1, len(sorted_ids)):
        group_a = sorted_ids[:idx]
        group_b = [sorted_ids[idx]]
        pairs.append((group_a, group_b))
    return pairs

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

def format_group(unit_ids: list[int]) -> str:
    return "{" + ",".join(str(i) for i in unit_ids) + "}"

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

    if args.unit == "session":
        attach_session_unit_ids(rows)
    unit_ids, metadata = build_unit_sequence(rows, args.unit)
    if len(unit_ids) < 1:
        raise SystemExit(f"Need at least one {args.unit} to compute IoU/loss.")

    labels = sorted({row["label"] for row in rows}, key=lambda key: (key == "space", key))
    grouped = group_key_points(rows)
    comparisons = progressive_pairs(unit_ids)

    loss_rows: list[dict] = []

    for group_a, group_b in comparisons:
        group_a_label = format_group(group_a)
        group_b_label = format_group(group_b)
        comparison_similarities: list[float] = []
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

            similarity_value: float | None = None
            loss_value: float | None = None
            if n_a >= args.min_taps and n_b >= args.min_taps:
                hist_a = build_histogram(points_a, args.grid_size)
                hist_b = build_histogram(points_b, args.grid_size)
                similarity_value = compute_weighted_jaccard(hist_a, hist_b)
                if similarity_value is not None:
                    loss_value = 1.0 - similarity_value
                    comparison_similarities.append(similarity_value)
                    weighted_pairs.append((similarity_value, n_a + n_b))

        mean_similarity = mean(comparison_similarities)
        weighted_similarity = weighted_mean(weighted_pairs)
        mean_loss = None if mean_similarity is None else 1.0 - mean_similarity
        weighted_loss = None if weighted_similarity is None else 1.0 - weighted_similarity
        current_unit = group_b[0]

        loss_rows.append(
            {
                "num_trials": current_unit if args.unit == "trial" else "",
                "similarity": "" if weighted_similarity is None else f"{weighted_similarity:.6f}",
                "loss": "" if weighted_loss is None else f"{weighted_loss:.6f}",
                "weighted_mean_loss": "" if weighted_loss is None else f"{weighted_loss:.6f}",
                "mean_loss": "" if mean_loss is None else f"{mean_loss:.6f}",
            }
        )

    output_prefix = args.output_prefix or f"{csv_path.stem}_{args.unit}_overlap"
    output_base = csv_path.parent / output_prefix
    loss_path = output_base.with_name(output_base.name + "_loss.csv")

    write_csv(
        loss_path,
        fieldnames=[
            "num_trials",
            "similarity",
            "loss",
            "weighted_mean_loss",
            "mean_loss",
        ],
        rows=loss_rows,
    )

    print(f"Input CSV: {csv_path}")
    print(f"Usable rows: {len(rows)}")
    print(f"Unit: {args.unit}")
    print(f"Units found: {unit_ids}")
    print(f"Concise results: {loss_path}")

if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
