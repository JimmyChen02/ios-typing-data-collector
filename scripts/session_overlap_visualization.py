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
import colorsys
import csv
import math
from collections import defaultdict
from pathlib import Path


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
KEYBOARD_Y = 54
LEGEND_COLUMNS = 7
LEGEND_ITEM_W = 128
LEGEND_ROW_H = 34
TERRITORY_STEP = 6
MIN_GAUSSIAN_VARIANCE = 36.0
ALL_KEYS = ROW0 + ROW1 + ROW2 + ["space", "delete"]


def key_color(key: str) -> str:
    semantic = {
        "q": "#D7263D", "w": "#F46036", "e": "#F9A03F", "r": "#EFD63F", "t": "#8AC926",
        "y": "#2EC4B6", "u": "#1B9AAA", "i": "#3A86FF", "o": "#5E60CE", "p": "#9D4EDD",
        "a": "#C1121F", "s": "#E85D04", "d": "#EE9B00", "f": "#70E000", "g": "#38B000",
        "h": "#00B4D8", "j": "#0077B6", "k": "#4361EE", "l": "#7209B7",
        "z": "#FF006E", "x": "#FB5607", "c": "#FFBE0B", "v": "#80B918", "b": "#06D6A0",
        "n": "#118AB2", "m": "#8338EC", "space": "#6C757D", "delete": "#212529",
    }
    if key in semantic:
        return semantic[key]

    try:
        index = ALL_KEYS.index(key)
    except ValueError:
        index = 0
    hue = (index * 0.618033988749895) % 1.0
    red, green, blue = colorsys.hsv_to_rgb(hue, 0.68, 0.90)
    return f"#{int(red * 255):02X}{int(green * 255):02X}{int(blue * 255):02X}"


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
        "--territory-step",
        type=int,
        default=TERRITORY_STEP,
        help="Pixel step used to sample Gaussian territories; lower is smoother but larger.",
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


def canvas_point(tap: dict, frames: dict[str, tuple[float, float, float, float]]) -> tuple[float, float] | None:
    frame = frames.get(tap["key"])
    if not frame:
        return None
    x, y, w, h = frame
    return x + tap["x"] * w, KEYBOARD_Y + y + tap["y"] * h


def gaussian_parameters(points: list[tuple[float, float]]) -> dict | None:
    if len(points) < 5:
        return None

    mean_x = sum(point[0] for point in points) / len(points)
    mean_y = sum(point[1] for point in points) / len(points)

    centered = [(point[0] - mean_x, point[1] - mean_y) for point in points]
    var_x = sum(x * x for x, _ in centered) / max(len(centered) - 1, 1)
    var_y = sum(y * y for _, y in centered) / max(len(centered) - 1, 1)
    cov_xy = sum(x * y for x, y in centered) / max(len(centered) - 1, 1)
    var_x = max(var_x, MIN_GAUSSIAN_VARIANCE)
    var_y = max(var_y, MIN_GAUSSIAN_VARIANCE)

    trace = var_x + var_y
    determinant = var_x * var_y - cov_xy * cov_xy
    discriminant = max((trace * trace) / 4.0 - determinant, 0.0)
    root = math.sqrt(discriminant)
    lambda_1 = max(trace / 2.0 + root, 0.0)
    lambda_2 = max(trace / 2.0 - root, 0.0)

    if lambda_1 <= 0 and lambda_2 <= 0:
        return None

    angle = 0.5 * math.atan2(2.0 * cov_xy, var_x - var_y) if abs(cov_xy) > 1e-9 else 0.0
    # Two standard deviations gives a readable "learned boundary" contour
    # without letting a handful of taps dominate the full key.
    radius_x = max(10.0, 2.0 * math.sqrt(lambda_1))
    radius_y = max(7.0, 2.0 * math.sqrt(lambda_2))
    return {
        "mean_x": mean_x,
        "mean_y": mean_y,
        "var_x": var_x,
        "var_y": var_y,
        "cov_xy": cov_xy,
        "radius_x": radius_x,
        "radius_y": radius_y,
        "angle": math.degrees(angle),
    }


def gaussian_ellipse(points: list[tuple[float, float]]) -> tuple[float, float, float, float, float] | None:
    params = gaussian_parameters(points)
    if params is None:
        return None
    return (
        params["mean_x"],
        params["mean_y"],
        params["radius_x"],
        params["radius_y"],
        params["angle"],
    )


def grouped_session_boundaries(
    taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
) -> list[tuple[str, tuple[float, float, float, float, float]]]:
    by_key: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for tap in taps:
        point = canvas_point(tap, frames)
        if point is not None:
            by_key[tap["key"]].append(point)

    boundaries: list[tuple[str, tuple[float, float, float, float, float]]] = []
    for key, points in sorted(by_key.items()):
        ellipse = gaussian_ellipse(points)
        if ellipse is not None:
            boundaries.append((key, ellipse))
    return boundaries


def grouped_session_gaussians(
    taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
) -> list[dict]:
    by_key: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for tap in taps:
        point = canvas_point(tap, frames)
        if point is not None:
            by_key[tap["key"]].append(point)

    models: list[dict] = []
    for key, points in sorted(by_key.items()):
        params = gaussian_parameters(points)
        if params is not None:
            models.append({"key": key, "count": len(points), **params})
    return models


def gaussian_score(model: dict, x: float, y: float) -> float:
    dx = x - model["mean_x"]
    dy = y - model["mean_y"]
    var_x = model["var_x"]
    var_y = model["var_y"]
    cov_xy = model["cov_xy"]
    determinant = max(var_x * var_y - cov_xy * cov_xy, 1e-6)

    inv_xx = var_y / determinant
    inv_yy = var_x / determinant
    inv_xy = -cov_xy / determinant
    mahalanobis = dx * dx * inv_xx + 2.0 * dx * dy * inv_xy + dy * dy * inv_yy
    return -0.5 * mahalanobis - 0.5 * math.log(determinant)


def write_gaussian_territories(
    lines: list[str],
    taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
    territory_step: int,
) -> None:
    models = grouped_session_gaussians(taps, frames)
    if len(models) < 2:
        return

    for key, (x, y, w, h) in frames.items():
        clip_id = f"clip_{key}_{abs(hash((key, territory_step))) % 1_000_000}"
        lines.append("<defs>")
        lines.append(
            f'<clipPath id="{clip_id}"><rect x="{x:.2f}" y="{KEYBOARD_Y + y:.2f}" '
            f'width="{w:.2f}" height="{h:.2f}" rx="8"/></clipPath>'
        )
        lines.append("</defs>")
        lines.append(f'<g clip-path="url(#{clip_id})" opacity="0.78">')

        sample_y = KEYBOARD_Y + y
        while sample_y < KEYBOARD_Y + y + h:
            sample_x = x
            while sample_x < x + w:
                cx = sample_x + territory_step / 2
                cy = sample_y + territory_step / 2
                winner = max(models, key=lambda model: gaussian_score(model, cx, cy))
                color = key_color(winner["key"])
                lines.append(
                    f'<rect x="{sample_x:.2f}" y="{sample_y:.2f}" '
                    f'width="{territory_step + 0.8:.2f}" height="{territory_step + 0.8:.2f}" '
                    f'fill="{color}" fill-opacity="0.26"/>'
                )
                sample_x += territory_step
            sample_y += territory_step

        lines.append("</g>")


def write_boundaries(
    lines: list[str],
    taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
    *,
    previous: bool,
) -> None:
    for key, (cx, cy, rx, ry, angle) in grouped_session_boundaries(taps, frames):
        if previous:
            stroke = "#2c2c2e"
            opacity = "0.34"
            width = "2.2"
            dash = ' stroke-dasharray="6 5"'
        else:
            stroke = key_color(key)
            opacity = "0.96"
            width = "3.0"
            dash = ""

        lines.append(
            f'<ellipse cx="{cx:.2f}" cy="{cy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" '
            f'transform="rotate({angle:.2f} {cx:.2f} {cy:.2f})" '
            f'fill="none" stroke="#ffffff" stroke-opacity="0.88" stroke-width="{float(width) + 2.0:.1f}"/>'
        )
        lines.append(
            f'<ellipse cx="{cx:.2f}" cy="{cy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" '
            f'transform="rotate({angle:.2f} {cx:.2f} {cy:.2f})" '
            f'fill="none" stroke="{stroke}" stroke-opacity="{opacity}" stroke-width="{width}"{dash}/>'
        )


def write_keyboard_base(
    lines: list[str],
    frames: dict[str, tuple[float, float, float, float]],
) -> None:
    for key, (x, y, w, h) in frames.items():
        lines.append(
            f'<rect x="{x:.2f}" y="{y + KEYBOARD_Y:.2f}" width="{w:.2f}" height="{h:.2f}" '
            f'rx="8" fill="#eef0f4" stroke="#c7c7cc" stroke-width="1"/>'
        )
        label = "space" if key == "space" else key
        lines.append(
            f'<text x="{x + 8:.2f}" y="{KEYBOARD_Y + y + h - 14:.2f}" '
            f'font-family="Menlo,monospace" font-size="12" fill="#60636b">{svg_escape(label)}</text>'
        )


def append_key_color_legend(lines: list[str], start_y: float) -> None:
    for offset, key in enumerate(ALL_KEYS):
        column = offset % 10
        row = offset // 10
        x = SIDE_PAD + column * 94
        y = start_y + row * 24
        lines.append(f'<rect x="{x - 7}" y="{y - 8}" width="14" height="14" rx="3" fill="{key_color(key)}"/>')
        lines.append(
            f'<text x="{x + 12}" y="{y + 4}" font-family="Menlo,monospace" '
            f'font-size="11" fill="#2c2c2e">{svg_escape(key)}</text>'
        )


def taps_by_key(taps: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for tap in taps:
        grouped[tap["key"]].append(tap)
    return grouped


def draw_jaccard_cells(
    lines: list[str],
    previous_taps: list[dict],
    latest_taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
    grid_size: int,
) -> None:
    previous_by_key = taps_by_key(previous_taps)
    latest_by_key = taps_by_key(latest_taps)

    for key, (x, y, w, h) in frames.items():
        previous_hist = histogram(previous_by_key.get(key, []), grid_size)
        latest_hist = histogram(latest_by_key.get(key, []), grid_size)
        cells = sorted(set(previous_hist) | set(latest_hist))
        if not cells:
            continue

        clip_id = f"jaccard_clip_{key}_{grid_size}"
        cell_w = w / grid_size
        cell_h = h / grid_size
        lines.append("<defs>")
        lines.append(
            f'<clipPath id="{clip_id}"><rect x="{x:.2f}" y="{KEYBOARD_Y + y:.2f}" '
            f'width="{w:.2f}" height="{h:.2f}" rx="8"/></clipPath>'
        )
        lines.append("</defs>")
        lines.append(f'<g clip-path="url(#{clip_id})">')

        for row, column in cells:
            in_previous = (row, column) in previous_hist
            in_latest = (row, column) in latest_hist
            if in_previous and in_latest:
                fill = "#111111"
                opacity = "0.62"
                stroke = key_color(key)
                stroke_opacity = "0.80"
            elif in_latest:
                fill = key_color(key)
                opacity = "0.56"
                stroke = key_color(key)
                stroke_opacity = "0.50"
            else:
                fill = "#9AA0A6"
                opacity = "0.34"
                stroke = "#6E6E73"
                stroke_opacity = "0.26"

            lines.append(
                f'<rect x="{x + column * cell_w:.2f}" y="{KEYBOARD_Y + y + row * cell_h:.2f}" '
                f'width="{cell_w + 0.30:.2f}" height="{cell_h + 0.30:.2f}" '
                f'fill="{fill}" fill-opacity="{opacity}" stroke="{stroke}" '
                f'stroke-opacity="{stroke_opacity}" stroke-width="0.35"/>'
            )

        lines.append("</g>")


def gaussian_models_by_key(
    taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
) -> dict[str, dict]:
    return {model["key"]: model for model in grouped_session_gaussians(taps, frames)}


def gaussian_overlap_cells(
    previous_model: dict,
    latest_model: dict,
    frame: tuple[float, float, float, float],
    sample_step: int,
) -> tuple[float | None, list[dict]]:
    x, y, w, h = frame
    raw_cells: list[tuple[float, float, float, float]] = []
    max_log_density = -math.inf

    sample_y = KEYBOARD_Y + y
    while sample_y < KEYBOARD_Y + y + h:
        sample_x = x
        while sample_x < x + w:
            center_x = sample_x + sample_step / 2
            center_y = sample_y + sample_step / 2
            previous_log_density = gaussian_score(previous_model, center_x, center_y)
            latest_log_density = gaussian_score(latest_model, center_x, center_y)
            max_log_density = max(max_log_density, previous_log_density, latest_log_density)
            raw_cells.append((sample_x, sample_y, previous_log_density, latest_log_density))
            sample_x += sample_step
        sample_y += sample_step

    if not raw_cells or not math.isfinite(max_log_density):
        return None, []

    density_cells: list[dict] = []
    overlap_sum = 0.0
    union_sum = 0.0
    max_union = 0.0

    for sample_x, sample_y, previous_log_density, latest_log_density in raw_cells:
        previous_density = math.exp(max(previous_log_density - max_log_density, -745.0))
        latest_density = math.exp(max(latest_log_density - max_log_density, -745.0))
        overlap_density = min(previous_density, latest_density)
        union_density = max(previous_density, latest_density)
        overlap_sum += overlap_density
        union_sum += union_density
        max_union = max(max_union, union_density)
        density_cells.append(
            {
                "x": sample_x,
                "y": sample_y,
                "previous": previous_density,
                "latest": latest_density,
                "overlap": overlap_density,
                "union": union_density,
            }
        )

    if union_sum <= 0 or max_union <= 0:
        return None, []

    for cell in density_cells:
        cell["previous"] /= max_union
        cell["latest"] /= max_union
        cell["overlap"] /= max_union
        cell["union"] /= max_union

    return overlap_sum / union_sum, density_cells


def gaussian_overlap_analysis(
    previous_taps: list[dict],
    latest_taps: list[dict],
    frames: dict[str, tuple[float, float, float, float]],
    sample_step: int,
) -> tuple[float | None, list[dict], dict[str, list[dict]]]:
    previous_models = gaussian_models_by_key(previous_taps, frames)
    latest_models = gaussian_models_by_key(latest_taps, frames)
    weighted: list[tuple[float, int]] = []
    by_key_rows: list[dict] = []
    cells_by_key: dict[str, list[dict]] = {}

    for key in ALL_KEYS:
        previous_model = previous_models.get(key)
        latest_model = latest_models.get(key)
        frame = frames.get(key)
        if previous_model is None or latest_model is None or frame is None:
            continue

        similarity, cells = gaussian_overlap_cells(previous_model, latest_model, frame, sample_step)
        if similarity is None:
            continue

        previous_count = int(previous_model["count"])
        latest_count = int(latest_model["count"])
        weight = previous_count + latest_count
        weighted.append((similarity, weight))
        cells_by_key[key] = cells
        by_key_rows.append(
            {
                "key": key,
                "similarity": f"{similarity:.6f}",
                "loss": f"{1.0 - similarity:.6f}",
                "latest_taps": latest_count,
                "previous_taps": previous_count,
            }
        )

    if not weighted:
        return None, by_key_rows, cells_by_key

    total_weight = sum(weight for _, weight in weighted)
    similarity = sum(value * weight for value, weight in weighted) / total_weight
    return similarity, by_key_rows, cells_by_key


def draw_gaussian_overlap_cells(
    lines: list[str],
    cells_by_key: dict[str, list[dict]],
    frames: dict[str, tuple[float, float, float, float]],
    sample_step: int,
) -> None:
    for key, cells in cells_by_key.items():
        frame = frames.get(key)
        if frame is None:
            continue
        x, y, w, h = frame
        clip_id = f"gaussian_overlap_clip_{key}_{sample_step}"
        lines.append("<defs>")
        lines.append(
            f'<clipPath id="{clip_id}"><rect x="{x:.2f}" y="{KEYBOARD_Y + y:.2f}" '
            f'width="{w:.2f}" height="{h:.2f}" rx="8"/></clipPath>'
        )
        lines.append("</defs>")
        lines.append(f'<g clip-path="url(#{clip_id})">')

        for cell in cells:
            previous_opacity = min(0.26, 0.24 * math.sqrt(cell["previous"]))
            if previous_opacity > 0.012:
                lines.append(
                    f'<rect x="{cell["x"]:.2f}" y="{cell["y"]:.2f}" '
                    f'width="{sample_step + 0.8:.2f}" height="{sample_step + 0.8:.2f}" '
                    f'fill="#6E7F91" fill-opacity="{previous_opacity:.3f}"/>'
                )

        for cell in cells:
            latest_opacity = min(0.38, 0.36 * math.sqrt(cell["latest"]))
            if latest_opacity > 0.014:
                lines.append(
                    f'<rect x="{cell["x"]:.2f}" y="{cell["y"]:.2f}" '
                    f'width="{sample_step + 0.8:.2f}" height="{sample_step + 0.8:.2f}" '
                    f'fill="{key_color(key)}" fill-opacity="{latest_opacity:.3f}"/>'
                )

        for cell in cells:
            overlap_opacity = min(0.70, 0.66 * math.sqrt(cell["overlap"]))
            if overlap_opacity > 0.018:
                lines.append(
                    f'<rect x="{cell["x"]:.2f}" y="{cell["y"]:.2f}" '
                    f'width="{sample_step + 0.8:.2f}" height="{sample_step + 0.8:.2f}" '
                    f'fill="#111111" fill-opacity="{overlap_opacity:.3f}"/>'
                )

        lines.append("</g>")


def write_jaccard_overlay_svg(
    path: Path,
    sessions: dict[int, list[dict]],
    visible: list[int],
    grid_size: int,
) -> None:
    frames = keyboard_frames()
    key_legend_rows = math.ceil(len(ALL_KEYS) / 10)
    legend_y = KEYBOARD_Y + HEIGHT + 42
    svg_height = legend_y + 72 + key_legend_rows * 24 + 34
    latest_session = visible[-1]
    latest_taps = sessions.get(latest_session, [])
    previous_taps = [tap for session_id in visible[:-1] for tap in sessions.get(session_id, [])]
    similarity, _ = session_similarity(latest_taps, previous_taps, grid_size) if previous_taps else (None, [])
    metric_text = (
        "No previous sessions yet, so Jaccard starts on the next frame."
        if similarity is None
        else f"Weighted Jaccard similarity: {similarity:.3f}; loss: {1.0 - similarity:.3f}"
    )

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{svg_height}" viewBox="0 0 {WIDTH} {svg_height}">',
        '<rect width="100%" height="100%" fill="#fbfbfd"/>',
        f'<text x="{SIDE_PAD}" y="30" font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700">Jaccard cells: {" + ".join(f"S{i + 1}" for i in visible)}</text>',
        f'<text x="{SIDE_PAD}" y="50" font-family="Helvetica,Arial,sans-serif" font-size="12" fill="#5f6368">{svg_escape(metric_text)}</text>',
    ]

    write_keyboard_base(lines, frames)
    draw_jaccard_cells(lines, previous_taps, latest_taps, frames, grid_size)

    for tap in previous_taps:
        point = canvas_point(tap, frames)
        if point is None:
            continue
        cx, cy = point
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.25" fill="#D1D1D6" fill-opacity="0.36" stroke="#77777C" stroke-width="0.6"/>')

    for tap in latest_taps:
        point = canvas_point(tap, frames)
        if point is None:
            continue
        cx, cy = point
        fill = key_color(tap["key"])
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.75" fill="#ffffff" fill-opacity="0.82"/>')
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.25" fill="{fill}" fill-opacity="0.88" stroke="{fill}" stroke-width="0.8"/>')

    legend_items = [
        ("previous-only cell", "#9AA0A6", "0.42"),
        ("newest-only cell", key_color("a"), "0.62"),
        ("overlap cell", "#111111", "0.70"),
        ("previous dots", "#D1D1D6", "0.70"),
        (f"newest dots S{latest_session + 1}", "#111111", "1.00"),
    ]
    for offset, (label, color, opacity) in enumerate(legend_items):
        x = SIDE_PAD + offset * 176
        y = legend_y
        if "dots" in label:
            lines.append(f'<circle cx="{x}" cy="{y}" r="7" fill="{color}" fill-opacity="{opacity}" stroke="#6E6E73" stroke-width="0.7"/>')
        else:
            lines.append(f'<rect x="{x - 8}" y="{y - 8}" width="16" height="16" rx="3" fill="{color}" fill-opacity="{opacity}"/>')
        lines.append(
            f'<text x="{x + 14}" y="{y + 5}" font-family="Helvetica,Arial,sans-serif" '
            f'font-size="11" font-weight="700" fill="#1c1c1e">{svg_escape(label)}</text>'
        )

    lines.append(
        f'<text x="{SIDE_PAD}" y="{legend_y + 34}" font-family="Helvetica,Arial,sans-serif" '
        f'font-size="11" fill="#5f6368">Newest-only cells and newest dots use the key color below. Dark cells are where newest and previous sessions share the same key/bin.</text>'
    )
    append_key_color_legend(lines, legend_y + 70)

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_gaussian_overlap_svg(
    path: Path,
    sessions: dict[int, list[dict]],
    visible: list[int],
    sample_step: int,
) -> tuple[float | None, list[dict]]:
    frames = keyboard_frames()
    key_legend_rows = math.ceil(len(ALL_KEYS) / 10)
    legend_y = KEYBOARD_Y + HEIGHT + 42
    svg_height = legend_y + 74 + key_legend_rows * 24 + 34
    latest_session = visible[-1]
    latest_taps = sessions.get(latest_session, [])
    previous_taps = [tap for session_id in visible[:-1] for tap in sessions.get(session_id, [])]
    similarity, by_key_rows, cells_by_key = gaussian_overlap_analysis(
        previous_taps,
        latest_taps,
        frames,
        sample_step,
    )
    metric_text = (
        "No previous Gaussian models yet, so overlap starts on the next frame."
        if similarity is None
        else f"Gaussian overlap similarity: {similarity:.3f}; loss: {1.0 - similarity:.3f}"
    )

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{svg_height}" viewBox="0 0 {WIDTH} {svg_height}">',
        '<rect width="100%" height="100%" fill="#fbfbfd"/>',
        f'<text x="{SIDE_PAD}" y="30" font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700">Gaussian overlap: {" + ".join(f"S{i + 1}" for i in visible)}</text>',
        f'<text x="{SIDE_PAD}" y="50" font-family="Helvetica,Arial,sans-serif" font-size="12" fill="#5f6368">{svg_escape(metric_text)}</text>',
    ]

    write_keyboard_base(lines, frames)
    draw_gaussian_overlap_cells(lines, cells_by_key, frames, sample_step)

    if previous_taps:
        write_boundaries(lines, previous_taps, frames, previous=True)
    write_boundaries(lines, latest_taps, frames, previous=False)

    for tap in previous_taps:
        point = canvas_point(tap, frames)
        if point is None:
            continue
        cx, cy = point
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.05" fill="#D1D1D6" fill-opacity="0.30" stroke="#77777C" stroke-width="0.5"/>')

    for tap in latest_taps:
        point = canvas_point(tap, frames)
        if point is None:
            continue
        cx, cy = point
        fill = key_color(tap["key"])
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.70" fill="#ffffff" fill-opacity="0.82"/>')
        lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="2.15" fill="{fill}" fill-opacity="0.86" stroke="{fill}" stroke-width="0.8"/>')

    legend_items = [
        ("previous density", "#6E7F91", "0.24"),
        ("newest density", key_color("a"), "0.34"),
        ("shared overlap", "#111111", "0.68"),
        ("previous Gaussian", "#2c2c2e", "0.45"),
        (f"newest Gaussian S{latest_session + 1}", "#111111", "1.00"),
    ]
    for offset, (label, color, opacity) in enumerate(legend_items):
        x = SIDE_PAD + offset * 176
        y = legend_y
        if "Gaussian" in label:
            lines.append(
                f'<ellipse cx="{x}" cy="{y}" rx="11" ry="7" fill="none" '
                f'stroke="{color}" stroke-opacity="{opacity}" stroke-width="2.2"/>'
            )
        else:
            lines.append(f'<rect x="{x - 8}" y="{y - 8}" width="16" height="16" rx="3" fill="{color}" fill-opacity="{opacity}"/>')
        lines.append(
            f'<text x="{x + 14}" y="{y + 5}" font-family="Helvetica,Arial,sans-serif" '
            f'font-size="11" font-weight="700" fill="#1c1c1e">{svg_escape(label)}</text>'
        )

    lines.append(
        f'<text x="{SIDE_PAD}" y="{legend_y + 34}" font-family="Helvetica,Arial,sans-serif" '
        f'font-size="11" fill="#5f6368">This compares smooth learned Gaussian density, so nearby taps still partially overlap instead of needing the exact same bin.</text>'
    )
    append_key_color_legend(lines, legend_y + 72)

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")
    return similarity, by_key_rows


def write_overlay_svg(
    path: Path,
    sessions: dict[int, list[dict]],
    visible: list[int],
    territory_step: int,
) -> None:
    frames = keyboard_frames()
    key_legend_rows = math.ceil(len(ALL_KEYS) / 10)
    legend_y = KEYBOARD_Y + HEIGHT + 40
    svg_height = legend_y + LEGEND_ROW_H + key_legend_rows * 24 + 34
    visible_taps = [tap for session_id in visible for tap in sessions.get(session_id, [])]
    previous_taps = [tap for session_id in visible[:-1] for tap in sessions.get(session_id, [])]

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{svg_height}" viewBox="0 0 {WIDTH} {svg_height}">',
        '<rect width="100%" height="100%" fill="#fbfbfd"/>',
        f'<text x="{SIDE_PAD}" y="30" font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700">Session overlap: {" + ".join(f"S{i + 1}" for i in visible)}</text>',
        f'<text x="{SIDE_PAD}" y="50" font-family="Helvetica,Arial,sans-serif" font-size="12" fill="#5f6368">Colored dots are the newest session by key; previous session dots are grey.</text>',
    ]

    write_keyboard_base(lines, frames)

    write_gaussian_territories(lines, visible_taps, frames, territory_step)

    if previous_taps:
        write_boundaries(lines, previous_taps, frames, previous=True)
    write_boundaries(lines, visible_taps, frames, previous=False)

    latest_session = visible[-1]
    for offset, session_index in enumerate(visible):
        is_latest = session_index == latest_session
        radius = 3.8 + min(offset, 8) * 0.08
        for tap in sessions.get(session_index, []):
            point = canvas_point(tap, frames)
            if point is None:
                continue
            cx, cy = point
            if is_latest:
                fill = key_color(tap["key"])
                opacity = "0.78"
                stroke = fill
                stroke_width = "1.2"
                halo = "0.80"
            else:
                fill = "#8E8E93"
                opacity = "0.23"
                stroke = "#6E6E73"
                stroke_width = "0.8"
                halo = "0.48"
            lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{radius + 1.2:.2f}" fill="#ffffff" fill-opacity="{halo}"/>')
            lines.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{radius:.2f}" fill="{fill}" fill-opacity="{opacity}" stroke="{stroke}" stroke-width="{stroke_width}"/>')

    legend_items = [("Previous sessions", "#8E8E93"), (f"Newest session S{latest_session + 1}", "#111111")]
    for offset, (label, color) in enumerate(legend_items):
        x = SIDE_PAD + offset * 220
        y = legend_y
        if offset == 0:
            lines.append(f'<circle cx="{x}" cy="{y}" r="8" fill="{color}" fill-opacity="0.35" stroke="#6E6E73"/>')
        else:
            lines.append(f'<circle cx="{x}" cy="{y}" r="8" fill="{color}"/>')
        lines.append(f'<text x="{x + 14}" y="{y + 5}" font-family="Helvetica,Arial,sans-serif" font-size="14" font-weight="700" fill="#1c1c1e">{svg_escape(label)}</text>')

    append_key_color_legend(lines, legend_y + LEGEND_ROW_H)

    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_outputs(
    sessions: dict[int, list[dict]],
    output_dir: Path,
    grid_size: int,
    territory_step: int,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    session_ids = sorted(sessions)
    summary_rows: list[dict] = []
    by_key_rows: list[dict] = []
    gaussian_summary_rows: list[dict] = []
    gaussian_by_key_rows: list[dict] = []

    for count in range(1, len(session_ids) + 1):
        visible = session_ids[:count]
        write_overlay_svg(
            output_dir / f"session_overlap_overlay_{count:02d}.svg",
            sessions,
            visible,
            territory_step,
        )
        write_jaccard_overlay_svg(
            output_dir / f"session_jaccard_overlay_{count:02d}.svg",
            sessions,
            visible,
            grid_size,
        )
        latest_id = visible[-1]
        latest = sessions[latest_id]
        previous = [tap for session_id in visible[:-1] for tap in sessions[session_id]]
        gaussian_similarity, gaussian_by_key = write_gaussian_overlap_svg(
            output_dir / f"session_gaussian_overlap_{count:02d}.svg",
            sessions,
            visible,
            territory_step,
        )
        gaussian_summary_rows.append(
            {
                "visible_sessions": ",".join(str(i + 1) for i in visible),
                "latest_session": latest_id + 1,
                "similarity": "" if gaussian_similarity is None else f"{gaussian_similarity:.6f}",
                "loss": "" if gaussian_similarity is None else f"{1.0 - gaussian_similarity:.6f}",
                "latest_taps": len(latest),
                "previous_taps": len(previous),
                "num_keys_compared": len(gaussian_by_key),
            }
        )
        for row in gaussian_by_key:
            gaussian_by_key_rows.append(
                {
                    "visible_sessions": ",".join(str(i + 1) for i in visible),
                    "latest_session": latest_id + 1,
                    **row,
                }
            )

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

    with (output_dir / "session_gaussian_overlap_summary.csv").open("w", newline="", encoding="utf-8") as handle:
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
        writer.writerows(gaussian_summary_rows)

    with (output_dir / "session_gaussian_overlap_by_key.csv").open("w", newline="", encoding="utf-8") as handle:
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
        writer.writerows(gaussian_by_key_rows)


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

    write_outputs(sessions, output_dir, args.grid_size, max(args.territory_step, 2))
    print(f"Input CSV: {csv_path}")
    print(f"Output dir: {output_dir}")
    print(f"Sessions: {', '.join(str(index + 1) for index in sessions)}")


if __name__ == "__main__":
    main()
