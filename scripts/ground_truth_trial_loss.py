#!/usr/bin/env python3
"""
Compute ground-truth trial loss for classic-keyboard touch regions.

Ground truth is built from all usable trials. The script then evaluates:

1. Simple / prefix mode:
   {1}, {1,2}, {1,2,3}, ... vs {all trials}

2. All-combinations mode:
   Every size-k subset vs {all trials}, averaged within each k

Similarity is normalized weighted-Jaccard overlap on grid-cell histograms:

    similarity = sum(min(p_A, p_B)) / sum(max(p_A, p_B))

where p_A and p_B are per-cell normalized tap densities.

Loss is defined as:

    loss = 1 - weighted_mean_similarity
"""

from __future__ import annotations

import argparse
import time
from itertools import combinations
from pathlib import Path

from numpy_analysis_utils import (
    HistogramBank,
    build_trial_sequence,
    format_float,
    load_filtered_rows,
    mean,
    sorted_labels,
    write_csv,
)


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
        help="Prefix for output CSVs. Defaults to <input_stem>_ground_truth_trial_loss",
    )
    return parser.parse_args()


def format_group(group: list[int] | tuple[int, ...]) -> str:
    return "{" + ",".join(str(unit_id) for unit_id in group) + "}"


def make_simple_rows(
    trial_ids: list[int],
    histogram_bank: HistogramBank,
    min_taps: int,
) -> list[dict]:
    ground_truth = trial_ids
    rows: list[dict] = []

    for k in range(1, len(trial_ids) + 1):
        subset = trial_ids[:k]
        mean_similarity, weighted_similarity, num_keys = histogram_bank.compare_groups(
            subset,
            ground_truth,
            min_taps,
        )
        mean_loss = None if mean_similarity is None else 1.0 - mean_similarity
        weighted_loss = None if weighted_similarity is None else 1.0 - weighted_similarity

        rows.append(
            {
                "num_trials": k,
                "total_trials": len(trial_ids),
                "subset": format_group(subset),
                "ground_truth": format_group(ground_truth),
                "num_keys_compared": num_keys,
                "similarity": format_float(weighted_similarity),
                "loss": format_float(weighted_loss),
                "weighted_mean_loss": format_float(weighted_loss),
                "mean_loss": format_float(mean_loss),
            }
        )

    return rows


def make_combination_rows(
    trial_ids: list[int],
    histogram_bank: HistogramBank,
    min_taps: int,
) -> list[dict]:
    ground_truth = trial_ids
    summary_rows: list[dict] = []

    for k in range(1, len(trial_ids) + 1):
        weighted_losses: list[float] = []
        mean_losses: list[float] = []
        weighted_similarities: list[float] = []
        combination_count = 0

        for combo in combinations(trial_ids, k):
            mean_similarity, weighted_similarity, _ = histogram_bank.compare_groups(
                combo,
                ground_truth,
                min_taps,
            )
            mean_loss = None if mean_similarity is None else 1.0 - mean_similarity
            weighted_loss = None if weighted_similarity is None else 1.0 - weighted_similarity

            if weighted_similarity is not None:
                weighted_similarities.append(weighted_similarity)
            if weighted_loss is not None:
                weighted_losses.append(weighted_loss)
            if mean_loss is not None:
                mean_losses.append(mean_loss)

            combination_count += 1

        avg_weighted_similarity = mean(weighted_similarities)
        avg_weighted_loss = mean(weighted_losses)
        avg_mean_loss = mean(mean_losses)

        summary_rows.append(
            {
                "num_trials": k,
                "total_trials": len(trial_ids),
                "num_combinations": combination_count,
                "ground_truth": format_group(ground_truth),
                "similarity": format_float(avg_weighted_similarity),
                "loss": format_float(avg_weighted_loss),
                "avg_combination_weighted_loss": format_float(avg_weighted_loss),
                "avg_combination_mean_loss": format_float(avg_mean_loss),
            }
        )

    return summary_rows


def run_analysis(
    csv_path: Path,
    grid_size: int,
    label_column: str,
    include_space: bool,
    min_taps: int,
    output_prefix: str | None = None,
) -> dict[str, Path]:
    if not csv_path.exists():
        raise FileNotFoundError(f"Input CSV not found: {csv_path}")

    rows = load_filtered_rows(
        csv_path=csv_path,
        label_column=label_column,
        include_space=include_space,
    )
    if not rows:
        raise ValueError("No usable rows after filtering. Check your CSV and options.")

    trial_ids, _ = build_trial_sequence(rows)
    if len(trial_ids) < 1:
        raise ValueError("Need at least one trial to compute ground-truth loss.")

    labels = sorted_labels(rows)
    histogram_bank = HistogramBank.from_rows(rows, labels, trial_ids, grid_size)

    simple_rows = make_simple_rows(
        trial_ids=trial_ids,
        histogram_bank=histogram_bank,
        min_taps=min_taps,
    )
    combination_summary_rows = make_combination_rows(
        trial_ids=trial_ids,
        histogram_bank=histogram_bank,
        min_taps=min_taps,
    )

    prefix = output_prefix or f"{csv_path.stem}_ground_truth_trial_loss"
    output_base = csv_path.parent / prefix

    simple_path = output_base.with_name(output_base.name + "_simple_summary.csv")
    combinations_summary_path = output_base.with_name(
        output_base.name + "_all_combinations_summary.csv"
    )

    write_csv(
        simple_path,
        fieldnames=[
            "num_trials",
            "total_trials",
            "subset",
            "ground_truth",
            "num_keys_compared",
            "similarity",
            "loss",
            "weighted_mean_loss",
            "mean_loss",
        ],
        rows=simple_rows,
    )
    write_csv(
        combinations_summary_path,
        fieldnames=[
            "num_trials",
            "total_trials",
            "num_combinations",
            "ground_truth",
            "similarity",
            "loss",
            "avg_combination_weighted_loss",
            "avg_combination_mean_loss",
        ],
        rows=combination_summary_rows,
    )

    return {
        "simple_summary": simple_path,
        "all_combinations_summary": combinations_summary_path,
    }


def main() -> None:
    args = parse_args()
    csv_path = Path(args.csv_path)

    output_paths = run_analysis(
        csv_path=csv_path,
        grid_size=args.grid_size,
        label_column=args.label_column,
        include_space=not args.exclude_space,
        min_taps=args.min_taps,
        output_prefix=args.output_prefix,
    )

    print(f"Input CSV: {csv_path}")
    for label, output_path in output_paths.items():
        print(f"{label}: {output_path}")


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
