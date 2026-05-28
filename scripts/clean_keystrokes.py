#!/usr/bin/env python3
"""
clean_keystrokes.py
-------------------
Flags outliers in raw keystroke CSVs exported from the TypingResearch iOS app.

Does NOT delete rows — adds columns so downstream analyses can filter with
different thresholds without re-running the pipeline:

    tap_norm_x           float  tapLocalX / keyWidth  (0 = left, 1 = right)
    tap_norm_y           float  tapLocalY / keyHeight (0 = top,  1 = bottom)
    dist_from_target_kw  float  distance from tap to expected key rect,
                                  measured in key-widths (0 if tap is inside
                                  the expected key's rectangle)
    is_outlier           int    1 if any flag fired, else 0
    outlier_flags        str    pipe-separated reasons (empty = clean)

Outlier criteria:
    spatial          tap_norm_x / tap_norm_y outside [-0.5, 1.5]
                       → tap is >½ key-width outside the HIT key's boundary.
                       Threshold from Azenkot & Zhai (2012).
    far_from_target  dist_from_target_kw > 1.25
                       → tap landed more than 1.25 key-widths from the
                       EXPECTED key — too far to count as a legitimate
                       neighbor mistap.
    iki_low          inter_key_interval_ms < 50  → double-registration
    iki_high         inter_key_interval_ms > 3000 → pause / distraction
    trial_start      text_before == ""  → first keystroke of a trial
    delete_event     event_type == "delete"  → intentional backspace
    sigma_outlier    tap is > N std devs from its expected key's cluster mean
                       (second pass, only applied when --sigma is set).
                       Use this to remove stray isolated dots for Gaussian truth.

Usage:
    python clean_keystrokes.py <input.csv> [output.csv] [-t KW] [-s SD]

    -t / --threshold FLOAT
        far_from_target cutoff in key-widths (default 1.25).
        Example: -t 1.0  →  keystrokes_Tran__cleaned_t1.0.csv

    -s / --sigma FLOAT
        Per-key cluster filter: flag taps more than N std devs from their
        expected key's mean tap position (computed from geometrically clean
        taps only). Good starting values: 2.5 (tight) to 3.0 (loose).
        Example: -s 2.5  →  keystrokes_Tran__cleaned_s2.5.csv
"""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np


SPATIAL_MIN = -0.5
SPATIAL_MAX = 1.5
IKI_MIN_MS = 50.0
IKI_MAX_MS = 3000.0
DIST_MAX_KW = 1.25
SIGMA_THRESHOLD: float | None = None

ROW_H = 1.35


def _make_rects() -> dict[str, tuple[float, float, float, float]]:
    rects: dict[str, tuple[float, float, float, float]] = {}

    def row(keys: list[str], x_start: float, row_index: int) -> None:
        for key_index, key in enumerate(keys):
            x = x_start + key_index
            rects[key] = (x, row_index * ROW_H, x + 1.0, (row_index + 1) * ROW_H)

    row(list("qwertyuiop"), 0.0, 0)
    row(list("asdfghjkl"), 0.5, 1)
    row(list("zxcvbnm"), 1.5, 2)
    rects["delete"] = (8.5, 2 * ROW_H, 10.0, 3 * ROW_H)
    rects["space"] = (1.5, 3 * ROW_H, 8.5, 4 * ROW_H)
    return rects


KEY_RECTS = _make_rects()
KEY_ORDER = list(KEY_RECTS)
KEY_TO_INDEX = {key: index for index, key in enumerate(KEY_ORDER)}
RECT_ARRAY = np.array([KEY_RECTS[key] for key in KEY_ORDER], dtype=np.float64)


def safe_float(val: str | None, default: float = 0.0) -> float:
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def expected_to_key(expected_raw: str) -> str | None:
    if expected_raw == " ":
        return "space"
    key = expected_raw.lower()
    return key if key in KEY_RECTS else None


def compute_output_columns(rows: list[dict]) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[list[str]]]:
    row_count = len(rows)
    tap_x = np.fromiter((safe_float(row.get("tap_local_x")) for row in rows), dtype=np.float64, count=row_count)
    tap_y = np.fromiter((safe_float(row.get("tap_local_y")) for row in rows), dtype=np.float64, count=row_count)
    key_w = np.fromiter((safe_float(row.get("key_width")) for row in rows), dtype=np.float64, count=row_count)
    key_h = np.fromiter((safe_float(row.get("key_height")) for row in rows), dtype=np.float64, count=row_count)
    iki = np.fromiter((safe_float(row.get("inter_key_interval_ms")) for row in rows), dtype=np.float64, count=row_count)

    norm_x = np.divide(tap_x, key_w, out=np.full(row_count, 0.5, dtype=np.float64), where=key_w > 0)
    norm_y = np.divide(tap_y, key_h, out=np.full(row_count, 0.5, dtype=np.float64), where=key_h > 0)

    key_indices = np.fromiter(
        (KEY_TO_INDEX.get((row.get("key_label") or "").strip().lower(), -1) for row in rows),
        dtype=np.int32,
        count=row_count,
    )
    expected_indices = np.fromiter(
        (KEY_TO_INDEX.get(expected_to_key(row.get("expected_char", "")) or "", -1) for row in rows),
        dtype=np.int32,
        count=row_count,
    )

    hit_valid = (key_indices >= 0) & (key_w > 0) & (key_h > 0)
    expected_valid = expected_indices >= 0
    safe_hit_indices = np.clip(key_indices, 0, len(KEY_ORDER) - 1)
    safe_expected_indices = np.clip(expected_indices, 0, len(KEY_ORDER) - 1)

    hit_rects = RECT_ARRAY[safe_hit_indices]
    expected_rects = RECT_ARRAY[safe_expected_indices]

    abs_x = hit_rects[:, 0] + norm_x * (hit_rects[:, 2] - hit_rects[:, 0])
    abs_y = hit_rects[:, 1] + norm_y * (hit_rects[:, 3] - hit_rects[:, 1])

    dx = np.maximum.reduce(
        [
            expected_rects[:, 0] - abs_x,
            np.zeros(row_count, dtype=np.float64),
            abs_x - expected_rects[:, 2],
        ]
    )
    dy = np.maximum.reduce(
        [
            expected_rects[:, 1] - abs_y,
            np.zeros(row_count, dtype=np.float64),
            abs_y - expected_rects[:, 3],
        ]
    )
    distance = np.sqrt(dx * dx + dy * dy)
    distance_valid = hit_valid & expected_valid
    distance = np.where(distance_valid, distance, np.nan)

    spatial = (norm_x < SPATIAL_MIN) | (norm_x > SPATIAL_MAX) | (norm_y < SPATIAL_MIN) | (norm_y > SPATIAL_MAX)
    iki_low = (iki < IKI_MIN_MS) & (iki > 0)
    iki_high = iki > IKI_MAX_MS
    trial_start = np.fromiter((not (row.get("text_before") or "").strip() for row in rows), dtype=bool, count=row_count)
    delete_event = np.fromiter(
        ((row.get("event_type") or "").strip().lower() == "delete" for row in rows),
        dtype=bool,
        count=row_count,
    )
    far_from_target = distance_valid & (distance > DIST_MAX_KW)

    flags_per_row: list[list[str]] = [[] for _ in rows]
    for flag_name, mask in (
        ("spatial", spatial),
        ("iki_low", iki_low),
        ("iki_high", iki_high),
        ("trial_start", trial_start),
        ("delete_event", delete_event),
        ("far_from_target", far_from_target),
    ):
        for index in np.flatnonzero(mask):
            flags_per_row[int(index)].append(flag_name)

    if SIGMA_THRESHOLD is not None:
        geometric_outlier = np.array([len(f) > 0 for f in flags_per_row], dtype=bool)
        valid_for_stats = hit_valid & expected_valid & ~geometric_outlier

        # Per-expected-key mean/std from geometrically clean taps
        key_stats: dict[int, tuple[float, float, float, float]] = {}
        for key_idx in range(len(KEY_ORDER)):
            mask = valid_for_stats & (expected_indices == key_idx)
            if mask.sum() < 5:
                continue
            xs, ys = abs_x[mask], abs_y[mask]
            sx, sy = float(xs.std()), float(ys.std())
            if sx < 1e-6 or sy < 1e-6:
                continue
            key_stats[key_idx] = (float(xs.mean()), float(ys.mean()), sx, sy)

        # Vectorised: flag taps > SIGMA_THRESHOLD std devs from their key's mean
        sigma_outlier = np.zeros(row_count, dtype=bool)
        valid_for_sigma = hit_valid & expected_valid
        for key_idx, (mu_x, mu_y, s_x, s_y) in key_stats.items():
            key_mask = valid_for_sigma & (expected_indices == key_idx)
            if not key_mask.any():
                continue
            z = np.sqrt(((abs_x[key_mask] - mu_x) / s_x) ** 2 +
                        ((abs_y[key_mask] - mu_y) / s_y) ** 2)
            hits = np.where(key_mask)[0]
            sigma_outlier[hits[z > SIGMA_THRESHOLD]] = True

        for index in np.flatnonzero(sigma_outlier):
            flags_per_row[int(index)].append("sigma_outlier")

    return norm_x, norm_y, distance, flags_per_row


def clean_file(input_path: str, output_path: str | None = None) -> str:
    in_path = Path(input_path)
    out_path = Path(output_path) if output_path else in_path.with_name(in_path.stem + "_cleaned.csv")

    with in_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        original_fields = reader.fieldnames or []
        rows = list(reader)

    SPATIAL_FLAGS = {"spatial", "far_from_target", "sigma_outlier"}

    new_fields = list(original_fields) + [
        "tap_norm_x",
        "tap_norm_y",
        "dist_from_target_kw",
        "is_outlier",
        "is_spatial_outlier",
        "outlier_flags",
    ]

    norm_x, norm_y, distance, flags_per_row = compute_output_columns(rows)

    flagged = 0
    flag_counts: dict[str, int] = {}
    for index, row in enumerate(rows):
        flags = flags_per_row[index]
        flag_set = set(flags)
        row["tap_norm_x"] = f"{norm_x[index]:.4f}"
        row["tap_norm_y"] = f"{norm_y[index]:.4f}"
        row["dist_from_target_kw"] = "" if np.isnan(distance[index]) else f"{distance[index]:.3f}"
        row["is_outlier"] = "1" if flags else "0"
        row["is_spatial_outlier"] = "1" if flag_set & SPATIAL_FLAGS else "0"
        row["outlier_flags"] = "|".join(flags)
        if flags:
            flagged += 1
            for flag in flags:
                flag_counts[flag] = flag_counts.get(flag, 0) + 1

    with out_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=new_fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    total = len(rows)
    print(f"\nInput : {in_path}")
    print(f"Output: {out_path}")
    print(f"Rows  : {total} total  |  {flagged} flagged ({100 * flagged / total:.1f}%)")
    print(f"        {total - flagged} clean")
    if flag_counts:
        print("\nFlag breakdown:")
        for flag, count in sorted(flag_counts.items(), key=lambda item: -item[1]):
            print(f"  {flag:<14} {count:>5}  ({100 * count / total:.1f}%)")

    clean_non_delete = sum(
        1 for row in rows
        if row["is_outlier"] == "0" and row.get("event_type") != "delete"
    )
    print(f"\nUsable for tap distribution (is_outlier=0, not delete): {clean_non_delete}")
    print(
        "Usable for IKI stats (is_outlier=0, not trial_start):    "
        f"{sum(1 for row in rows if row['is_outlier'] == '0' and 'trial_start' not in row['outlier_flags'])}"
    )

    return str(out_path)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Flag outliers in raw keystroke CSVs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", help="Raw keystroke CSV")
    parser.add_argument("output", nargs="?", help="Output CSV (optional)")
    parser.add_argument(
        "-t", "--threshold",
        type=float,
        default=1.25,
        metavar="KW",
        help="far_from_target cutoff in key-widths (default 1.25)",
    )
    parser.add_argument(
        "-s", "--sigma",
        type=float,
        default=None,
        metavar="SD",
        help="per-key cluster filter: flag taps > N std devs from expected key mean (e.g. 2.5)",
    )
    args = parser.parse_args()

    global DIST_MAX_KW, SIGMA_THRESHOLD
    DIST_MAX_KW = args.threshold
    SIGMA_THRESHOLD = args.sigma

    output_csv = args.output
    if output_csv is None:
        stem = Path(args.input).stem
        t_suffix = f"_t{args.threshold}" if args.threshold != 1.25 else ""
        s_suffix = f"_s{args.sigma}" if args.sigma is not None else ""
        if t_suffix or s_suffix:
            output_csv = str(Path(args.input).with_name(f"{stem}_cleaned{t_suffix}{s_suffix}.csv"))

    clean_file(args.input, output_csv)


if __name__ == "__main__":
    main()
