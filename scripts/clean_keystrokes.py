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

Usage:
    python clean_keystrokes.py <input.csv> [output.csv]

    If output path is omitted, writes <stem>_cleaned.csv next to the input.

Thresholds can be overridden at the top of this file.
"""

import sys
import csv
import os
import time
from pathlib import Path

# ── Configurable thresholds ──────────────────────────────────────────────
SPATIAL_MIN  = -0.5   # norm_x / norm_y lower bound (inclusive)
SPATIAL_MAX  =  1.5   # norm_x / norm_y upper bound (inclusive)
IKI_MIN_MS   =  50.0  # IKI below this → iki_low
IKI_MAX_MS   = 3000.0 # IKI above this → iki_high
DIST_MAX_KW  =  1.25  # far_from_target: max distance from expected key, in key-widths
# ──────────────────────────────────────────────────────────────────────────

# ── Keyboard layout (key-width units; row height = 1.35 key-widths) ──────
ROW_H = 1.35

def _make_rects():
    rects = {}
    def row(keys, x_start, r):
        for i, k in enumerate(keys):
            x = x_start + i
            rects[k] = (x, r * ROW_H, x + 1.0, (r + 1) * ROW_H)
    row(list("qwertyuiop"), 0.0, 0)
    row(list("asdfghjkl"),  0.5, 1)
    row(list("zxcvbnm"),    1.5, 2)
    rects["delete"] = (8.5, 2 * ROW_H, 10.0, 3 * ROW_H)
    rects["space"]  = (1.5, 3 * ROW_H,  8.5, 4 * ROW_H)
    return rects

KEY_RECTS = _make_rects()


def safe_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def expected_to_key(expected_raw: str) -> str | None:
    if expected_raw == " ":
        return "space"
    k = expected_raw.lower()
    return k if k in KEY_RECTS else None


def tap_absolute_position(row: dict) -> tuple[float, float] | None:
    key = row.get("key_label", "").strip().lower()
    rect = KEY_RECTS.get(key)
    if rect is None:
        return None
    kw_v = safe_float(row.get("key_width"))
    kh_v = safe_float(row.get("key_height"))
    if kw_v <= 0 or kh_v <= 0:
        return None
    nx = safe_float(row.get("tap_local_x")) / kw_v
    ny = safe_float(row.get("tap_local_y")) / kh_v
    x = rect[0] + nx * (rect[2] - rect[0])
    y = rect[1] + ny * (rect[3] - rect[1])
    return x, y


def distance_to_rect(x: float, y: float, rect: tuple) -> float:
    xmin, ymin, xmax, ymax = rect
    dx = max(xmin - x, 0.0, x - xmax)
    dy = max(ymin - y, 0.0, y - ymax)
    return (dx * dx + dy * dy) ** 0.5


def compute_flags(row: dict) -> list[str]:
    flags = []

    # ── tap_norm_x / tap_norm_y ──────────────────────────────────────────
    tap_x   = safe_float(row.get("tap_local_x"))
    tap_y   = safe_float(row.get("tap_local_y"))
    k_w     = safe_float(row.get("key_width"))
    k_h     = safe_float(row.get("key_height"))

    norm_x = (tap_x / k_w) if k_w > 0 else 0.5
    norm_y = (tap_y / k_h) if k_h > 0 else 0.5

    row["tap_norm_x"] = f"{norm_x:.4f}"
    row["tap_norm_y"] = f"{norm_y:.4f}"

    if not (SPATIAL_MIN <= norm_x <= SPATIAL_MAX) or \
       not (SPATIAL_MIN <= norm_y <= SPATIAL_MAX):
        flags.append("spatial")

    # ── IKI ──────────────────────────────────────────────────────────────
    iki = safe_float(row.get("inter_key_interval_ms"))
    if iki < IKI_MIN_MS and iki > 0:   # iki == 0 is handled by trial_start
        flags.append("iki_low")
    if iki > IKI_MAX_MS:
        flags.append("iki_high")

    # ── Trial start ───────────────────────────────────────────────────────
    if row.get("text_before", "").strip() == "":
        flags.append("trial_start")

    # ── Delete events ─────────────────────────────────────────────────────
    if row.get("event_type", "").strip().lower() == "delete":
        flags.append("delete_event")

    # ── Distance from expected key (key-width units) ─────────────────────
    expected_key = expected_to_key(row.get("expected_char", ""))
    exp_rect = KEY_RECTS.get(expected_key) if expected_key else None
    pos = tap_absolute_position(row) if exp_rect else None
    if exp_rect and pos:
        d = distance_to_rect(pos[0], pos[1], exp_rect)
        row["dist_from_target_kw"] = f"{d:.3f}"
        if d > DIST_MAX_KW:
            flags.append("far_from_target")
    else:
        row["dist_from_target_kw"] = ""

    return flags


def clean_file(input_path: str, output_path: str | None = None) -> str:
    in_path  = Path(input_path)
    out_path = Path(output_path) if output_path else \
               in_path.with_name(in_path.stem + "_cleaned.csv")

    with open(in_path, newline="", encoding="utf-8") as fh:
        reader   = csv.DictReader(fh)
        orig_fields = reader.fieldnames or []
        rows     = list(reader)

    new_fields = list(orig_fields) + ["tap_norm_x", "tap_norm_y",
                                       "dist_from_target_kw",
                                       "is_outlier", "outlier_flags"]

    total    = len(rows)
    flagged  = 0
    flag_counts: dict[str, int] = {}

    for row in rows:
        flags = compute_flags(row)          # also sets tap_norm_x/y in row
        row["is_outlier"]    = "1" if flags else "0"
        row["outlier_flags"] = "|".join(flags)
        if flags:
            flagged += 1
            for f in flags:
                flag_counts[f] = flag_counts.get(f, 0) + 1

    with open(out_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=new_fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    # ── Summary ──────────────────────────────────────────────────────────
    print(f"\nInput : {in_path}")
    print(f"Output: {out_path}")
    print(f"Rows  : {total} total  |  {flagged} flagged ({100*flagged/total:.1f}%)")
    print(f"        {total - flagged} clean")
    if flag_counts:
        print("\nFlag breakdown:")
        for flag, count in sorted(flag_counts.items(), key=lambda x: -x[1]):
            print(f"  {flag:<14} {count:>5}  ({100*count/total:.1f}%)")

    clean_non_delete = sum(
        1 for r in rows
        if r["is_outlier"] == "0" and r.get("event_type") != "delete"
    )
    print(f"\nUsable for tap distribution (is_outlier=0, not delete): {clean_non_delete}")
    print(f"Usable for IKI stats (is_outlier=0, not trial_start):    "
          f"{sum(1 for r in rows if r['is_outlier']=='0' and 'trial_start' not in r['outlier_flags'])}")

    return str(out_path)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    input_csv  = sys.argv[1]
    output_csv = sys.argv[2] if len(sys.argv) > 2 else None
    clean_file(input_csv, output_csv)


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
