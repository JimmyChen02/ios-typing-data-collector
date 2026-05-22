#!/usr/bin/env python3
from __future__ import annotations

import csv
import string
from dataclasses import dataclass
from pathlib import Path

import numpy as np


LETTER_KEYS = set(string.ascii_lowercase)


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


def format_float(value: float | None) -> str:
    return "" if value is None else f"{value:.6f}"


def sorted_labels(rows: list[dict]) -> list[str]:
    return sorted({row["label"] for row in rows}, key=lambda key: (key == "space", key))


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def load_filtered_rows(
    csv_path: Path,
    label_column: str,
    include_space: bool,
    *,
    require_trial_index: bool = False,
) -> list[dict]:
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
            if require_trial_index and trial_index is None:
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


def build_trial_sequence(
    rows: list[dict],
    *,
    assign_field: str = "unit_id",
) -> tuple[list[int], dict[int, dict]]:
    by_trial: dict[tuple[int, int], list[dict]] = {}
    for row in rows:
        key = (row["study_session_index"], row["trial_index"])
        by_trial.setdefault(key, []).append(row)

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
            row[assign_field] = ordinal

    return sequence, metadata


def attach_session_unit_ids(rows: list[dict], *, field_name: str = "unit_id") -> None:
    for row in rows:
        row[field_name] = row["study_session_index"]


def build_unit_sequence(
    rows: list[dict],
    unit: str,
    *,
    assign_field: str = "unit_id",
) -> tuple[list[int], dict[int, dict]]:
    if unit == "session":
        attach_session_unit_ids(rows, field_name=assign_field)
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

    return build_trial_sequence(rows, assign_field=assign_field)


def build_count_matrix(
    rows: list[dict],
    labels: list[str],
    unit_ids: list[int],
    *,
    unit_field: str = "unit_id",
) -> np.ndarray:
    label_to_index = {label: index for index, label in enumerate(labels)}
    unit_to_index = {unit_id: index for index, unit_id in enumerate(unit_ids)}
    matrix = np.zeros((len(unit_ids), len(labels)), dtype=np.int32)

    if not rows or not labels or not unit_ids:
        return matrix

    unit_index = np.fromiter(
        (unit_to_index.get(int(row[unit_field]), -1) for row in rows),
        dtype=np.int32,
        count=len(rows),
    )
    label_index = np.fromiter(
        (label_to_index[row["label"]] for row in rows),
        dtype=np.int32,
        count=len(rows),
    )
    valid = unit_index >= 0
    np.add.at(matrix, (unit_index[valid], label_index[valid]), 1)
    return matrix


@dataclass(frozen=True)
class HistogramBank:
    labels: list[str]
    unit_ids: list[int]
    grid_size: int
    histograms: np.ndarray
    totals: np.ndarray
    unit_to_index: dict[int, int]

    @classmethod
    def from_rows(
        cls,
        rows: list[dict],
        labels: list[str],
        unit_ids: list[int],
        grid_size: int,
        *,
        unit_field: str = "unit_id",
    ) -> "HistogramBank":
        unit_to_index = {unit_id: index for index, unit_id in enumerate(unit_ids)}
        label_to_index = {label: index for index, label in enumerate(labels)}
        cell_count = grid_size * grid_size
        histograms = np.zeros((len(unit_ids), len(labels), cell_count), dtype=np.float32)

        if rows and labels and unit_ids:
            unit_index = np.fromiter(
                (unit_to_index.get(int(row[unit_field]), -1) for row in rows),
                dtype=np.int32,
                count=len(rows),
            )
            label_index = np.fromiter(
                (label_to_index[row["label"]] for row in rows),
                dtype=np.int32,
                count=len(rows),
            )
            tap_x = np.fromiter((float(row["tap_norm_x"]) for row in rows), dtype=np.float32, count=len(rows))
            tap_y = np.fromiter((float(row["tap_norm_y"]) for row in rows), dtype=np.float32, count=len(rows))

            cols = np.clip((tap_x * grid_size).astype(np.int32), 0, grid_size - 1)
            rows_idx = np.clip((tap_y * grid_size).astype(np.int32), 0, grid_size - 1)
            bins = rows_idx * grid_size + cols
            valid = unit_index >= 0
            np.add.at(histograms, (unit_index[valid], label_index[valid], bins[valid]), 1.0)

        totals = histograms.sum(axis=2, dtype=np.float32)
        return cls(
            labels=labels,
            unit_ids=unit_ids,
            grid_size=grid_size,
            histograms=histograms,
            totals=totals,
            unit_to_index=unit_to_index,
        )

    def compare_groups(
        self,
        group_a: list[int] | tuple[int, ...],
        group_b: list[int] | tuple[int, ...],
        min_taps: int,
    ) -> tuple[float | None, float | None, int]:
        if not group_a or not group_b:
            return None, None, 0

        group_a_index = np.array([self.unit_to_index[unit_id] for unit_id in group_a], dtype=np.int32)
        group_b_index = np.array([self.unit_to_index[unit_id] for unit_id in group_b], dtype=np.int32)

        hist_a = self.histograms[group_a_index].sum(axis=0, dtype=np.float32)
        hist_b = self.histograms[group_b_index].sum(axis=0, dtype=np.float32)
        total_a = hist_a.sum(axis=1, dtype=np.float32)
        total_b = hist_b.sum(axis=1, dtype=np.float32)
        valid = (total_a >= min_taps) & (total_b >= min_taps)
        if not np.any(valid):
            return None, None, 0

        min_mass = np.minimum(hist_a[valid], hist_b[valid]).sum(axis=1, dtype=np.float32)
        max_mass = np.maximum(hist_a[valid], hist_b[valid]).sum(axis=1, dtype=np.float32)
        positive = max_mass > 0
        if not np.any(positive):
            return None, None, 0

        similarities = (min_mass[positive] / max_mass[positive]).astype(np.float64, copy=False)
        weights = (total_a[valid][positive] + total_b[valid][positive]).astype(np.float64, copy=False)
        weighted_similarity = float(np.average(similarities, weights=weights)) if float(weights.sum()) > 0 else None
        return float(similarities.mean()), weighted_similarity, int(similarities.size)
