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
"""

from __future__ import annotations

import argparse
import csv
import math
import os
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
from PIL import Image

import gaussian_keyboard_pdf as gkp

ISOLATED_FILL_ALPHA = 224
WHITE_RGBA = np.array([255, 255, 255, 255], dtype=np.uint8)


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
        default=160.0,
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


def visible_session_label(session_ids: list[int]) -> str:
    return ",".join(str(session_id + 1) for session_id in session_ids)


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
                fontsize=max(9, frame.h * 0.255),
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
                fontsize=7.5,
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
                fontsize=7.5,
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
) -> list[Path]:
    saved: list[Path] = []
    wants_png = output_format in {"png", "both"}
    wants_svg = output_format in {"svg", "both"}

    if wants_png:
        png_path = output_dir / f"frame_{frame_index:02d}_{stage}.png"
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
    winner_mask = winner_indices == key_index
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
    snapshots: list[Snapshot] = []

    for count, session_id in enumerate(session_ids, start=1):
        current_events = grouped[session_id]
        cumulative_events.extend(current_events)
        cumulative_samples = gkp.training_samples(cumulative_events)
        model, _, _ = gkp.fit_model(
            cumulative_samples,
            fitted_source=gkp.SOURCE_FITTED_CUMULATIVE,
        )
        snapshots.append(
            Snapshot(
                latest_session=session_id + 1,
                visible_sessions=session_ids[:count],
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
    ground_truth = Snapshot(
        latest_session=max(session_ids) + 1,
        visible_sessions=sorted({event.study_session_index for event in classic_events}),
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
    display_frames: dict[str, gkp.Rect] | None = None,
) -> list[dict[str, str | int]]:
    # Fall back to analysis_rect / frames when no separate display geometry.
    if display_panel_rect is None:
        display_panel_rect = panel_rect
    if display_frames is None:
        display_frames = frames

    manifest_rows: list[dict[str, str | int]] = []
    final_full_background = rendered_full_winner_map_rgba(
        analysis_rect=analysis_rect,
        frames=frames,
        model=ground_truth.model,
        raster_step=raster_step,
    )
    current_full_backgrounds = [
        rendered_full_winner_map_rgba(
            analysis_rect=analysis_rect,
            frames=frames,
            model=snapshot.model,
            raster_step=raster_step,
        )
        for snapshot in snapshots
    ]
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
        for frame_index, current_snapshot in enumerate(snapshots):
            fig, ax = configure_axes(panel_rect=display_panel_rect, dpi=dpi)
            panel, outline = panel_patches(ax, display_panel_rect)
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
            # The background RGBA and coverage_alpha were computed in
            # analysis_rect coordinates (eval space).  Stretch them to fill
            # display_panel_rect so that the key-outline overlay aligns.
            image = ax.imshow(
                background,
                extent=(
                    display_panel_rect.x,
                    display_panel_rect.x + display_panel_rect.w,
                    display_panel_rect.y + display_panel_rect.h,
                    display_panel_rect.y,
                ),
                interpolation="bilinear",
                zorder=1.5,
            )
            image.set_clip_path(panel)
            # Boundary contours: pass display_panel_rect as analysis_rect so
            # contour x/y axes span the display coordinate space.
            draw_raster_boundary(
                ax=ax,
                alpha=final_coverage,
                analysis_rect=display_panel_rect,
                color=(0.0, 0.0, 0.0, 0.98),
                linewidth=2.2,
                linestyle="solid",
                zorder=3.0,
                panel=panel,
            )
            draw_raster_boundary(
                ax=ax,
                alpha=current_coverage,
                analysis_rect=display_panel_rect,
                color=(*key_rgb(key), 0.98),
                linewidth=2.1,
                linestyle=(0, (3.0, 2.0)),
                zorder=3.2,
                panel=panel,
            )
            render_keyboard_base(ax, display_frames)
            ax.add_patch(outline)

            stage = f"session_{current_snapshot.latest_session:02d}"
            saved_paths = save_frame(
                output_dir=key_dir,
                frame_index=frame_index,
                stage=stage,
                output_format=output_format,
                fig=fig,
                dpi=dpi,
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

    # --- display geometry (scaled, for matplotlib panel / key outlines) ---
    display_panel_rect = gkp.Rect(
        base_panel_rect.x * scale,
        base_panel_rect.y * scale,
        base_panel_rect.w * scale,
        base_panel_rect.h * scale,
    )
    display_frames = gkp.scale_frames(base_frames, scale)

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
    (output_dir / "largest_difference_key.txt").write_text(
        "\n".join(
            [
                f"key={largest_difference_key}",
                f"max_overlap_loss={summary_rows[0]['max_overlap_loss']}",
                f"max_overlap_session={summary_rows[0]['max_overlap_session']}",
                f"mean_overlap_loss={summary_rows[0]['mean_overlap_loss']}",
                f"final_overlap_loss={summary_rows[0]['final_overlap_loss']}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

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
            dpi=max(float(args.dpi), 72.0),
            display_panel_rect=display_panel_rect,
            display_frames=display_frames,
        )
    )

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
    finished_at = datetime.now().astimezone()
    elapsed_seconds = time.perf_counter() - start
    print(f"Started: {started_at.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"Finished: {finished_at.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print(f"Elapsed: {format_elapsed(elapsed_seconds)}")


if __name__ == "__main__":
    main()
