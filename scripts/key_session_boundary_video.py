#!/usr/bin/env python3
"""
Create video-ready per-key Gaussian boundary frames over sessions.

This script:

1. Fits a cumulative Gaussian model after each visible session.
2. Fits one final classic-only ground-truth model.
3. Measures session-vs-ground-truth overlap for each key's winning region.
4. Exports per-key frame sequences where each frame shows:
   - one key's current Gaussian winning region
   - a white background everywhere else
   - an optional solid black final boundary overlay
   - keyboard outlines only, with no contour circles or extra overlays

Primary outputs:

- `key_boundary_overlap_summary.csv`
- `key_boundary_overlap_by_session.csv`
- `key_boundary_frame_manifest.csv`
- `largest_difference_key.txt`
- `frames/<key>/frame_XX_*.png` or `.svg`
- `frames/whole_keyboard/frame_XX_*.png` or `.svg`
- `videos/whole_keyboard_boundary.mp4` when PNG frames are enabled and ffmpeg is available
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import shutil
import subprocess
import tempfile
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "matplotlib"))
os.environ.setdefault("XDG_CACHE_HOME", str(Path(tempfile.gettempdir()) / "xdg-cache"))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import FancyBboxPatch, Rectangle
from PIL import Image, ImageDraw, ImageFont

import gaussian_keyboard_pdf as gkp

ISOLATED_FILL_ALPHA = 110
WHITE_RGBA = np.array([255, 255, 255, 255], dtype=np.uint8)
CM_PER_INCH = 2.54
BADGE_PADDING_CM = 0.04
DISPLAY_BADGE_HEIGHT_FRAC = 0.62
DISPLAY_BADGE_MIN = 44.0


@dataclass(frozen=True)
class SamplingLayout:
    coarse_w: int
    coarse_h: int
    sub_samples: int
    fine_w: int
    fine_h: int


@dataclass(frozen=True)
class Snapshot:
    latest_session: int
    visible_sessions: list[int]
    visible_trial_count: int
    total_trial_count: int
    model: dict[str, gkp.Gaussian2D]
    winner_indices: np.ndarray


def demo_key_dimensions(key: str) -> tuple[float, float]:
    letter_w = 54.0
    letter_h = 72.0
    if key in gkp.LETTER_KEYS:
        return letter_w, letter_h
    if key == "delete":
        return ((3.0 * letter_w + gkp.LIVE_KEY_GAP) / 2.0, letter_h)
    if key == "space":
        return (7.0 * letter_w + 6.0 * gkp.LIVE_KEY_GAP, letter_h)
    return letter_w, letter_h


def key_row_col(key: str) -> tuple[int, float]:
    if key in gkp.ROW0:
        col = gkp.ROW0.index(key)
        return (0, -1.0 + 2.0 * col / max(1, len(gkp.ROW0) - 1))
    if key in gkp.ROW1:
        col = gkp.ROW1.index(key)
        return (1, -1.0 + 2.0 * col / max(1, len(gkp.ROW1) - 1))
    if key in gkp.ROW2:
        col = gkp.ROW2.index(key)
        return (2, -1.0 + 2.0 * col / max(1, len(gkp.ROW2) - 1))
    if key == "space":
        return (3, 0.0)
    return (2, 1.25)


def demo_session_shift(key: str, session_index: int) -> tuple[float, float]:
    row, col = key_row_col(key)
    row_center = row - 1.2
    if session_index == 1:
        return (-0.11 * col, -0.08 + 0.04 * row_center)
    if session_index == 2:
        return (0.06 * math.sin((col + 1.0) * 1.8), -0.05 * col + 0.03 * row_center)
    if session_index == 3:
        return (0.09 * col, 0.07 - 0.05 * row_center)
    return (-0.04 + 0.05 * row_center, 0.10 * math.cos((col + 1.0) * 1.3) - 0.02 * col)


def demo_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    timestamp = 0
    taps_per_key = 18

    for session_index in range(1, 5):
        for key in gkp.ALL_KEYS:
            key_w, key_h = demo_key_dimensions(key)
            shift_x, shift_y = demo_session_shift(key, session_index)
            row, col = key_row_col(key)
            jitter_scale_x = 0.035 + 0.010 * (row + 1)
            jitter_scale_y = 0.030 + 0.008 * (2 - min(row, 2))

            for tap_index in range(taps_per_key):
                angle = tap_index * 1.9 + session_index * 0.7 + col * 0.8
                ring = 0.030 + 0.010 * (tap_index % 3)
                local_norm_x = 0.5 + shift_x + math.cos(angle) * ring + math.sin(angle * 0.5) * jitter_scale_x
                local_norm_y = 0.5 + shift_y + math.sin(angle) * ring * 0.82 + math.cos(angle * 0.6) * jitter_scale_y
                local_norm_x = min(max(local_norm_x, 0.08), 0.92)
                local_norm_y = min(max(local_norm_y, 0.10), 0.90)

                expected_char = " " if key == "space" else ""
                if key in gkp.LETTER_KEYS:
                    expected_char = key

                rows.append(
                    {
                        "session_mode": "classic",
                        "event_type": "insert",
                        "is_outlier": "0",
                        "outlier_flags": "",
                        "is_correct": "1",
                        "study_session_index": str(session_index),
                        "trial_index": str(tap_index // 6),
                        "trial_id": f"s{session_index}-{key}-{tap_index // 6}",
                        "timestamp_ms": str(timestamp),
                        "expected_char": expected_char,
                        "key_label": key,
                        "tap_norm_x": f"{local_norm_x:.6f}",
                        "tap_norm_y": f"{local_norm_y:.6f}",
                        "tap_local_x": f"{local_norm_x * key_w:.6f}",
                        "tap_local_y": f"{local_norm_y * key_h:.6f}",
                        "key_width": f"{key_w:.6f}",
                        "key_height": f"{key_h:.6f}",
                    }
                )
                timestamp += 10
    return rows


def write_demo_csv(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = demo_rows()
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "csv_path",
        nargs="?",
        help="Cleaned keystroke CSV. Omit with --demo to generate synthetic data.",
    )
    parser.add_argument(
        "--output-dir",
        default="key_session_boundary_video_outputs",
        help="Directory for summary CSVs and per-key frame exports.",
    )
    parser.add_argument(
        "--raster-step",
        type=float,
        default=gkp.RASTER_STEP,
        help="Raster sampling step for region masks. Lower is smoother but slower.",
    )
    parser.add_argument(
        "--scale",
        type=float,
        default=2.0,
        help="Scale factor applied to the keyboard panel before export.",
    )
    parser.add_argument(
        "--dpi",
        type=float,
        default=220.0,
        help="Raster DPI for PNG output.",
    )
    parser.add_argument(
        "--format",
        choices=["png", "svg", "both"],
        default="png",
        help="Output format for frame exports (default: png).",
    )
    parser.add_argument(
        "--keys",
        nargs="+",
        help="Optional subset of keys to export. Defaults to all keys.",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=2.0,
        help="Frames per second for the combined all-letters MP4 export.",
    )
    parser.add_argument(
        "--skip-letter-overview",
        action="store_true",
        help="Skip the combined all-letters frame sequence and MP4 export.",
    )
    parser.add_argument(
        "--skip-video",
        action="store_true",
        help="Skip MP4 assembly even when PNG frames are available.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate synthetic shifted sessions before rendering outputs.",
    )
    return parser.parse_args()


def grouped_session_events(events: list[gkp.Event]) -> dict[int, list[gkp.Event]]:
    grouped: dict[int, list[gkp.Event]] = defaultdict(list)
    for event in events:
        grouped[event.study_session_index].append(event)

    ordered: dict[int, list[gkp.Event]] = {}
    for session_id in sorted(grouped):
        ordered[session_id] = sorted(
            grouped[session_id],
            key=lambda event: (event.trial_index, event.timestamp_ms),
        )
    return ordered


def sampling_layout(canvas: gkp.Rect, raster_step: float) -> SamplingLayout:
    sample_step = max(1.0, float(raster_step))
    coarse_w = max(1, int(math.ceil(canvas.w / sample_step)))
    coarse_h = max(1, int(math.ceil(canvas.h / sample_step)))
    sub_samples = 3 if sample_step >= 4 else 2 if sample_step >= 2 else 1
    fine_w = coarse_w * sub_samples
    fine_h = coarse_h * sub_samples
    return SamplingLayout(
        coarse_w=coarse_w,
        coarse_h=coarse_h,
        sub_samples=sub_samples,
        fine_w=fine_w,
        fine_h=fine_h,
    )


def build_sampling_grid(canvas: gkp.Rect, raster_step: float) -> tuple[np.ndarray, np.ndarray, SamplingLayout]:
    layout = sampling_layout(canvas, raster_step)

    sample_x = np.linspace(
        canvas.x + canvas.w / (2.0 * layout.fine_w),
        canvas.x + canvas.w - canvas.w / (2.0 * layout.fine_w),
        layout.fine_w,
        dtype=np.float32,
    )
    sample_y = np.linspace(
        canvas.y + canvas.h / (2.0 * layout.fine_h),
        canvas.y + canvas.h - canvas.h / (2.0 * layout.fine_h),
        layout.fine_h,
        dtype=np.float32,
    )
    return sample_x, sample_y, layout


def winner_indices_for_model(
    *,
    sample_x: np.ndarray,
    sample_y: np.ndarray,
    frames: dict[str, gkp.Rect],
    model: dict[str, gkp.Gaussian2D],
) -> np.ndarray:
    return gkp.winner_indices_grid(sample_x, sample_y, gkp.raster_key_params(frames, model))


def mix_with_white(rgb: tuple[float, float, float], amount: float) -> tuple[float, float, float]:
    blend = max(0.0, min(1.0, amount))
    return tuple(channel * (1.0 - blend) + blend for channel in rgb)


def key_rgb(key: str) -> tuple[float, float, float]:
    red, green, blue, _ = gkp.key_color(key)
    return (red, green, blue)


def display_key_label(key: str) -> str:
    if key == "space":
        return "SPACE"
    if key == "delete":
        return "DEL"
    return key.upper()


def frame_badge_lines(
    *,
    title: str,
    snapshot: Snapshot,
) -> tuple[str, str]:
    return (
        title,
        f"Session {snapshot.latest_session}   Trials {snapshot.visible_trial_count}/{snapshot.total_trial_count}",
    )


def visible_session_label(session_ids: list[int]) -> str:
    return ",".join(str(session_id + 1) for session_id in session_ids)


def draw_frame_badge(
    *,
    ax: plt.Axes,
    export_rect: gkp.Rect,
    keyboard_panel_rect: gkp.Rect,
    badge_gap_px: float,
    title: str,
    detail: str,
) -> None:
    badge_x = keyboard_panel_rect.x + keyboard_panel_rect.w * 0.040
    badge_y = export_rect.y
    ax.text(
        badge_x,
        badge_y,
        f"{title}\n{detail}",
        ha="left",
        va="top",
        color="#0F172A",
        fontsize=max(10.0, min(13.0, max(DISPLAY_BADGE_MIN, badge_gap_px) * 0.28)),
        fontweight="bold",
        linespacing=1.25,
        bbox={
            "boxstyle": "round,pad=0.48,rounding_size=0.6",
            "facecolor": (248 / 255.0, 250 / 255.0, 252 / 255.0, 0.93),
            "edgecolor": (15 / 255.0, 23 / 255.0, 42 / 255.0, 0.18),
            "linewidth": 1.0,
        },
        zorder=5.2,
    )


def annotate_frame_rgba(
    *,
    frame_rgba: np.ndarray,
    title: str,
    detail: str,
    badge_region_top_px: int | None = None,
    badge_region_bottom_px: int | None = None,
) -> np.ndarray:
    image = Image.fromarray(frame_rgba, mode="RGBA")
    draw = ImageDraw.Draw(image, "RGBA")
    title_font = ImageFont.load_default(size=max(15, image.height // 26))
    detail_font = ImageFont.load_default(size=max(12, image.height // 34))
    pad_x = max(12, image.width // 24)
    pad_y = max(12, image.height // 26)
    inner_pad_x = max(10, image.width // 48)
    inner_pad_y = max(8, image.height // 52)
    line_gap = max(4, image.height // 120)

    title_box = draw.textbbox((0, 0), title, font=title_font)
    detail_box = draw.textbbox((0, 0), detail, font=detail_font)
    text_w = max(title_box[2] - title_box[0], detail_box[2] - detail_box[0])
    title_h = title_box[3] - title_box[1]
    detail_h = detail_box[3] - detail_box[1]
    box_w = text_w + inner_pad_x * 2
    box_h = title_h + detail_h + line_gap + inner_pad_y * 2

    left = pad_x
    if badge_region_top_px is not None and badge_region_bottom_px is not None:
        region_top = max(0, badge_region_top_px)
        region_bottom = max(region_top + 1, badge_region_bottom_px)
        top = max(0, min(region_top, region_bottom - box_h))
    else:
        top = pad_y
    right = left + box_w
    bottom = top + box_h
    draw.rounded_rectangle(
        (left, top, right, bottom),
        radius=max(14, image.height // 28),
        fill=(248, 250, 252, 236),
        outline=(15, 23, 42, 38),
        width=1,
    )
    draw.text(
        (left + inner_pad_x, top + inner_pad_y),
        title,
        font=title_font,
        fill=(15, 23, 42, 255),
    )
    draw.text(
        (left + inner_pad_x, top + inner_pad_y + title_h + line_gap),
        detail,
        font=detail_font,
        fill=(30, 41, 59, 255),
    )
    return np.asarray(image)


def trial_identity(event: gkp.Event) -> tuple[int, int]:
    return (event.study_session_index, event.trial_index)


def build_display_geometry(
    *,
    base_panel_rect: gkp.Rect,
    base_frames: dict[str, gkp.Rect],
    scale: float,
    dpi: float,
) -> tuple[gkp.Rect, gkp.Rect, dict[str, gkp.Rect], float]:
    scaled_panel_rect = gkp.Rect(
        base_panel_rect.x * scale,
        base_panel_rect.y * scale,
        base_panel_rect.w * scale,
        base_panel_rect.h * scale,
    )
    scaled_frames = gkp.scale_frames(base_frames, scale)
    sample_frame = next(iter(scaled_frames.values()))
    badge_gap_px = max(0.0, float(dpi) * BADGE_PADDING_CM / CM_PER_INCH)
    badge_height = max(DISPLAY_BADGE_MIN, sample_frame.h * DISPLAY_BADGE_HEIGHT_FRAC)
    header_height = badge_gap_px + badge_height
    keyboard_panel_rect = gkp.Rect(
        scaled_panel_rect.x,
        scaled_panel_rect.y + header_height,
        scaled_panel_rect.w,
        scaled_panel_rect.h,
    )
    export_rect = gkp.Rect(
        scaled_panel_rect.x,
        scaled_panel_rect.y,
        scaled_panel_rect.w,
        scaled_panel_rect.h + header_height,
    )
    display_frames = gkp.offset_frames(scaled_frames, 0.0, header_height)
    return export_rect, keyboard_panel_rect, display_frames, badge_gap_px


def render_keyboard_base(ax, frames: dict[str, gkp.Rect]) -> None:
    for key, frame in frames.items():
        ax.add_patch(
            Rectangle(
                (frame.x, frame.y),
                frame.w,
                frame.h,
                facecolor=(1.0, 1.0, 1.0, 0.06),
                edgecolor=(17 / 255.0, 24 / 255.0, 39 / 255.0, 0.88),
                linewidth=1.2,
                zorder=3,
            )
        )
        if key in gkp.LETTER_KEYS:
            ax.text(
                frame.mid_x,
                frame.mid_y + 4.5,
                key.upper(),
                fontsize=max(6.75, frame.h * 0.191),
                fontweight="bold",
                color="#111111",
                ha="center",
                va="center",
                zorder=4,
            )
        elif key == "space":
            ax.text(
                frame.mid_x,
                frame.mid_y + 2.25,
                "SPACE",
                fontsize=5.625,
                fontweight="semibold",
                color=(17 / 255.0, 17 / 255.0, 17 / 255.0, 0.55),
                ha="center",
                va="center",
                zorder=4,
            )
        elif key == "delete":
            ax.text(
                frame.mid_x,
                frame.mid_y + 2.25,
                "DEL",
                fontsize=5.625,
                fontweight="bold",
                color=(17 / 255.0, 17 / 255.0, 17 / 255.0, 0.60),
                ha="center",
                va="center",
                zorder=4,
            )


def configure_axes(
    *,
    panel_rect: gkp.Rect,
    dpi: float,
) -> tuple[plt.Figure, plt.Axes]:
    fig = plt.figure(figsize=(panel_rect.w / dpi, panel_rect.h / dpi), dpi=dpi)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(panel_rect.x, panel_rect.x + panel_rect.w)
    ax.set_ylim(panel_rect.y + panel_rect.h, panel_rect.y)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.add_patch(
        Rectangle(
            (panel_rect.x, panel_rect.y),
            panel_rect.w,
            panel_rect.h,
            facecolor="#FFFFFF",
            edgecolor="none",
            zorder=0,
        )
    )
    return fig, ax


def save_frame(
    *,
    output_dir: Path,
    frame_index: int,
    stage: str,
    output_format: str,
    fig: plt.Figure,
    dpi: float,
    frame_rgba: np.ndarray | None = None,
) -> list[Path]:
    """Save a frame.

    If *frame_rgba* (H×W×4 uint8) is provided AND the format is png-only,
    we skip matplotlib's savefig entirely and write the PNG directly with
    PIL, which is ~3× faster.  SVG output always goes through matplotlib.
    """
    saved: list[Path] = []
    wants_png = output_format in {"png", "both"}
    wants_svg = output_format in {"svg", "both"}

    if wants_png:
        png_path = output_dir / f"frame_{frame_index:02d}_{stage}.png"
        if frame_rgba is not None and not wants_svg:
            Image.fromarray(frame_rgba, mode="RGBA").convert("RGB").save(png_path)
        else:
            fig.savefig(png_path, dpi=dpi, facecolor="white", bbox_inches=None, pad_inches=0)
        saved.append(png_path)
    if wants_svg:
        svg_path = output_dir / f"frame_{frame_index:02d}_{stage}.svg"
        fig.savefig(svg_path, facecolor="white", bbox_inches=None, pad_inches=0)
        saved.append(svg_path)

    return saved


def panel_patches(ax, panel_rect: gkp.Rect) -> tuple[object, object]:
    shadow = FancyBboxPatch(
        (panel_rect.x, panel_rect.y + 6.0),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={gkp.PANEL_RADIUS}",
        facecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.08),
        edgecolor="none",
        zorder=0.5,
    )
    ax.add_patch(shadow)

    panel = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={gkp.PANEL_RADIUS}",
        facecolor="#F8FAFC",
        edgecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.18),
        linewidth=1.2,
        zorder=1.0,
    )
    ax.add_patch(panel)

    outline = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={gkp.PANEL_RADIUS}",
        facecolor="none",
        edgecolor="#111827",
        linewidth=2.0,
        zorder=4.5,
    )
    return panel, outline


def selected_key_coverage_alpha(
    *,
    winner_indices: np.ndarray,
    key_index: int,
    analysis_rect: gkp.Rect,
    layout: SamplingLayout,
) -> np.ndarray:
    return selected_key_indices_coverage_alpha(
        winner_indices=winner_indices,
        key_indices=[key_index],
        analysis_rect=analysis_rect,
        layout=layout,
    )


def selected_key_indices_coverage_alpha(
    *,
    winner_indices: np.ndarray,
    key_indices: list[int],
    analysis_rect: gkp.Rect,
    layout: SamplingLayout,
) -> np.ndarray:
    winner_mask = np.isin(winner_indices, np.asarray(key_indices, dtype=winner_indices.dtype))
    alpha = np.zeros(winner_mask.shape, dtype=np.uint8)
    alpha[winner_mask] = 255

    if layout.sub_samples > 1:
        alpha = (
            alpha.reshape(layout.coarse_h, layout.sub_samples, layout.coarse_w, layout.sub_samples)
            .mean(axis=(1, 3), dtype=np.float32)
            .astype(np.uint8)
        )

    target_w = max(1, int(round(analysis_rect.w)))
    target_h = max(1, int(round(analysis_rect.h)))
    image = Image.fromarray(alpha, mode="L")
    if image.size != (target_w, target_h):
        image = image.resize((target_w, target_h), resample=Image.Resampling.LANCZOS)
    return np.asarray(image)


def rendered_full_winner_map_rgba(
    *,
    analysis_rect: gkp.Rect,
    frames: dict[str, gkp.Rect],
    model: dict[str, gkp.Gaussian2D],
    raster_step: float,
) -> np.ndarray:
    return gkp.raster_background_rgba(
        canvas=analysis_rect,
        frames=frames,
        model=model,
        raster_step=raster_step,
        alpha=ISOLATED_FILL_ALPHA,
    )


def rendered_full_winner_map_rgba_from_snapshot(
    *,
    snapshot: "Snapshot",
    analysis_rect: gkp.Rect,
    layout: "SamplingLayout",
) -> np.ndarray:
    """Build the full RGBA background from winner_indices already stored in
    a Snapshot, skipping the redundant winner_indices_grid call inside
    raster_background_rgba."""
    return gkp.raster_background_rgba_from_indices(
        winner_indices=snapshot.winner_indices,
        coarse_h=layout.coarse_h,
        coarse_w=layout.coarse_w,
        sub_samples=layout.sub_samples,
        canvas=analysis_rect,
        alpha=ISOLATED_FILL_ALPHA,
    )


def render_keyboard_overlay_rgba(
    *,
    export_rect: gkp.Rect,
    keyboard_panel_rect: gkp.Rect,
    display_frames: dict[str, gkp.Rect],
    dpi: float,
) -> np.ndarray:
    """Pre-render the static keyboard UI (key outlines + labels + panel border)
    to a numpy RGBA array with a fully transparent background.

    The panel shadow and fill are NOT included here — they are drawn per-frame
    by panel_patches() so that the colored key background is visible underneath.
    This image is composited on top of each frame via ax.imshow, giving key
    outlines and labels without re-drawing every patch/text object per frame.
    """
    from matplotlib.patches import FancyBboxPatch as _FBP

    fig, ax = configure_axes(panel_rect=export_rect, dpi=dpi)
    # Make the figure and all background rects fully transparent.
    fig.patch.set_alpha(0.0)
    for patch in list(ax.patches):
        patch.set_facecolor((0.0, 0.0, 0.0, 0.0))
        patch.set_edgecolor((0.0, 0.0, 0.0, 0.0))

    # Key outlines + labels (key fill is nearly transparent; only the dark
    # border and letter text will be visible over the colored background).
    render_keyboard_base(ax, display_frames)

    # Panel border only — no fill, so the background shows through.
    outline = _FBP(
        (keyboard_panel_rect.x, keyboard_panel_rect.y),
        keyboard_panel_rect.w,
        keyboard_panel_rect.h,
        boxstyle=f"round,pad=0.0,rounding_size={gkp.PANEL_RADIUS}",
        facecolor="none",
        edgecolor="#111827",
        linewidth=2.0,
        zorder=4.5,
    )
    ax.add_patch(outline)

    fig.canvas.draw()
    buf = fig.canvas.buffer_rgba()
    w, h = fig.canvas.get_width_height()
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 4).copy()
    plt.close(fig)
    return arr


def isolate_pixels_from_full_render(
    *,
    full_background: np.ndarray,
    coverage_alpha: np.ndarray,
    threshold: int = 128,
) -> np.ndarray:
    output = np.broadcast_to(WHITE_RGBA, full_background.shape).copy()
    keep_mask = coverage_alpha >= threshold
    output[keep_mask] = full_background[keep_mask]
    return output


def image_axes(analysis_rect: gkp.Rect, image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    height, width = image.shape[:2]
    x = np.linspace(
        analysis_rect.x + analysis_rect.w / (2.0 * width),
        analysis_rect.x + analysis_rect.w - analysis_rect.w / (2.0 * width),
        width,
        dtype=np.float32,
    )
    y = np.linspace(
        analysis_rect.y + analysis_rect.h / (2.0 * height),
        analysis_rect.y + analysis_rect.h - analysis_rect.h / (2.0 * height),
        height,
        dtype=np.float32,
    )
    return x, y


def _find_boundary_at_size(
    coverage_alpha: np.ndarray,
    dst_w: int,
    dst_h: int,
) -> np.ndarray:
    """Return boolean mask (dst_h, dst_w) of 1-pixel-wide boundary in display space.

    Upscales coverage_alpha to (dst_h, dst_w) with LANCZOS first so the
    boundary follows the smoother resized edge rather than the coarse grid.
    """
    alpha_img = Image.fromarray(coverage_alpha, mode="L")
    if alpha_img.size != (dst_w, dst_h):
        alpha_img = alpha_img.resize((dst_w, dst_h), resample=Image.Resampling.LANCZOS)
    alpha_disp = np.asarray(alpha_img)
    mask = alpha_disp > 127
    padded = np.pad(mask, 1, constant_values=False)
    interior = (
        padded[:-2, 1:-1] & padded[2:, 1:-1] &
        padded[1:-1, :-2] & padded[1:-1, 2:]
    )
    return mask & ~interior


def _draw_boundary_on_frame(
    frame_arr: np.ndarray,
    boundary: np.ndarray,
    color: tuple[int, int, int, int],
    radius: int,
    dashed: bool = False,
) -> None:
    """Draw a boundary mask onto frame_arr (H×W×4 uint8) in-place.

    Uses vectorized numpy slicing for each offset in the disc of the given
    radius — no Python-level per-pixel loops.  Dashed mode keeps only every
    3-of-5 boundary rows (approximates a dashed contour).
    """
    h, w = boundary.shape
    color_arr = np.array(color, dtype=np.uint8)

    draw_mask = boundary.copy()
    if dashed:
        # Sort boundary pixels by angle from centroid — O(n log n), gives
        # contour-like ordering for convex-ish key shapes so the dash period
        # is measured along the path rather than in raster-scan order.
        ys, xs = np.where(draw_mask)
        if len(ys) > 1:
            angles = np.arctan2(ys - ys.mean(), xs - xs.mean())
            order = np.argsort(angles)
            ordered_ys = ys[order]
            ordered_xs = xs[order]
            dash_on, dash_off = 10, 16
            period = dash_on + dash_off
            idx = np.arange(len(ordered_ys))
            gap = (idx % period) >= dash_on
            draw_mask[ordered_ys[gap], ordered_xs[gap]] = False

    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if dy * dy + dx * dx > radius * radius:
                continue
            # Source slice in draw_mask
            sy0 = max(0, -dy);  sy1 = h - max(0, dy)
            sx0 = max(0, -dx);  sx1 = w - max(0, dx)
            # Destination slice in frame_arr
            dy0 = max(0, dy);   dy1 = h + min(0, dy)
            dx0 = max(0, dx);   dx1 = w + min(0, dx)
            submask = draw_mask[sy0:sy1, sx0:sx1]
            frame_arr[dy0:dy1, dx0:dx1][submask] = color_arr


@dataclass(frozen=True)
class PixelBoundary:
    coverage: np.ndarray
    color: tuple[int, int, int, int]
    radius: int
    dashed: bool = False


def make_frame_rgba_pil(
    *,
    background: np.ndarray,
    keyboard_overlay_rgba: np.ndarray,
    boundaries: list[PixelBoundary],
    display_panel_rect: gkp.Rect,
    display_analysis_rect: gkp.Rect,
) -> np.ndarray:
    """Composite one frame entirely in PIL/numpy — no matplotlib figure needed.

    Steps:
    1. LANCZOS-upscale background (analysis res) to display res.
    2. Draw all requested raster boundaries in display space.
    3. Alpha-composite keyboard_overlay_rgba (outlines + labels) on top.

    Returns H×W×4 uint8 RGBA.
    """
    dst_h, dst_w = keyboard_overlay_rgba.shape[:2]
    scale_x = dst_w / max(display_panel_rect.w, 1.0)
    scale_y = dst_h / max(display_panel_rect.h, 1.0)
    region_left = int(round((display_analysis_rect.x - display_panel_rect.x) * scale_x))
    region_top = int(round((display_analysis_rect.y - display_panel_rect.y) * scale_y))
    region_w = max(1, int(round(display_analysis_rect.w * scale_x)))
    region_h = max(1, int(round(display_analysis_rect.h * scale_y)))

    # 1. Upscale background to display resolution.
    bg_img = Image.fromarray(background, mode="RGBA")
    if bg_img.size != (region_w, region_h):
        bg_img = bg_img.resize((region_w, region_h), resample=Image.Resampling.LANCZOS)
    # Composite onto white base.
    base = Image.new("RGBA", (dst_w, dst_h), (255, 255, 255, 255))
    frame_arr = np.array(base, dtype=np.uint8)
    bg_region = Image.alpha_composite(
        Image.new("RGBA", (region_w, region_h), (255, 255, 255, 255)),
        bg_img,
    )
    bg_arr = np.array(bg_region, dtype=np.uint8)
    region_bottom = min(dst_h, region_top + bg_arr.shape[0])
    region_right = min(dst_w, region_left + bg_arr.shape[1])
    frame_arr[
        region_top:region_bottom,
        region_left:region_right,
    ] = bg_arr[: region_bottom - region_top, : region_right - region_left]

    # 2. Draw boundary contours directly on the pixel array.
    for boundary in boundaries:
        local_boundary_mask = _find_boundary_at_size(boundary.coverage, region_w, region_h)
        boundary_mask = np.zeros((dst_h, dst_w), dtype=bool)
        boundary_mask[
            region_top:region_bottom,
            region_left:region_right,
        ] = local_boundary_mask[: region_bottom - region_top, : region_right - region_left]
        _draw_boundary_on_frame(
            frame_arr,
            boundary_mask,
            boundary.color,
            boundary.radius,
            dashed=boundary.dashed,
        )

    # 3. Composite keyboard overlay (outlines + labels, transparent background).
    overlay_img = Image.fromarray(keyboard_overlay_rgba, mode="RGBA")
    result = Image.alpha_composite(Image.fromarray(frame_arr, mode="RGBA"), overlay_img)
    return np.asarray(result)


def draw_raster_boundary(
    *,
    ax: plt.Axes,
    alpha: np.ndarray,
    analysis_rect: gkp.Rect,
    color: tuple[float, float, float, float],
    linewidth: float,
    linestyle: str | tuple[float, tuple[float, ...]],
    zorder: float,
    panel: object,
) -> None:
    alpha_float = alpha.astype(np.float32)
    if float(alpha_float.max()) <= 0.0:
        return

    x, y = image_axes(analysis_rect, alpha_float)
    contour = ax.contour(
        x,
        y,
        alpha_float,
        levels=[127.5],
        colors=[color],
        linewidths=[linewidth],
        linestyles=[linestyle],
        zorder=zorder,
    )
    if hasattr(contour, "set_clip_path"):
        contour.set_clip_path(panel)
    for collection in getattr(contour, "collections", []):
        collection.set_clip_path(panel)


def mask_overlap_metrics(session_mask: np.ndarray, ground_truth_mask: np.ndarray) -> dict[str, float | int]:
    session_pixels = int(np.count_nonzero(session_mask))
    ground_truth_pixels = int(np.count_nonzero(ground_truth_mask))
    intersection_pixels = int(np.count_nonzero(session_mask & ground_truth_mask))
    union_pixels = int(np.count_nonzero(session_mask | ground_truth_mask))
    iou = float(intersection_pixels / union_pixels) if union_pixels else 1.0
    overlap_loss = 1.0 - iou
    area_delta = float(abs(session_pixels - ground_truth_pixels) / ground_truth_pixels) if ground_truth_pixels else 0.0
    return {
        "session_pixels": session_pixels,
        "ground_truth_pixels": ground_truth_pixels,
        "intersection_pixels": intersection_pixels,
        "union_pixels": union_pixels,
        "iou": iou,
        "overlap_loss": overlap_loss,
        "area_delta": area_delta,
    }


def ensure_valid_keys(requested_keys: list[str] | None) -> list[str]:
    if not requested_keys:
        return list(gkp.ALL_KEYS)

    canonical: list[str] = []
    invalid: list[str] = []
    for raw in requested_keys:
        key = raw.strip().lower()
        if key in gkp.VALID_KEYS:
            canonical.append(key)
        else:
            invalid.append(raw)

    if invalid:
        raise SystemExit(f"Unknown keys: {', '.join(invalid)}")
    return canonical


def build_snapshots(
    *,
    events: list[gkp.Event],
    sample_x: np.ndarray,
    sample_y: np.ndarray,
    frames: dict[str, gkp.Rect],
) -> tuple[list[Snapshot], Snapshot]:
    grouped = grouped_session_events(events)
    if not grouped:
        raise SystemExit("No grouped session events were available after filtering.")

    session_ids = sorted(grouped)
    cumulative_events: list[gkp.Event] = []
    visible_trials: set[tuple[int, int]] = set()
    total_trial_count = len({trial_identity(event) for event in events})
    snapshots: list[Snapshot] = []

    for count, session_id in enumerate(session_ids, start=1):
        current_events = grouped[session_id]
        cumulative_events.extend(current_events)
        visible_trials.update(trial_identity(event) for event in current_events)
        cumulative_samples = gkp.training_samples(cumulative_events)
        model, _, _ = gkp.fit_model(
            cumulative_samples,
            fitted_source=gkp.SOURCE_FITTED_CUMULATIVE,
        )
        snapshots.append(
            Snapshot(
                latest_session=session_id + 1,
                visible_sessions=session_ids[:count],
                visible_trial_count=len(visible_trials),
                total_trial_count=total_trial_count,
                model=model,
                winner_indices=winner_indices_for_model(
                    sample_x=sample_x,
                    sample_y=sample_y,
                    frames=frames,
                    model=model,
                ),
            )
        )

    classic_events = [event for event in events if event.session_mode == "classic"]
    if not classic_events:
        raise SystemExit("No classic-only events were available for the ground-truth model.")

    classic_samples = gkp.training_samples(classic_events)
    classic_model, _, _ = gkp.fit_model(classic_samples)
    classic_trial_count = len({trial_identity(event) for event in classic_events})
    ground_truth = Snapshot(
        latest_session=max(session_ids) + 1,
        visible_sessions=sorted({event.study_session_index for event in classic_events}),
        visible_trial_count=classic_trial_count,
        total_trial_count=classic_trial_count,
        model=classic_model,
        winner_indices=winner_indices_for_model(
            sample_x=sample_x,
            sample_y=sample_y,
            frames=frames,
            model=classic_model,
        ),
    )
    return snapshots, ground_truth


def render_key_frames(
    *,
    snapshots: list[Snapshot],
    ground_truth: Snapshot,
    selected_keys: list[str],
    panel_rect: gkp.Rect,
    analysis_rect: gkp.Rect,
    layout: SamplingLayout,
    frames: dict[str, gkp.Rect],
    raster_step: float,
    output_dir: Path,
    output_format: str,
    dpi: float,
    # Separate display-only frames/rect for keyboard UI (scaled).
    # analysis_rect and frames must be in the SAME coordinate system as the
    # Gaussian training data so that winner-map boundaries are correct.
    # display_panel_rect and display_frames are used only for the matplotlib
    # axes, key-outline rendering, and imshow extent.
    display_panel_rect: gkp.Rect | None = None,
    display_analysis_rect: gkp.Rect | None = None,
    display_frames: dict[str, gkp.Rect] | None = None,
    badge_gap_px: float = 0.0,
) -> list[dict[str, str | int]]:
    # Fall back to analysis_rect / frames when no separate display geometry.
    if display_panel_rect is None:
        display_panel_rect = panel_rect
    if display_analysis_rect is None:
        display_analysis_rect = display_panel_rect
    if display_frames is None:
        display_frames = frames

    manifest_rows: list[dict[str, str | int]] = []

    # Build full RGBA backgrounds from pre-computed winner_indices stored in each
    # Snapshot, avoiding a redundant winner_indices_grid call per snapshot.
    final_full_background = rendered_full_winner_map_rgba_from_snapshot(
        snapshot=ground_truth,
        analysis_rect=analysis_rect,
        layout=layout,
    )
    current_full_backgrounds = [
        rendered_full_winner_map_rgba_from_snapshot(
            snapshot=snapshot,
            analysis_rect=analysis_rect,
            layout=layout,
        )
        for snapshot in snapshots
    ]

    # Pre-render the static keyboard overlay (panel + key outlines + labels +
    # panel outline) once; composite it on every frame with PIL instead of
    # re-drawing ~30 matplotlib patches and text objects per frame.
    keyboard_overlay_rgba: np.ndarray | None = None
    if display_panel_rect is not None and display_frames is not None:
        keyboard_overlay_rgba = render_keyboard_overlay_rgba(
            export_rect=display_panel_rect,
            keyboard_panel_rect=display_analysis_rect,
            display_frames=display_frames,
            dpi=dpi,
        )
    for key in selected_keys:
        key_dir = output_dir / key
        key_dir.mkdir(parents=True, exist_ok=True)
        key_index = gkp.ALL_KEYS.index(key)
        final_coverage = selected_key_coverage_alpha(
            winner_indices=ground_truth.winner_indices,
            key_index=key_index,
            analysis_rect=analysis_rect,
            layout=layout,
        )
        final_background = isolate_pixels_from_full_render(
            full_background=final_full_background,
            coverage_alpha=final_coverage,
        )
        kr, kg, kb = key_rgb(key)
        key_color_rgba = (int(kr * 255), int(kg * 255), int(kb * 255), 250)
        dark_color_rgba = (
            int(key_color_rgba[0] * 0.45),
            int(key_color_rgba[1] * 0.45),
            int(key_color_rgba[2] * 0.45),
            key_color_rgba[3],
        )

        for frame_index, current_snapshot in enumerate(snapshots):
            current_coverage = selected_key_coverage_alpha(
                winner_indices=current_snapshot.winner_indices,
                key_index=key_index,
                analysis_rect=analysis_rect,
                layout=layout,
            )
            background = isolate_pixels_from_full_render(
                full_background=current_full_backgrounds[frame_index],
                coverage_alpha=current_coverage,
            )

            stage = f"session_{current_snapshot.latest_session:02d}"
            badge_title, badge_detail = frame_badge_lines(
                title=display_key_label(key),
                snapshot=current_snapshot,
            )

            # Fast PIL path for PNG: skip matplotlib figure creation entirely.
            # Boundary finding + compositing in numpy/PIL is ~10-20× faster than
            # ax.contour + fig.canvas.draw() + plt.close().
            if keyboard_overlay_rgba is not None and output_format == "png":
                frame_rgba = make_frame_rgba_pil(
                    background=background,
                    keyboard_overlay_rgba=keyboard_overlay_rgba,
                    boundaries=[
                        PixelBoundary(
                            coverage=final_coverage,
                            color=dark_color_rgba,
                            radius=3,
                        ),
                        PixelBoundary(
                            coverage=current_coverage,
                            color=key_color_rgba,
                            radius=3,
                            dashed=True,
                        ),
                    ],
                    display_panel_rect=display_panel_rect,
                    display_analysis_rect=display_analysis_rect,
                )
                frame_rgba = annotate_frame_rgba(
                    frame_rgba=frame_rgba,
                    title=badge_title,
                    detail=badge_detail,
                    badge_region_top_px=0,
                    badge_region_bottom_px=max(
                        1,
                        int(
                            round(
                                (
                                    (display_analysis_rect.y - display_panel_rect.y)
                                    / max(display_panel_rect.h, 1.0)
                                )
                                * frame_rgba.shape[0]
                            )
                        ),
                    ),
                )
                png_path = key_dir / f"frame_{frame_index:02d}_{stage}.png"
                Image.fromarray(frame_rgba, mode="RGBA").convert("RGB").save(png_path)
                manifest_rows.append(
                    {
                        "key": key,
                        "frame_index": frame_index,
                        "latest_session": current_snapshot.latest_session,
                        "visible_sessions": visible_session_label(current_snapshot.visible_sessions),
                        "path": str(png_path),
                    }
                )
                continue

            # SVG / both: fall through to matplotlib (vector output requires it).
            export_rect = display_panel_rect
            keyboard_panel_rect = display_analysis_rect
            fig, ax = configure_axes(panel_rect=export_rect, dpi=dpi)
            panel, outline = panel_patches(ax, keyboard_panel_rect)

            img_obj = ax.imshow(
                background,
                extent=(
                    keyboard_panel_rect.x,
                    keyboard_panel_rect.x + keyboard_panel_rect.w,
                    keyboard_panel_rect.y + keyboard_panel_rect.h,
                    keyboard_panel_rect.y,
                ),
                interpolation="bilinear",
                zorder=1.5,
            )
            img_obj.set_clip_path(panel)
            draw_raster_boundary(
                ax=ax,
                alpha=final_coverage,
                analysis_rect=display_analysis_rect,
                color=(0.0, 0.0, 0.0, 0.98),
                linewidth=2.2,
                linestyle="solid",
                zorder=3.0,
                panel=panel,
            )
            draw_raster_boundary(
                ax=ax,
                alpha=current_coverage,
                analysis_rect=display_analysis_rect,
                color=(*key_rgb(key), 0.98),
                linewidth=2.1,
                linestyle=(0, (3.0, 2.0)),
                zorder=3.2,
                panel=panel,
            )
            if keyboard_overlay_rgba is not None:
                ax.imshow(
                    keyboard_overlay_rgba,
                    extent=(
                        export_rect.x,
                        export_rect.x + export_rect.w,
                        export_rect.y + export_rect.h,
                        export_rect.y,
                    ),
                    interpolation="nearest",
                    zorder=4.0,
                )
            else:
                render_keyboard_base(ax, display_frames)
                ax.add_patch(outline)
            draw_frame_badge(
                ax=ax,
                export_rect=export_rect,
                keyboard_panel_rect=keyboard_panel_rect,
                badge_gap_px=badge_gap_px,
                title=badge_title,
                detail=badge_detail,
            )

            saved_paths = save_frame(
                output_dir=key_dir,
                frame_index=frame_index,
                stage=stage,
                output_format=output_format,
                fig=fig,
                dpi=dpi,
                frame_rgba=None,
            )
            plt.close(fig)

            for saved_path in saved_paths:
                manifest_rows.append(
                    {
                        "key": key,
                        "frame_index": frame_index,
                        "latest_session": current_snapshot.latest_session,
                        "visible_sessions": visible_session_label(current_snapshot.visible_sessions),
                        "path": str(saved_path),
                    }
                )

    return manifest_rows


def render_letter_overview_frames(
    *,
    snapshots: list[Snapshot],
    ground_truth: Snapshot,
    panel_rect: gkp.Rect,
    analysis_rect: gkp.Rect,
    layout: SamplingLayout,
    frames: dict[str, gkp.Rect],
    output_dir: Path,
    output_format: str,
    dpi: float,
    display_panel_rect: gkp.Rect | None = None,
    display_analysis_rect: gkp.Rect | None = None,
    display_frames: dict[str, gkp.Rect] | None = None,
    badge_gap_px: float = 0.0,
) -> list[dict[str, str | int]]:
    if display_panel_rect is None:
        display_panel_rect = panel_rect
    if display_analysis_rect is None:
        display_analysis_rect = display_panel_rect
    if display_frames is None:
        display_frames = frames

    manifest_rows: list[dict[str, str | int]] = []
    overview_dir = output_dir / "whole_keyboard"
    overview_dir.mkdir(parents=True, exist_ok=True)
    overview_keys = list(gkp.ALL_KEYS)
    overview_indices = [gkp.ALL_KEYS.index(key) for key in overview_keys]

    final_coverages = {
        key: selected_key_coverage_alpha(
            winner_indices=ground_truth.winner_indices,
            key_index=gkp.ALL_KEYS.index(key),
            analysis_rect=analysis_rect,
            layout=layout,
        )
        for key in overview_keys
    }
    current_full_backgrounds = [
        rendered_full_winner_map_rgba_from_snapshot(
            snapshot=snapshot,
            analysis_rect=analysis_rect,
            layout=layout,
        )
        for snapshot in snapshots
    ]

    keyboard_overlay_rgba: np.ndarray | None = None
    if display_panel_rect is not None and display_frames is not None:
        keyboard_overlay_rgba = render_keyboard_overlay_rgba(
            export_rect=display_panel_rect,
            keyboard_panel_rect=display_analysis_rect,
            display_frames=display_frames,
            dpi=dpi,
        )

    for frame_index, current_snapshot in enumerate(snapshots):
        stage = f"session_{current_snapshot.latest_session:02d}"
        current_background = isolate_pixels_from_full_render(
            full_background=current_full_backgrounds[frame_index],
            coverage_alpha=selected_key_indices_coverage_alpha(
                winner_indices=current_snapshot.winner_indices,
                key_indices=overview_indices,
                analysis_rect=analysis_rect,
                layout=layout,
            ),
        )
        badge_title, badge_detail = frame_badge_lines(
            title="Whole Keyboard",
            snapshot=current_snapshot,
        )

        current_coverages = {
            key: selected_key_coverage_alpha(
                winner_indices=current_snapshot.winner_indices,
                key_index=gkp.ALL_KEYS.index(key),
                analysis_rect=analysis_rect,
                layout=layout,
            )
            for key in overview_keys
        }

        if keyboard_overlay_rgba is not None and output_format == "png":
            boundaries: list[PixelBoundary] = []
            for key in overview_keys:
                kr, kg, kb = key_rgb(key)
                key_color_rgba = (int(kr * 255), int(kg * 255), int(kb * 255), 250)
                dark_color_rgba = (
                    int(key_color_rgba[0] * 0.45),
                    int(key_color_rgba[1] * 0.45),
                    int(key_color_rgba[2] * 0.45),
                    key_color_rgba[3],
                )
                boundaries.append(
                    PixelBoundary(
                        coverage=final_coverages[key],
                        color=dark_color_rgba,
                        radius=2,
                    )
                )
                boundaries.append(
                    PixelBoundary(
                        coverage=current_coverages[key],
                        color=key_color_rgba,
                        radius=2,
                        dashed=True,
                    )
                )
            frame_rgba = make_frame_rgba_pil(
                background=current_background,
                keyboard_overlay_rgba=keyboard_overlay_rgba,
                boundaries=boundaries,
                display_panel_rect=display_panel_rect,
                display_analysis_rect=display_analysis_rect,
            )
            frame_rgba = annotate_frame_rgba(
                frame_rgba=frame_rgba,
                title=badge_title,
                detail=badge_detail,
                badge_region_top_px=0,
                badge_region_bottom_px=max(
                    1,
                    int(
                        round(
                            (
                                (display_analysis_rect.y - display_panel_rect.y)
                                / max(display_panel_rect.h, 1.0)
                            )
                            * frame_rgba.shape[0]
                        )
                    ),
                ),
            )
            png_path = overview_dir / f"frame_{frame_index:02d}_{stage}.png"
            Image.fromarray(frame_rgba, mode="RGBA").convert("RGB").save(png_path)
            manifest_rows.append(
                {
                    "key": "whole_keyboard",
                    "frame_index": frame_index,
                    "latest_session": current_snapshot.latest_session,
                    "visible_sessions": visible_session_label(current_snapshot.visible_sessions),
                    "path": str(png_path),
                }
            )
            continue

        export_rect = display_panel_rect
        keyboard_panel_rect = display_analysis_rect
        fig, ax = configure_axes(panel_rect=export_rect, dpi=dpi)
        panel, outline = panel_patches(ax, keyboard_panel_rect)

        img_obj = ax.imshow(
            current_background,
            extent=(
                keyboard_panel_rect.x,
                keyboard_panel_rect.x + keyboard_panel_rect.w,
                keyboard_panel_rect.y + keyboard_panel_rect.h,
                keyboard_panel_rect.y,
            ),
            interpolation="bilinear",
            zorder=1.5,
        )
        img_obj.set_clip_path(panel)
        for key in overview_keys:
            kr, kg, kb = key_rgb(key)
            draw_raster_boundary(
                ax=ax,
                alpha=final_coverages[key],
                analysis_rect=display_analysis_rect,
                color=(kr * 0.45, kg * 0.45, kb * 0.45, 0.98),
                linewidth=1.45,
                linestyle="solid",
                zorder=3.0,
                panel=panel,
            )
            draw_raster_boundary(
                ax=ax,
                alpha=current_coverages[key],
                analysis_rect=display_analysis_rect,
                color=(kr, kg, kb, 0.98),
                linewidth=1.3,
                linestyle=(0, (3.0, 2.0)),
                zorder=3.2,
                panel=panel,
            )
        if keyboard_overlay_rgba is not None:
            ax.imshow(
                keyboard_overlay_rgba,
                extent=(
                    export_rect.x,
                    export_rect.x + export_rect.w,
                    export_rect.y + export_rect.h,
                    export_rect.y,
                ),
                interpolation="nearest",
                zorder=4.0,
            )
        else:
            render_keyboard_base(ax, display_frames)
            ax.add_patch(outline)
        draw_frame_badge(
            ax=ax,
            export_rect=export_rect,
            keyboard_panel_rect=keyboard_panel_rect,
            badge_gap_px=badge_gap_px,
            title=badge_title,
            detail=badge_detail,
        )

        saved_paths = save_frame(
            output_dir=overview_dir,
            frame_index=frame_index,
            stage=stage,
            output_format=output_format,
            fig=fig,
            dpi=dpi,
            frame_rgba=None,
        )
        plt.close(fig)

        for saved_path in saved_paths:
            manifest_rows.append(
                {
                    "key": "whole_keyboard",
                    "frame_index": frame_index,
                    "latest_session": current_snapshot.latest_session,
                    "visible_sessions": visible_session_label(current_snapshot.visible_sessions),
                    "path": str(saved_path),
                }
            )

    return manifest_rows


def assemble_mp4_from_frames(
    *,
    frame_dir: Path,
    output_path: Path,
    fps: float,
) -> bool:
    ffmpeg_bin = shutil.which("ffmpeg")
    if ffmpeg_bin is None:
        return False

    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            [
                ffmpeg_bin,
                "-y",
                "-loglevel",
                "error",
                "-framerate",
                f"{max(float(fps), 0.25):g}",
                "-pattern_type",
                "glob",
                "-i",
                "frame_*.png",
                "-vf",
                "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                str(output_path),
            ],
            cwd=frame_dir,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return False
    return output_path.exists()


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, str | int | float]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def format_elapsed(seconds: float) -> str:
    total_seconds = max(0.0, float(seconds))
    minutes, remaining_seconds = divmod(total_seconds, 60.0)
    hours, remaining_minutes = divmod(int(minutes), 60)
    if hours:
        return f"{hours}h {remaining_minutes}m {remaining_seconds:.1f}s"
    if minutes >= 1:
        return f"{int(minutes)}m {remaining_seconds:.1f}s"
    return f"{total_seconds:.2f}s"


def main() -> None:
    start = time.perf_counter()
    started_at = datetime.now().astimezone()
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.demo:
        csv_path = output_dir / "synthetic_key_session_boundary_video_input.csv"
        write_demo_csv(csv_path)
    elif args.csv_path:
        csv_path = Path(args.csv_path).resolve()
    else:
        raise SystemExit("Provide a CSV path or use --demo.")

    selected_keys = ensure_valid_keys(args.keys)
    gkp.RASTER_STEP = max(float(args.raster_step), 1.0)

    events, participant = gkp.read_events(csv_path)
    if not events:
        raise SystemExit(f"No usable events found in {csv_path}")

    base_panel_rect, base_frames = gkp.build_svg_panel_and_frames()
    scale = max(float(args.scale), 0.5)

    # --- display geometry (scaled, with header space reserved for the badge) ---
    render_dpi = max(float(args.dpi), 72.0)
    display_panel_rect, display_analysis_rect, display_frames, badge_gap_px = build_display_geometry(
        base_panel_rect=base_panel_rect,
        base_frames=base_frames,
        scale=scale,
        dpi=render_dpi,
    )

    # --- evaluation geometry (scale=1.0, matching reference PDF pipeline) ---
    # Gaussian model parameters are in phone-pixel units that match the
    # unscaled PDF key dimensions.  Using scaled panel coordinates inflates dx
    # relative to mu_x/mu_y, causing fitted neighbour keys to score artificially
    # low and letting fallback-Gaussian keys steal their territory.  We therefore
    # evaluate all winner maps and raster backgrounds in the original (scale=1.0)
    # coordinate system and only use the scaled geometry for display.
    eval_panel_rect = base_panel_rect
    eval_frames = base_frames
    eval_raster_step = gkp.RASTER_STEP

    analysis_rect = eval_panel_rect
    sample_x, sample_y, layout = build_sampling_grid(analysis_rect, eval_raster_step)
    snapshots, ground_truth = build_snapshots(
        events=events,
        sample_x=sample_x,
        sample_y=sample_y,
        frames=eval_frames,
    )
    # panel_rect alias keeps the rest of the summary/metrics code unchanged.
    panel_rect = display_panel_rect
    frames = display_frames

    ground_truth_masks = {
        key: ground_truth.winner_indices == gkp.ALL_KEYS.index(key)
        for key in gkp.ALL_KEYS
    }

    by_session_rows: list[dict[str, str | int | float]] = []
    summary_rows: list[dict[str, str | int | float]] = []

    for key in gkp.ALL_KEYS:
        per_session_metrics: list[dict[str, float | int]] = []
        ground_truth_mask = ground_truth_masks[key]
        for snapshot in snapshots:
            session_mask = snapshot.winner_indices == gkp.ALL_KEYS.index(key)
            metrics = mask_overlap_metrics(session_mask, ground_truth_mask)
            metrics["latest_session"] = snapshot.latest_session
            per_session_metrics.append(metrics)
            by_session_rows.append(
                {
                    "key": key,
                    "latest_session": snapshot.latest_session,
                    "visible_sessions": visible_session_label(snapshot.visible_sessions),
                    "session_pixels": metrics["session_pixels"],
                    "ground_truth_pixels": metrics["ground_truth_pixels"],
                    "intersection_pixels": metrics["intersection_pixels"],
                    "union_pixels": metrics["union_pixels"],
                    "iou": f"{metrics['iou']:.6f}",
                    "overlap_loss": f"{metrics['overlap_loss']:.6f}",
                    "area_delta": f"{metrics['area_delta']:.6f}",
                }
            )

        if not per_session_metrics:
            continue

        max_entry = max(per_session_metrics, key=lambda row: float(row["overlap_loss"]))
        final_entry = per_session_metrics[-1]
        mean_overlap_loss = sum(float(row["overlap_loss"]) for row in per_session_metrics) / len(per_session_metrics)
        mean_iou = sum(float(row["iou"]) for row in per_session_metrics) / len(per_session_metrics)
        summary_rows.append(
            {
                "key": key,
                "max_overlap_loss": f"{float(max_entry['overlap_loss']):.6f}",
                "max_overlap_session": int(max_entry["latest_session"]),
                "mean_overlap_loss": f"{mean_overlap_loss:.6f}",
                "final_overlap_loss": f"{float(final_entry['overlap_loss']):.6f}",
                "mean_iou": f"{mean_iou:.6f}",
                "final_iou": f"{float(final_entry['iou']):.6f}",
                "ground_truth_pixels": int(final_entry["ground_truth_pixels"]),
            }
        )

    summary_rows.sort(key=lambda row: float(row["max_overlap_loss"]), reverse=True)
    if not summary_rows:
        raise SystemExit("No summary rows were produced.")

    largest_difference_key = str(summary_rows[0]["key"])
    top_n = min(5, len(summary_rows))
    lines: list[str] = [f"top_{top_n}_keys_by_max_overlap_loss"]
    for rank, row in enumerate(summary_rows[:top_n], start=1):
        lines += [
            f"",
            f"rank={rank}",
            f"key={row['key']}",
            f"max_overlap_loss={row['max_overlap_loss']}",
            f"max_overlap_session={row['max_overlap_session']}",
            f"mean_overlap_loss={row['mean_overlap_loss']}",
            f"final_overlap_loss={row['final_overlap_loss']}",
        ]
    (output_dir / "largest_difference_key.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    manifest_rows: list[dict[str, str | int]] = []
    frames_root = output_dir / "frames"
    frames_root.mkdir(parents=True, exist_ok=True)
    manifest_rows.extend(
        render_key_frames(
            snapshots=snapshots,
            ground_truth=ground_truth,
            selected_keys=selected_keys,
            panel_rect=eval_panel_rect,
            analysis_rect=eval_panel_rect,
            layout=layout,
            frames=eval_frames,
            raster_step=eval_raster_step,
            output_dir=frames_root,
            output_format=args.format,
            dpi=render_dpi,
            display_panel_rect=display_panel_rect,
            display_analysis_rect=display_analysis_rect,
            display_frames=display_frames,
            badge_gap_px=badge_gap_px,
        )
    )
    whole_keyboard_video_path: Path | None = None
    video_status = "not requested"
    if not args.skip_letter_overview:
        manifest_rows.extend(
            render_letter_overview_frames(
                snapshots=snapshots,
                ground_truth=ground_truth,
                panel_rect=eval_panel_rect,
                analysis_rect=eval_panel_rect,
                layout=layout,
                frames=eval_frames,
                output_dir=frames_root,
                output_format=args.format,
                dpi=render_dpi,
                display_panel_rect=display_panel_rect,
                display_analysis_rect=display_analysis_rect,
                display_frames=display_frames,
                badge_gap_px=badge_gap_px,
            )
        )
        video_status = "skipped (--skip-video)"
        if args.format not in {"png", "both"}:
            video_status = "skipped (PNG frames required)"
        elif not args.skip_video:
            candidate_video_path = output_dir / "videos" / "whole_keyboard_boundary.mp4"
            if assemble_mp4_from_frames(
                frame_dir=frames_root / "whole_keyboard",
                output_path=candidate_video_path,
                fps=args.fps,
            ):
                whole_keyboard_video_path = candidate_video_path
                video_status = f"created ({candidate_video_path.relative_to(output_dir)})"
            else:
                video_status = "skipped (ffmpeg unavailable or encode failed)"

    write_csv(
        output_dir / "key_boundary_overlap_summary.csv",
        [
            "key",
            "max_overlap_loss",
            "max_overlap_session",
            "mean_overlap_loss",
            "final_overlap_loss",
            "mean_iou",
            "final_iou",
            "ground_truth_pixels",
        ],
        summary_rows,
    )
    write_csv(
        output_dir / "key_boundary_overlap_by_session.csv",
        [
            "key",
            "latest_session",
            "visible_sessions",
            "session_pixels",
            "ground_truth_pixels",
            "intersection_pixels",
            "union_pixels",
            "iou",
            "overlap_loss",
            "area_delta",
        ],
        by_session_rows,
    )
    write_csv(
        output_dir / "key_boundary_frame_manifest.csv",
        ["key", "frame_index", "latest_session", "visible_sessions", "path"],
        manifest_rows,
    )

    session_labels = ", ".join(str(snapshot.latest_session) for snapshot in snapshots)
    print(f"Input CSV: {csv_path}")
    print(f"Output dir: {output_dir}")
    print(f"Participant: {participant or '(unknown)'}")
    print(f"Sessions rendered: {session_labels}")
    print(f"Keys exported: {', '.join(selected_keys)}")
    print(f"Largest-difference key: {largest_difference_key}")
    print("Primary outputs:")
    print("  - key_boundary_overlap_summary.csv")
    print("  - key_boundary_overlap_by_session.csv")
    print("  - key_boundary_frame_manifest.csv")
    print("  - largest_difference_key.txt")
    print("  - frames/<key>/frame_XX_*")
    if not args.skip_letter_overview:
        print("  - frames/whole_keyboard/frame_XX_*")
    if whole_keyboard_video_path is not None:
        print(f"  - {whole_keyboard_video_path.relative_to(output_dir)}")
        print(f"Whole-keyboard video: {whole_keyboard_video_path}")
    elif not args.skip_letter_overview:
        print(f"Whole-keyboard video: {video_status}")
    finished_at = datetime.now().astimezone()
    elapsed_seconds = time.perf_counter() - start
    print(f"Started: {started_at.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"Finished: {finished_at.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"Elapsed: {format_elapsed(elapsed_seconds)}")


if __name__ == "__main__":
    main()
