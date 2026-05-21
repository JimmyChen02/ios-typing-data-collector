#!/usr/bin/env python3
"""
Generate a small synthetic cleaned-keystroke CSV and verify the key backoff report.

This is a quick manual sanity check for the backoff classification logic:

- `trial_specific` when the current trial has enough taps for a key
- `prior_cumulative` when only earlier trials have enough taps
- `pooled_global` when only the full dataset has enough taps
- `key_area` when no reliable Gaussian is available anywhere
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

from key_backoff_report import (
    SOURCE_KEY_AREA,
    SOURCE_POOLED_GLOBAL,
    SOURCE_PRIOR_CUMULATIVE,
    SOURCE_TRIAL_SPECIFIC,
    run_report,
)


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


def add_rows(
    rows: list[dict[str, str]],
    *,
    trial_index: int,
    label: str,
    count: int,
    timestamp_start: int,
    base_x: float,
    base_y: float,
) -> int:
    timestamp = timestamp_start
    for tap_index in range(count):
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
                "tap_norm_x": f"{base_x + 0.003 * tap_index:.6f}",
                "tap_norm_y": f"{base_y + 0.002 * tap_index:.6f}",
            }
        )
        timestamp += 10
    return timestamp


def synthetic_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    timestamp = 0

    # Trial 1: only "a" is mature within-trial. "b" and "c" will rely on
    # pooled-global support; "d" never matures anywhere.
    timestamp = add_rows(rows, trial_index=0, label="a", count=6, timestamp_start=timestamp, base_x=0.20, base_y=0.30)
    timestamp = add_rows(rows, trial_index=0, label="b", count=2, timestamp_start=timestamp, base_x=0.70, base_y=0.55)

    # Trial 2: "a" now has prior support, "b" is mature in-trial, "c" is still pooled-only.
    timestamp = add_rows(rows, trial_index=1, label="a", count=1, timestamp_start=timestamp, base_x=0.22, base_y=0.31)
    timestamp = add_rows(rows, trial_index=1, label="b", count=6, timestamp_start=timestamp, base_x=0.72, base_y=0.58)
    timestamp = add_rows(rows, trial_index=1, label="c", count=2, timestamp_start=timestamp, base_x=0.45, base_y=0.67)

    # Trial 3: "c" becomes mature in-trial.
    timestamp = add_rows(rows, trial_index=2, label="c", count=6, timestamp_start=timestamp, base_x=0.47, base_y=0.69)

    # Trial 4: "d" never reaches the threshold and should stay on key-area fallback.
    add_rows(rows, trial_index=3, label="d", count=2, timestamp_start=timestamp, base_x=0.30, base_y=0.80)
    return rows


def write_synthetic_csv(path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(synthetic_rows())


def load_detail_lookup(path: Path) -> dict[tuple[int, str], str]:
    lookup: dict[tuple[int, str], str] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            lookup[(int(row["trial_ordinal"]), row["label"])] = row["source"]
    return lookup


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    csv_path = output_dir / "synthetic_key_backoff_input.csv"
    write_synthetic_csv(csv_path)

    output_paths = run_report(
        csv_path=csv_path,
        label_column="expected_char",
        include_space=True,
        min_samples=5,
        output_prefix="synthetic_key_backoff",
    )

    lookup = load_detail_lookup(output_paths["trial_key_detail"])
    assert lookup[(1, "a")] == SOURCE_TRIAL_SPECIFIC
    assert lookup[(1, "b")] == SOURCE_POOLED_GLOBAL
    assert lookup[(1, "d")] == SOURCE_KEY_AREA
    assert lookup[(2, "a")] == SOURCE_PRIOR_CUMULATIVE
    assert lookup[(2, "b")] == SOURCE_TRIAL_SPECIFIC
    assert lookup[(3, "c")] == SOURCE_TRIAL_SPECIFIC
    assert lookup[(4, "d")] == SOURCE_KEY_AREA

    print(f"Synthetic input: {csv_path}")
    for label, output_path in output_paths.items():
        print(f"{label}: {output_path}")
    print("Synthetic key backoff report checks passed.")


if __name__ == "__main__":
    main()
