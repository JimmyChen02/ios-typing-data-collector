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
import time
from pathlib import Path

from numpy_analysis_utils import (
    HistogramBank,
    build_unit_sequence,
    format_float,
    load_filtered_rows,
    sorted_labels,
    write_csv,
)


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

    unit_ids, _ = build_unit_sequence(rows, args.unit)
    if len(unit_ids) < 1:
        raise SystemExit(f"Need at least one {args.unit} to compute IoU/loss.")

    labels = sorted_labels(rows)
    histogram_bank = HistogramBank.from_rows(rows, labels, unit_ids, args.grid_size)
    comparisons = progressive_pairs(unit_ids)

    loss_rows: list[dict] = []

    for group_a, group_b in comparisons:
        mean_similarity, weighted_similarity, compared_keys = histogram_bank.compare_groups(
            group_a,
            group_b,
            args.min_taps,
        )
        mean_loss = None if mean_similarity is None else 1.0 - mean_similarity
        weighted_loss = None if weighted_similarity is None else 1.0 - weighted_similarity
        current_unit = group_b[0]

        loss_rows.append(
            {
                "num_trials": current_unit if args.unit == "trial" else "",
                "num_keys_compared": compared_keys,
                "similarity": format_float(weighted_similarity),
                "loss": format_float(weighted_loss),
                "weighted_mean_loss": format_float(weighted_loss),
                "mean_loss": format_float(mean_loss),
            }
        )

    output_prefix = args.output_prefix or f"{csv_path.stem}_{args.unit}_overlap"
    output_base = csv_path.parent / output_prefix
    loss_path = output_base.with_name(output_base.name + "_loss.csv")

    write_csv(
        loss_path,
        fieldnames=[
            "num_trials",
            "num_keys_compared",
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
