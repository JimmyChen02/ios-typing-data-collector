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
import csv
import string
from collections import Counter, defaultdict
from pathlib import Path
from statistics import median


LETTER_KEYS = set(string.ascii_lowercase)
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

            if session_idx is None or trial_index is None or tap_x is None or tap_y is None or label is None:
                continue

            rows.append(
                {
                    "study_session_index": session_idx,
                    "trial_index": trial_index,
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
            row["trial_ordinal"] = ordinal

    return sequence, metadata


def mean(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


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


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def run_report(
    csv_path: Path,
    label_column: str,
    include_space: bool,
    min_samples: int,
    output_prefix: str | None = None,
) -> dict[str, Path]:
    if not csv_path.exists():
        raise FileNotFoundError(f"Input CSV not found: {csv_path}")

    rows = load_rows(
        csv_path=csv_path,
        label_column=label_column,
        include_space=include_space,
    )
    if not rows:
        raise ValueError("No usable rows after filtering. Check your CSV and options.")

    trial_ids, metadata = build_trial_sequence(rows)
    if not trial_ids:
        raise ValueError("Need at least one usable trial to build the backoff report.")

    labels = sorted({row["label"] for row in rows}, key=lambda key: (key == "space", key))
    global_counts = Counter(row["label"] for row in rows)
    trial_counters: dict[int, Counter[str]] = defaultdict(Counter)
    for row in rows:
        trial_counters[row["trial_ordinal"]][row["label"]] += 1

    detail_rows: list[dict] = []
    trial_summary_rows: list[dict] = []
    cumulative_counts: Counter[str] = Counter()

    for trial_ordinal in trial_ids:
        trial_counts = trial_counters.get(trial_ordinal, Counter())
        source_counts: Counter[str] = Counter()

        for label in labels:
            trial_taps = trial_counts.get(label, 0)
            prior_taps = cumulative_counts.get(label, 0)
            global_taps = global_counts.get(label, 0)
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

        present_counts = [count for count in trial_counts.values() if count > 0]
        trial_summary_rows.append(
            {
                "trial_ordinal": trial_ordinal,
                "study_session_index": metadata[trial_ordinal]["study_session_index"],
                "trial_index": metadata[trial_ordinal]["trial_index"],
                "trial_id": metadata[trial_ordinal]["trial_id"],
                "labels_tracked": len(labels),
                "labels_present_in_trial": sum(1 for count in trial_counts.values() if count > 0),
                "labels_missing_in_trial": len(labels) - sum(1 for count in trial_counts.values() if count > 0),
                "trial_specific_keys": source_counts[SOURCE_TRIAL_SPECIFIC],
                "prior_cumulative_keys": source_counts[SOURCE_PRIOR_CUMULATIVE],
                "pooled_global_keys": source_counts[SOURCE_POOLED_GLOBAL],
                "key_area_keys": source_counts[SOURCE_KEY_AREA],
                "min_present_key_taps": min(present_counts) if present_counts else 0,
                "mean_present_key_taps": f"{mean([float(v) for v in present_counts]) or 0.0:.4f}",
                "max_present_key_taps": max(present_counts) if present_counts else 0,
            }
        )

        cumulative_counts.update(trial_counts)

    key_summary_rows: list[dict] = []
    for label in labels:
        per_trial_counts = [trial_counters[trial_id].get(label, 0) for trial_id in trial_ids]
        present_pairs = [(trial_id, count) for trial_id, count in zip(trial_ids, per_trial_counts) if count > 0]
        first_present = present_pairs[0][0] if present_pairs else ""
        first_single_trial_mature = next((trial_id for trial_id, count in present_pairs if count >= min_samples), "")

        running = 0
        first_cumulative_mature = ""
        for trial_id, count in zip(trial_ids, per_trial_counts):
            running += count
            if running >= min_samples:
                first_cumulative_mature = trial_id
                break

        positive_counts = [count for count in per_trial_counts if count > 0]
        key_summary_rows.append(
            {
                "label": label,
                "global_taps": global_counts[label],
                "trials_present": len(positive_counts),
                "min_present_trial_taps": min(positive_counts) if positive_counts else 0,
                "mean_present_trial_taps": f"{mean([float(v) for v in positive_counts]) or 0.0:.4f}",
                "max_present_trial_taps": max(positive_counts) if positive_counts else 0,
                "first_trial_present": first_present,
                "first_trial_single_trial_mature": first_single_trial_mature,
                "first_trial_cumulative_mature": first_cumulative_mature,
                "global_status": SOURCE_POOLED_GLOBAL if global_counts[label] >= min_samples else SOURCE_KEY_AREA,
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

    positive_global_counts = [count for count in global_counts.values() if count > 0]
    never_global = sorted(label for label in labels if global_counts[label] < min_samples)
    trials_with_key_area = sum(1 for row in trial_summary_rows if int(row["key_area_keys"]) > 0)

    print(f"Input CSV: {csv_path}")
    print(f"Usable rows: {len(rows)}")
    print(f"Trials found: {len(trial_ids)}")
    print(f"Labels tracked: {len(labels)}")
    if positive_global_counts:
        print(
            "Global per-key taps:"
            f" min={min(positive_global_counts)}"
            f" median={median(positive_global_counts)}"
            f" max={max(positive_global_counts)}"
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
