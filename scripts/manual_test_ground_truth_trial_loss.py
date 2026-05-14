#!/usr/bin/env python3
"""
Generate a small synthetic cleaned-keystroke CSV and run the ground-truth loss
analysis against it.

This uses the same computation path as scripts/ground_truth_trial_loss.py, so it
is a quick manual sanity check for the CSV outputs and the k == total_trials
endpoint.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

from ground_truth_trial_loss import run_analysis


FIELDNAMES = [
    "session_mode",
    "event_type",
    "is_outlier",
    "study_session_index",
    "trial_index",
    "trial_id",
    "timestamp_ms",
    "expected_char",
    "key_label",
    "tap_norm_x",
    "tap_norm_y",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory where the synthetic CSV and result CSVs are written",
    )
    return parser.parse_args()


def synthetic_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    trial_offsets = [0.00, 0.02, 0.04]
    base_points = {
        "a": (0.20, 0.30),
        "b": (0.72, 0.62),
    }

    timestamp = 0
    for trial_index, offset in enumerate(trial_offsets):
        for label, (base_x, base_y) in base_points.items():
            for tap_index in range(6):
                tap_x = base_x + offset + 0.004 * tap_index
                tap_y = base_y + offset / 2.0 + 0.003 * tap_index
                rows.append(
                    {
                        "session_mode": "classic",
                        "event_type": "insert",
                        "is_outlier": "0",
                        "study_session_index": "1",
                        "trial_index": str(trial_index),
                        "trial_id": f"trial-{trial_index + 1}",
                        "timestamp_ms": str(timestamp),
                        "expected_char": label,
                        "key_label": label,
                        "tap_norm_x": f"{tap_x:.6f}",
                        "tap_norm_y": f"{tap_y:.6f}",
                    }
                )
                timestamp += 10
    return rows


def write_synthetic_csv(path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(synthetic_rows())


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    csv_path = output_dir / "synthetic_ground_truth_trial_loss_input.csv"
    write_synthetic_csv(csv_path)

    output_paths = run_analysis(
        csv_path=csv_path,
        grid_size=25,
        label_column="expected_char",
        include_space=True,
        min_taps=5,
        output_prefix="synthetic_ground_truth_trial_loss",
    )

    print(f"Synthetic input: {csv_path}")
    for label, output_path in output_paths.items():
        print(f"{label}: {output_path}")


if __name__ == "__main__":
    main()
