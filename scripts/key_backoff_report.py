#!/usr/bin/env python3
"""
Summarize per-trial key coverage and Gaussian backoff readiness.

For each trial and each key label, this script classifies which model source
would be used under a simple backoff chain:

1. `trial_specific`   -> enough taps in the current trial to fit a fresh key model
2. `prior_cumulative` -> not enough in the current trial, but enough in prior trials
3. `pooled_global`    -> not enough causally yet, but enough in the full dataset
4. `key_area`         -> no reliable Gaussian available; use the geometric key area

This is an offline dataset-audit tool. `pooled_global` is intentionally
non-causal: it answers whether the full cleaned dataset has enough support for a
key even when the early trials do not.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import median

import numpy as np

from numpy_analysis_utils import (
    build_count_matrix,
    build_trial_sequence,
    load_filtered_rows,
    sorted_labels,
    write_csv,
)


SOURCE_TRIAL_SPECIFIC = "trial_specific"
SOURCE_PRIOR_CUMULATIVE = "prior_cumulative"
SOURCE_POOLED_GLOBAL = "pooled_global"
SOURCE_KEY_AREA = "key_area"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", help="Path to a cleaned keystroke CSV")
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
        "--min-samples",
        type=int,
        default=5,
        help="Minimum taps required to consider a key Gaussian mature (default: 5)",
    )
    parser.add_argument(
        "--output-prefix",
        default=None,
        help="Prefix for output CSVs. Defaults to <input_stem>_key_backoff",
    )
    return parser.parse_args()


def classify_backoff_source(
    trial_taps: int,
    prior_taps: int,
    global_taps: int,
    min_samples: int,
) -> str:
    if trial_taps >= min_samples:
        return SOURCE_TRIAL_SPECIFIC
    if prior_taps >= min_samples:
        return SOURCE_PRIOR_CUMULATIVE
    if global_taps >= min_samples:
        return SOURCE_POOLED_GLOBAL
    return SOURCE_KEY_AREA


def run_report(
    csv_path: Path,
    label_column: str,
    include_space: bool,
    min_samples: int,
    output_prefix: str | None = None,
) -> dict[str, Path]:
    if not csv_path.exists():
        raise FileNotFoundError(f"Input CSV not found: {csv_path}")

    rows = load_filtered_rows(
        csv_path=csv_path,
        label_column=label_column,
        include_space=include_space,
        require_trial_index=True,
    )
    if not rows:
        raise ValueError("No usable rows after filtering. Check your CSV and options.")

    trial_ids, metadata = build_trial_sequence(rows, assign_field="trial_ordinal")
    if not trial_ids:
        raise ValueError("Need at least one usable trial to build the backoff report.")

    labels = sorted_labels(rows)
    count_matrix = build_count_matrix(rows, labels, trial_ids, unit_field="trial_ordinal")
    label_to_index = {label: index for index, label in enumerate(labels)}
    global_counts = count_matrix.sum(axis=0, dtype=np.int32)
    cumulative_counts = count_matrix.cumsum(axis=0, dtype=np.int32)

    detail_rows: list[dict] = []
    trial_summary_rows: list[dict] = []

    for row_index, trial_ordinal in enumerate(trial_ids):
        trial_counts = count_matrix[row_index]
        prior_counts = cumulative_counts[row_index - 1] if row_index > 0 else np.zeros(len(labels), dtype=np.int32)
        source_counts: dict[str, int] = {
            SOURCE_TRIAL_SPECIFIC: 0,
            SOURCE_PRIOR_CUMULATIVE: 0,
            SOURCE_POOLED_GLOBAL: 0,
            SOURCE_KEY_AREA: 0,
        }

        for label in labels:
            label_index = label_to_index[label]
            trial_taps = int(trial_counts[label_index])
            prior_taps = int(prior_counts[label_index])
            global_taps = int(global_counts[label_index])
            cumulative_taps = prior_taps + trial_taps
            source = classify_backoff_source(
                trial_taps=trial_taps,
                prior_taps=prior_taps,
                global_taps=global_taps,
                min_samples=min_samples,
            )
            source_counts[source] += 1
            detail_rows.append(
                {
                    "trial_ordinal": trial_ordinal,
                    "study_session_index": metadata[trial_ordinal]["study_session_index"],
                    "trial_index": metadata[trial_ordinal]["trial_index"],
                    "trial_id": metadata[trial_ordinal]["trial_id"],
                    "label": label,
                    "trial_taps": trial_taps,
                    "prior_taps": prior_taps,
                    "cumulative_taps": cumulative_taps,
                    "global_taps": global_taps,
                    "source": source,
                }
            )

        present_counts = trial_counts[trial_counts > 0]
        labels_present = int((trial_counts > 0).sum())
        trial_summary_rows.append(
            {
                "trial_ordinal": trial_ordinal,
                "study_session_index": metadata[trial_ordinal]["study_session_index"],
                "trial_index": metadata[trial_ordinal]["trial_index"],
                "trial_id": metadata[trial_ordinal]["trial_id"],
                "labels_tracked": len(labels),
                "labels_present_in_trial": labels_present,
                "labels_missing_in_trial": len(labels) - labels_present,
                "trial_specific_keys": source_counts[SOURCE_TRIAL_SPECIFIC],
                "prior_cumulative_keys": source_counts[SOURCE_PRIOR_CUMULATIVE],
                "pooled_global_keys": source_counts[SOURCE_POOLED_GLOBAL],
                "key_area_keys": source_counts[SOURCE_KEY_AREA],
                "min_present_key_taps": int(present_counts.min()) if present_counts.size else 0,
                "mean_present_key_taps": f"{float(present_counts.mean()) if present_counts.size else 0.0:.4f}",
                "max_present_key_taps": int(present_counts.max()) if present_counts.size else 0,
            }
        )

    key_summary_rows: list[dict] = []
    for label in labels:
        label_index = label_to_index[label]
        per_trial_counts = count_matrix[:, label_index]
        positive_mask = per_trial_counts > 0
        positive_trial_ids = [trial_ids[index] for index, present in enumerate(positive_mask) if present]
        positive_counts = per_trial_counts[positive_mask]

        first_present = positive_trial_ids[0] if positive_trial_ids else ""
        first_single_trial_mature = next(
            (trial_ids[index] for index, count in enumerate(per_trial_counts) if count >= min_samples),
            "",
        )

        cumulative_for_label = cumulative_counts[:, label_index]
        mature_indices = np.flatnonzero(cumulative_for_label >= min_samples)
        first_cumulative_mature = trial_ids[int(mature_indices[0])] if mature_indices.size else ""

        key_summary_rows.append(
            {
                "label": label,
                "global_taps": int(global_counts[label_index]),
                "trials_present": int(positive_mask.sum()),
                "min_present_trial_taps": int(positive_counts.min()) if positive_counts.size else 0,
                "mean_present_trial_taps": f"{float(positive_counts.mean()) if positive_counts.size else 0.0:.4f}",
                "max_present_trial_taps": int(positive_counts.max()) if positive_counts.size else 0,
                "first_trial_present": first_present,
                "first_trial_single_trial_mature": first_single_trial_mature,
                "first_trial_cumulative_mature": first_cumulative_mature,
                "global_status": SOURCE_POOLED_GLOBAL if int(global_counts[label_index]) >= min_samples else SOURCE_KEY_AREA,
            }
        )

    prefix = output_prefix or f"{csv_path.stem}_key_backoff"
    output_base = csv_path.parent / prefix
    trial_summary_path = output_base.with_name(output_base.name + "_trial_summary.csv")
    trial_detail_path = output_base.with_name(output_base.name + "_trial_key_detail.csv")
    key_summary_path = output_base.with_name(output_base.name + "_key_summary.csv")

    write_csv(
        trial_summary_path,
        fieldnames=[
            "trial_ordinal",
            "study_session_index",
            "trial_index",
            "trial_id",
            "labels_tracked",
            "labels_present_in_trial",
            "labels_missing_in_trial",
            "trial_specific_keys",
            "prior_cumulative_keys",
            "pooled_global_keys",
            "key_area_keys",
            "min_present_key_taps",
            "mean_present_key_taps",
            "max_present_key_taps",
        ],
        rows=trial_summary_rows,
    )
    write_csv(
        trial_detail_path,
        fieldnames=[
            "trial_ordinal",
            "study_session_index",
            "trial_index",
            "trial_id",
            "label",
            "trial_taps",
            "prior_taps",
            "cumulative_taps",
            "global_taps",
            "source",
        ],
        rows=detail_rows,
    )
    write_csv(
        key_summary_path,
        fieldnames=[
            "label",
            "global_taps",
            "trials_present",
            "min_present_trial_taps",
            "mean_present_trial_taps",
            "max_present_trial_taps",
            "first_trial_present",
            "first_trial_single_trial_mature",
            "first_trial_cumulative_mature",
            "global_status",
        ],
        rows=key_summary_rows,
    )

    positive_global_counts = global_counts[global_counts > 0]
    never_global = sorted(label for label in labels if int(global_counts[label_to_index[label]]) < min_samples)
    trials_with_key_area = sum(1 for row in trial_summary_rows if int(row["key_area_keys"]) > 0)

    print(f"Input CSV: {csv_path}")
    print(f"Usable rows: {len(rows)}")
    print(f"Trials found: {len(trial_ids)}")
    print(f"Labels tracked: {len(labels)}")
    if positive_global_counts.size:
        print(
            "Global per-key taps:"
            f" min={int(positive_global_counts.min())}"
            f" median={median(int(value) for value in positive_global_counts.tolist())}"
            f" max={int(positive_global_counts.max())}"
        )
    print(f"Trials requiring raw key-area fallback: {trials_with_key_area}/{len(trial_ids)}")
    if never_global:
        print("Keys never reaching pooled-global maturity: " + ", ".join(never_global))
    else:
        print("Every tracked key reaches pooled-global maturity.")
    print(f"trial_summary: {trial_summary_path}")
    print(f"trial_key_detail: {trial_detail_path}")
    print(f"key_summary: {key_summary_path}")

    return {
        "trial_summary": trial_summary_path,
        "trial_key_detail": trial_detail_path,
        "key_summary": key_summary_path,
    }


def main() -> None:
    args = parse_args()
    run_report(
        csv_path=Path(args.csv_path),
        label_column=args.label_column,
        include_space=not args.exclude_space,
        min_samples=args.min_samples,
        output_prefix=args.output_prefix,
    )


if __name__ == "__main__":
    main()
