#!/usr/bin/env python3
"""
Create session-to-session tap overlap visuals and Jaccard summaries.

This analysis is separate from ground-truth trial loss. It groups clean insert
taps by study session, then produces cumulative overlays:

    overlay 01: session 1
    overlay 02: session 1 + session 2
    overlay 03: session 1 + session 2 + session 3

For each added session, it compares the newest session against all previously
visible sessions with weighted Jaccard overlap.
"""

from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path


COLORS = [
    "#007AFF",  # blue
    "#FF2D55",  # pink
    "#34C759",  # green
    "#FF9500",  # orange
    "#AF52DE",  # purple
    "#FF3B30",  # red
    "#5AC8FA",  # cyan
    "#5856D6",  # indigo
]

ROW0 = list("qwertyuiop")
ROW1 = list("asdfghjkl")
ROW2 = list("zxcvbnm")

WIDTH = 980
KEY_GAP = 10
SIDE_PAD = 16
TOP_PAD = 28
ROW_GAP = 22
KEY_H = 76
BOTTOM_PAD = 22
HEIGHT = TOP_PAD + 4 * KEY_H + 3 * ROW_GAP + BOTTOM_PAD


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "csv_path",
        nargs="?",
        help="Cleaned keystroke CSV. Omit with --demo to generate synthetic data.",
    )
    parser.add_argument(
        "--output-dir",
        default="session_overlap_outputs",
        help="Directory for CSV summaries and SVG overlays.",
    )
    parser.add_argument(
        "--grid-size",
        type=int,
        default=30,
        help="Histogram bins per axis for weighted Jaccard.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate synthetic shifted sessions before rendering overlays.",
    )
    return parser.parse_args()


def safe_int(value: str | None, default: int = 0) -> int:
    try:
        return int(value) if value not in (None, "") else default
    except ValueError:
        return default


def safe_float(value: str | None, default: float = 0.0) -> float:
    try:
        return float(value) if value not in (None, "") else default
    except ValueError:
        return default


def clean_key(raw: str) -> str:
    if raw == " ":
        return "space"
    key = raw.strip().lower()
    return "space" if key == "space" else key


def tap_norm(row: dict) -> tuple[float, float]:
    if row.get("tap_norm_x") not in (None, "") and row.get("tap_norm_y") not in (None, ""):
        return safe_float(row.get("tap_norm_x"), 0.5), safe_float(row.get("tap_norm_y"), 0.5)

    width = safe_float(row.get("key_width"), 0)
    height = safe_float(row.get("key_height"), 0)
    x = safe_float(row.get("tap_local_x"), 0)
    y = safe_float(row.get("tap_local_y"), 0)
    return (x / width if width > 0 else 0.5), (y / height if height > 0 else 0.5)


def load_taps(csv_path: Path) -> dict[int, list[dict]]:
    sessions: dict[int, list[dict]] = defaultdict(list)
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("event_type") != "insert":
                continue
            if row.get("is_outlier", "0") not in ("", "0"):
                continue

            key = clean_key(row.get("key_label") or row.get("expected_char") or "")
            if key not in set(ROW0 + ROW1 + ROW2 + ["space", "delete"]):
                continue

            norm_x, norm_y = tap_norm(row)
            session_index = safe_int(row.get("study_session_index"), 1)
            if session_index >= 1:
                session_index -= 1

            sessions[session_index].append(
                {
                    "session": session_index,
                    "key": key,
                    "x": min(max(norm_x, 0.0), 1.0),
                    "y": min(max(norm_y, 0.0), 1.0),
                }
            )
    return dict(sorted(sessions.items()))


def histogram(taps: list[dict], grid_size: int) -> dict[tuple[int, int], int]:
    bins: dict[tuple[int, int], int] = defaultdict(int)
    for tap in taps:
        col = min(max(int(tap["x"] * grid_size), 0), grid_size - 1)
        row = min(max(int(tap["y"] * grid_size), 0), grid_size - 1)
        bins[(row, col)] += 1
    return dict(bins)


def weighted_jaccard(a: list[dict], b: list[dict], grid_size: int) -> float | None:
    hist_a = histogram(a, grid_size)
    hist_b = histogram(b, grid_size)
    total_a = sum(hist_a.values())
    total_b = sum(hist_b.values())
    if total_a == 0 or total_b == 0:
        return None

    numerator = 0.0
    denominator = 0.0
    for cell in set(hist_a) | set(hist_b):
        pa = hist_a.get(cell, 0) / total_a
        pb = hist_b.get(cell, 0) / total_b
        numerator += min(pa, pb)
        denominator += max(pa, pb)
    return numerator / denominator if denominator else None


def session_similarity(
    latest: list[dict],
    previous: list[dict],
    grid_size: int,
) -> tuple[float | None, list[dict]]:
    labels = sorted(set(t["key"] for t in latest) & set(t["key"] for t in previous))
    weighted: list[tuple[float, int]] = []
    by_key: list[dict] = []

    for key in labels:
        a = [tap for tap in latest if tap["key"] == key]
        b = [tap for tap in previous if tap["key"] == key]
        if len(a) < 3 or len(b) < 3:
            continue
        similarity = weighted_jaccard(a, b, grid_size)
        if similarity is None:
            continue
        weight = len(a) + len(b)
        weighted.append((similarity, weight))
        by_key.append(
            {
                "key": key,
                "similarity": f"{similarity:.6f}",
                "loss": f"{1.0 - similarity:.6f}",
                "latest_taps": len(a),
                "previous_taps": len(b),
            }
        )

    if not weighted:
        return None, by_key

    total_weight = sum(weight for _, weight in weighted)
    similarity = sum(value * weight for value, weight in weighted) / total_weight
    return similarity, by_key


def keyboard_frames() -> dict[str, tuple[float, float, float, float]]:
    key_w = (WIDTH - 2 * SIDE_PAD - 9 * KEY_GAP) / 10
    special_w = (WIDTH - 2 * SIDE_PAD - 7 * key_w - 8 * KEY_GAP) / 2
    frames: dict[str, tuple[float, float, float, float]] = {}

    y0 = TOP_PAD
    for index, key in enumerate(ROW0):
        frames[key] = (SIDE_PAD + index * (key_w + KEY_GAP), y0, key_w, KEY_H)

    y1 = y0 + KEY_H + ROW_GAP
    row1_start = (WIDTH - 9 * key_w - 8 * KEY_GAP) / 2
    for index, key in enumerate(ROW1):
        frames[key] = (row1_start + index * (key_w + KEY_GAP), y1, key_w, KEY_H)

    y2 = y1 + KEY_H + ROW_GAP
    row2_start = SIDE_PAD + special_w + KEY_GAP
    for index, key in enumerate(ROW2):
        frames[key] = (row2_start + index * (key_w + KEY_GAP), y2, key_w, KEY_H)

    frames["delete"] = (WIDTH - SIDE_PAD - special_w, y2, special_w, KEY_H)
    y3 = y2 + KEY_H + ROW_GAP
    frames["space"] = (
        SIDE_PAD + special_w + KEY_GAP,
        y3,
        WIDTH - 2 * SIDE_PAD - 2 * special_w - 2 * KEY_GAP,
        KEY_H,
    )
    return frames


def svg_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def write_overlay_svg(path: Path, sessions: dict[int, list[dict]], visible: list[int]) -> None:
    frames = keyboard_frames()
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT + 92}" viewBox="0 0 {WIDTH} {HEIGHT + 92}">',
        '<rect width="100%" height="100%" fill="#fbfbfd"/>',
        f'<text x="{SIDE_PAD}" y="24" font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700">Session overlap: {" + ".join(f"S{i + 1}" for i in visible)}</text>',
    ]

    for key, (x, y, w, h) in frames.items():
        lines.append(f'<rect x="{x:.2f}" y="{y + 34:.2f}" width="{w:.2f}" height="{h:.2f}" rx="8" fill="#eef0f4" stroke="#c7c7cc" stroke-width="1"/>')
        label = "space" if key == "space" else key
        lines.append(f'<text x="{x + 8:.2f}" y="{y + h + 21:.2f}" font-family="Menlo,monospace" font-size="12" fill="#60636b">{svg_escape(label)}</text>')

    for offset, session_index in enumerate(visible):
        color = COLORS[offset % len(COLORS)]
        radius = 8 + offset * 0.5
        for tap in sessions.get(session_index, []):
            frame = frames.get(tap["key"])
            if not frame:
                continue
            x, y, w, h = frame
            cx = x + tap["x"] * w
            cy = y + 34 + tap["y"] * h
            lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{radius + 2:.2f}" fill="#ffffff" fill-opacity="0.78"/>')
            lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{radius:.2f}" fill="{color}" fill-opacity="0.58" stroke="{color}" stroke-width="2"/>')

    legend_y = HEIGHT + 62
    legend_x = SIDE_PAD
    for offset, session_index in enumerate(visible):
        color = COLORS[offset % len(COLORS)]
        x = legend_x + offset * 120
        lines.append(f'<circle cx="{x}" cy="{legend_y}" r="8" fill="{color}"/>')
        lines.append(f'<text x="{x + 14}" y="{legend_y + 5}" font-family="Helvetica,Arial,sans-serif" font-size="14" font-weight="700" fill="#1c1c1e">S{session_index + 1}</text>')

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_outputs(sessions: dict[int, list[dict]], output_dir: Path, grid_size: int) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    session_ids = sorted(sessions)
    summary_rows: list[dict] = []
    by_key_rows: list[dict] = []

    for count in range(1, len(session_ids) + 1):
        visible = session_ids[:count]
        write_overlay_svg(output_dir / f"session_overlap_overlay_{count:02d}.svg", sessions, visible)

        if count == 1:
            summary_rows.append(
                {
                    "visible_sessions": "1",
                    "latest_session": "1",
                    "similarity": "",
                    "loss": "",
                    "latest_taps": len(sessions[visible[-1]]),
                    "previous_taps": 0,
                    "num_keys_compared": 0,
                }
            )
            continue

        latest_id = visible[-1]
        latest = sessions[latest_id]
        previous = [tap for session_id in visible[:-1] for tap in sessions[session_id]]
        similarity, by_key = session_similarity(latest, previous, grid_size)
        summary_rows.append(
            {
                "visible_sessions": ",".join(str(i + 1) for i in visible),
                "latest_session": latest_id + 1,
                "similarity": "" if similarity is None else f"{similarity:.6f}",
                "loss": "" if similarity is None else f"{1.0 - similarity:.6f}",
                "latest_taps": len(latest),
                "previous_taps": len(previous),
                "num_keys_compared": len(by_key),
            }
        )
        for row in by_key:
            by_key_rows.append(
                {
                    "visible_sessions": ",".join(str(i + 1) for i in visible),
                    "latest_session": latest_id + 1,
                    **row,
                }
            )

    with (output_dir / "session_overlap_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        fieldnames = [
            "visible_sessions",
            "latest_session",
            "similarity",
            "loss",
            "latest_taps",
            "previous_taps",
            "num_keys_compared",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(summary_rows)

    with (output_dir / "session_overlap_by_key.csv").open("w", newline="", encoding="utf-8") as handle:
        fieldnames = [
            "visible_sessions",
            "latest_session",
            "key",
            "similarity",
            "loss",
            "latest_taps",
            "previous_taps",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(by_key_rows)


def demo_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    keys = ["q", "w", "e", "a", "s", "d", "z", "x", "c", "space"]
    centers = {
        "q": (0.40, 0.45),
        "w": (0.52, 0.40),
        "e": (0.60, 0.48),
        "a": (0.42, 0.50),
        "s": (0.54, 0.52),
        "d": (0.62, 0.47),
        "z": (0.45, 0.54),
        "x": (0.56, 0.58),
        "c": (0.65, 0.53),
        "space": (0.48, 0.50),
    }
    shifts = [(-0.11, -0.04), (-0.03, 0.00), (0.05, 0.04), (0.11, 0.07)]

    timestamp = 0
    for session_index, (shift_x, shift_y) in enumerate(shifts, start=1):
        for key in keys:
            base_x, base_y = centers[key]
            for tap_index in range(18):
                angle = tap_index * 1.7 + session_index * 0.4
                radius = 0.045 + 0.006 * (tap_index % 3)
                x = base_x + shift_x + math.cos(angle) * radius
                y = base_y + shift_y + math.sin(angle) * radius * 0.72
                rows.append(
                    {
                        "session_mode": "classic",
                        "event_type": "insert",
                        "is_outlier": "0",
                        "study_session_index": str(session_index),
                        "trial_index": str(tap_index // 6),
                        "trial_id": f"s{session_index}-trial-{tap_index // 6}",
                        "timestamp_ms": str(timestamp),
                        "expected_char": " " if key == "space" else key,
                        "key_label": key,
                        "tap_norm_x": f"{min(max(x, 0.05), 0.95):.6f}",
                        "tap_norm_y": f"{min(max(y, 0.05), 0.95):.6f}",
                    }
                )
                timestamp += 10
    return rows


def write_demo_csv(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = demo_rows()
    with path.open("w", newline="", encoding="utf-8") as handle:
        fieldnames = list(rows[0].keys())
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()

    if args.demo:
        csv_path = output_dir / "synthetic_session_overlap_input.csv"
        write_demo_csv(csv_path)
    elif args.csv_path:
        csv_path = Path(args.csv_path).resolve()
    else:
        raise SystemExit("Provide a CSV path or use --demo.")

    sessions = load_taps(csv_path)
    if not sessions:
        raise SystemExit(f"No usable taps found in {csv_path}")

    write_outputs(sessions, output_dir, args.grid_size)
    print(f"Input CSV: {csv_path}")
    print(f"Output dir: {output_dir}")
    print(f"Sessions: {', '.join(str(index + 1) for index in sessions)}")


if __name__ == "__main__":
    main()
