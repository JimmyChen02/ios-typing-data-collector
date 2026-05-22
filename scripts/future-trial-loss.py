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
import time
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
        help="Prefix for output CSVs. Defaults to <input_stem>_future_trial_loss",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    csv_path = Path(args.csv_path)
    if not csv_path.exists():
        raise SystemExit(f"Input CSV not found: {csv_path}")

    rows = load_filtered_rows(
        csv_path=csv_path,
        label_column=args.label_column,
        include_space=not args.exclude_space,
    )
    if not rows:
        raise SystemExit("No usable rows after filtering. Check your CSV and options.")

    trial_ids, _ = build_trial_sequence(rows)
    if len(trial_ids) < 2:
        raise SystemExit("Need at least two trials to compute future-trial loss.")

    labels = sorted_labels(rows)
    histogram_bank = HistogramBank.from_rows(rows, labels, trial_ids, args.grid_size)

    summary_rows: list[dict] = []
    for current_n in range(1, len(trial_ids)):
        reference_trials = trial_ids[:current_n]
        future_trials = trial_ids[current_n:]

        future_weighted_losses: list[float] = []
        future_mean_losses: list[float] = []

        for future_trial in future_trials:
            mean_similarity, weighted_similarity, _ = histogram_bank.compare_groups(
                reference_trials,
                [future_trial],
                args.min_taps,
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
                "similarity": format_float(None if avg_future_weighted_loss is None else 1.0 - avg_future_weighted_loss),
                "loss": format_float(avg_future_weighted_loss),
                "avg_future_weighted_loss": format_float(avg_future_weighted_loss),
                "avg_future_mean_loss": format_float(avg_future_mean_loss),
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
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
