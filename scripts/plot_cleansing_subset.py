#!/usr/bin/env python3
"""
Render a side-by-side raw vs cleaned tap comparison for selected sessions.

Usage:
    python3 scripts/plot_cleansing_subset.py <raw.csv> <cleaned.csv> [output.pdf] [--sessions 1 2 3 4 5]
    python3 scripts/plot_cleansing_subset.py <raw.csv> <cleaned.csv> [output.pdf] --session-start 1 --session-end 7

The output uses a single page with two keyboards:
    - left: all raw taps from the selected sessions
    - right: cleaned taps that remain after the tap-distribution filter

Both panels use the final-Gaussian keyboard frame style and the tap-dot style
from the tap distribution report.
"""

from __future__ import annotations

import argparse
import csv
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle

import gaussian_keyboard_pdf as gkp


PAGE_W = 792.0
PAGE_H = 612.0
MARGIN_X = 28.0
TOP_MARGIN = 34.0
BOTTOM_MARGIN = 26.0
PANEL_GAP = 24.0
HEADER_RULE_Y = 72.0
DOT_R = 4.5
PANEL_DOT_PADDING = 18.0

MATCH_FIELDS = [
    "session_id",
    "study_session_index",
    "trial_id",
    "trial_index",
    "event_type",
    "key_label",
    "expected_char",
    "actual_char",
    "corrected_char",
    "tap_local_x",
    "tap_local_y",
    "timestamp_ms",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_csv", help="Path to the raw CSV")
    parser.add_argument("cleaned_csv", help="Path to the cleaned CSV")
    parser.add_argument("output", nargs="?", help="Output file path (.pdf or .png)")
    parser.add_argument(
        "--sessions",
        nargs="+",
        help="Explicit study session indexes to include, like --sessions 1 2 3 4 5",
    )
    parser.add_argument(
        "--session-start",
        type=int,
        help="Starting study session index for an inclusive range",
    )
    parser.add_argument(
        "--session-end",
        type=int,
        help="Ending study session index for an inclusive range",
    )
    return parser.parse_args()


def safe_float(value: str | None, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def participant_name(rows: list[dict[str, str]]) -> str:
    if not rows:
        return ""
    first = (rows[0].get("participant_first") or "").strip()
    last = (rows[0].get("participant_last") or "").strip()
    return f"{first} {last}".strip()


def row_identity(row: dict[str, str]) -> tuple[str, ...]:
    return tuple((row.get(field) or "").strip() for field in MATCH_FIELDS)


def session_value(row: dict[str, str]) -> str:
    return (row.get("study_session_index") or "").strip()


def is_displayable(row: dict[str, str]) -> bool:
    key_label = (row.get("key_label") or "").strip()
    if key_label not in gkp.VALID_KEYS:
        return False
    return safe_float(row.get("key_width")) > 0 and safe_float(row.get("key_height")) > 0


def keep_for_clean_plot(row: dict[str, str]) -> bool:
    if not is_displayable(row):
        return False
    flags = (row.get("outlier_flags") or "").lower()
    return "spatial" not in flags and "far_from_target" not in flags


def key_color(key: str) -> tuple[float, float, float]:
    idx = gkp.ALL_KEYS.index(key) if key in gkp.ALL_KEYS else 0
    hue = (idx * 0.618033988749895) % 1.0
    sat = 0.82 if idx % 2 == 0 else 0.65
    return tuple(matplotlib.colors.hsv_to_rgb([hue, sat, 0.88]))


def expected_to_color_key(raw: str, fallback: str) -> str:
    if raw == " ":
        return "space"
    key = raw.strip().lower()
    return key if key in gkp.ALL_KEYS else fallback


def selected_raw_rows(rows: list[dict[str, str]], sessions: set[str]) -> list[dict[str, str]]:
    return [row for row in rows if session_value(row) in sessions and is_displayable(row)]


def selected_clean_rows(rows: list[dict[str, str]], sessions: set[str]) -> list[dict[str, str]]:
    return [row for row in rows if session_value(row) in sessions and keep_for_clean_plot(row)]


def raw_removed_count(raw_rows: list[dict[str, str]], kept_clean_rows: list[dict[str, str]]) -> int:
    remaining = Counter(row_identity(row) for row in kept_clean_rows)
    kept = 0
    for row in raw_rows:
        ident = row_identity(row)
        if remaining[ident] > 0:
            kept += 1
            remaining[ident] -= 1
    return max(0, len(raw_rows) - kept)


def scale_panel_and_frames(
    panel_rect: gkp.Rect,
    frames: dict[str, gkp.Rect],
    scale: float,
    left: float,
    top: float,
) -> tuple[gkp.Rect, dict[str, gkp.Rect]]:
    scaled_panel = gkp.Rect(left, top, panel_rect.w * scale, panel_rect.h * scale)
    scaled_frames = gkp.scale_frames(frames, scale)
    shifted_frames = gkp.offset_frames(scaled_frames, left, top)
    return scaled_panel, shifted_frames


def draw_panel(ax: plt.Axes, panel_rect: gkp.Rect, frames: dict[str, gkp.Rect], scale: float) -> None:
    radius = gkp.PANEL_RADIUS * scale
    shadow = FancyBboxPatch(
        (panel_rect.x, panel_rect.y + 6.0 * scale),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={radius}",
        facecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.08),
        edgecolor="none",
        zorder=0.5,
    )
    panel = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={radius}",
        facecolor="#F8FAFC",
        edgecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.18),
        linewidth=1.2,
        zorder=1.0,
    )
    outline = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={radius}",
        facecolor="none",
        edgecolor="#111827",
        linewidth=2.0,
        zorder=4.5,
    )
    ax.add_patch(shadow)
    ax.add_patch(panel)
    gkp.draw_keyboard_pdf(ax, frames)
    ax.add_patch(outline)


def absolute_tap_position(row: dict[str, str], frames: dict[str, gkp.Rect]) -> tuple[float, float] | tuple[None, None]:
    key_label = (row.get("key_label") or "").strip()
    frame = frames.get(key_label)
    if frame is None:
        return None, None
    key_width = safe_float(row.get("key_width"))
    key_height = safe_float(row.get("key_height"))
    if key_width <= 0 or key_height <= 0:
        return None, None
    px = frame.x + (safe_float(row.get("tap_local_x")) / key_width) * frame.w
    py = frame.y + (safe_float(row.get("tap_local_y")) / key_height) * frame.h
    return px, py


def draw_taps(ax: plt.Axes, rows: list[dict[str, str]], frames: dict[str, gkp.Rect]) -> None:
    if not rows:
        return

    dot_x: list[float] = []
    dot_y: list[float] = []
    dot_colors: list[tuple[float, float, float]] = []
    labels: list[tuple[float, float, str]] = []
    for row in rows:
        px, py = absolute_tap_position(row, frames)
        if px is None:
            continue
        color_key = expected_to_color_key((row.get("expected_char") or ""), (row.get("key_label") or ""))
        dot_x.append(px)
        dot_y.append(py)
        dot_colors.append(key_color(color_key))
        if len(color_key) == 1:
            labels.append((px, py, color_key))

    if not dot_x:
        return

    halo_size = (DOT_R + 1.0) ** 2 * 4.0
    dot_size = DOT_R ** 2 * 4.0
    ax.scatter(dot_x, dot_y, s=halo_size, c=[(1.0, 1.0, 1.0, 0.8)], edgecolors="none", zorder=5)
    ax.scatter(dot_x, dot_y, s=dot_size, c=[(*rgb, 0.95) for rgb in dot_colors], edgecolors="none", zorder=6)
    for px, py, label in labels:
        ax.text(
            px,
            py,
            label,
            fontsize=DOT_R * 1.1,
            color="white",
            fontweight="bold",
            family="monospace",
            ha="center",
            va="center",
            zorder=7,
        )


def sessions_label(sessions: list[str]) -> str:
    if not sessions:
        return ""
    if len(sessions) >= 2 and sessions == [str(value) for value in range(int(sessions[0]), int(sessions[-1]) + 1)]:
        return f"{sessions[0]}-{sessions[-1]}"
    return ", ".join(sessions)


def resolve_sessions(args: argparse.Namespace) -> list[str]:
    if args.sessions:
        return [str(value) for value in args.sessions]

    if args.session_start is None and args.session_end is None:
        return ["1", "2", "3", "4", "5"]

    if args.session_start is None or args.session_end is None:
        raise SystemExit("Pass both --session-start and --session-end for a range.")

    if args.session_end < args.session_start:
        raise SystemExit("--session-end must be greater than or equal to --session-start.")

    return [str(value) for value in range(args.session_start, args.session_end + 1)]


def render_side_by_side(
    raw_rows: list[dict[str, str]],
    cleaned_rows: list[dict[str, str]],
    participant: str,
    sessions: list[str],
    out_path: Path,
) -> None:
    session_set = set(sessions)
    raw_selected = selected_raw_rows(raw_rows, session_set)
    cleaned_selected = selected_clean_rows(cleaned_rows, session_set)
    removed_count = raw_removed_count(raw_selected, cleaned_selected)

    local_panel_rect, local_frames = gkp.build_svg_panel_and_frames()
    local_panel_rect = gkp.Rect(
        0.0,
        0.0,
        local_panel_rect.w + 2.0 * PANEL_DOT_PADDING,
        local_panel_rect.h + 2.0 * PANEL_DOT_PADDING,
    )
    local_frames = gkp.offset_frames(local_frames, PANEL_DOT_PADDING, PANEL_DOT_PADDING)
    available_width = PAGE_W - 2.0 * MARGIN_X - PANEL_GAP
    panel_scale = min(
        available_width / (2.0 * local_panel_rect.w),
        (PAGE_H - TOP_MARGIN - BOTTOM_MARGIN - 94.0) / local_panel_rect.h,
    )
    panel_width = local_panel_rect.w * panel_scale
    panel_height = local_panel_rect.h * panel_scale
    left_x = (PAGE_W - (2.0 * panel_width + PANEL_GAP)) / 2.0
    top_y = 112.0
    left_panel, left_frames = scale_panel_and_frames(local_panel_rect, local_frames, panel_scale, left_x, top_y)
    right_panel, right_frames = scale_panel_and_frames(local_panel_rect, local_frames, panel_scale, left_x + panel_width + PANEL_GAP, top_y)

    fig = plt.figure(figsize=(PAGE_W / 72.0, PAGE_H / 72.0), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, PAGE_W)
    ax.set_ylim(PAGE_H, 0)
    ax.set_aspect("equal")
    ax.axis("off")

    ax.add_patch(Rectangle((0, 0), PAGE_W, PAGE_H, facecolor="white", edgecolor="none", zorder=0))
    ax.text(
        PAGE_W / 2.0,
        28.0,
        "Data Cleansing Check - Sessions " + sessions_label(sessions),
        fontsize=18,
        fontweight="bold",
        color="#0F172A",
        ha="center",
        va="center",
    )
    if participant:
        ax.text(
            MARGIN_X,
            54.0,
            f"Participant: {participant}",
            fontsize=9,
            color="#475569",
            ha="left",
            va="center",
        )
    ax.text(
        PAGE_W - MARGIN_X,
        54.0,
        datetime.now().strftime("%Y-%m-%d"),
        fontsize=9,
        family="monospace",
        color="#475569",
        ha="right",
        va="center",
    )
    ax.plot([MARGIN_X, PAGE_W - MARGIN_X], [HEADER_RULE_Y, HEADER_RULE_Y], color="#CBD5E1", linewidth=1.0, zorder=0.8)

    draw_panel(ax, left_panel, left_frames, panel_scale)
    draw_panel(ax, right_panel, right_frames, panel_scale)
    draw_taps(ax, raw_selected, left_frames)
    draw_taps(ax, cleaned_selected, right_frames)

    raw_title_y = left_panel.y - 16.0
    clean_title_y = right_panel.y - 16.0
    ax.text(
        left_panel.mid_x,
        raw_title_y,
        f"Raw combined sessions {sessions_label(sessions)}",
        fontsize=11,
        fontweight="bold",
        color="#0F172A",
        ha="center",
        va="bottom",
    )
    ax.text(
        left_panel.mid_x,
        raw_title_y + 14.0,
        f"{len(raw_selected)} taps shown, about {removed_count} removed by cleaning",
        fontsize=8.5,
        color="#64748B",
        ha="center",
        va="bottom",
    )
    ax.text(
        right_panel.mid_x,
        clean_title_y,
        f"Cleaned combined sessions {sessions_label(sessions)}",
        fontsize=11,
        fontweight="bold",
        color="#0F172A",
        ha="center",
        va="bottom",
    )
    ax.text(
        right_panel.mid_x,
        clean_title_y + 14.0,
        f"{len(cleaned_selected)} taps kept after spatial/far-from-target filtering",
        fontsize=8.5,
        color="#64748B",
        ha="center",
        va="bottom",
    )

    ax.text(
        PAGE_W / 2.0,
        PAGE_H - 14.0,
        "Dots use the tap-distribution style; cleaned view follows the tap report filter.",
        fontsize=8.5,
        color="#475569",
        ha="center",
        va="center",
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def main() -> None:
    args = parse_args()
    raw_csv = Path(args.raw_csv).expanduser()
    cleaned_csv = Path(args.cleaned_csv).expanduser()
    sessions = resolve_sessions(args)
    if args.output:
        out_path = Path(args.output).expanduser()
    else:
        out_path = raw_csv.with_name(f"{raw_csv.stem}_cleansing_check_s{sessions_label(sessions).replace(', ', '_')}_side_by_side.pdf")

    raw_rows = load_rows(raw_csv)
    cleaned_rows = load_rows(cleaned_csv)
    participant = participant_name(cleaned_rows) or participant_name(raw_rows)
    render_side_by_side(raw_rows, cleaned_rows, participant, sessions, out_path)

    print(f"Raw CSV: {raw_csv}")
    print(f"Cleaned CSV: {cleaned_csv}")
    print(f"Sessions: {', '.join(sessions)}")
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
