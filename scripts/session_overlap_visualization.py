#!/usr/bin/env python3
"""
Create per-session Gaussian keyboard boundary visuals.

This replaces the older session Jaccard and Gaussian-overlap overlays with a
session-by-session boundary view that matches the adaptive-keyboard logic more
closely.

For session N, the visualization builds a per-key model using this backoff
chain:

1. Fit a fresh Gaussian from the current session if that key has enough taps.
2. Otherwise borrow the most reliable cumulative model from prior sessions.
3. Otherwise fall back to the geometric key area.

The script writes one SVG per session, plus CSV summaries describing which keys
were current-session fits, borrowed from prior sessions, or still relying on
geometry fallback.
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
import math
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image


ROW0 = list("qwertyuiop")
ROW1 = list("asdfghjkl")
ROW2 = list("zxcvbnm")
ALL_KEYS = ROW0 + ROW1 + ROW2 + ["space", "delete"]
LETTER_KEYS = set(ROW0 + ROW1 + ROW2)
VALID_KEYS = set(ALL_KEYS)

WIDTH = 980
SIDE_PAD = 16
TOP_PAD = 18
KEY_GAP = 10
ROW_GAP = 22
KEY_H = 76
BOTTOM_PAD = 18
PANEL_MARGIN = 10
PANEL_RADIUS = 20
INNER_MARGIN_X = 14
INNER_MARGIN_Y = 14
HEIGHT = TOP_PAD + 4 * KEY_H + 3 * ROW_GAP + BOTTOM_PAD + 2 * (PANEL_MARGIN + INNER_MARGIN_Y)

MIN_SAMPLES = 5
RIDGE_FRAC = 0.05
ANCHOR_FRAC = 0.20
SPATIAL_PRIOR_FRAC = 0.40
RASTER_STEP = 2

SOURCE_FITTED_CURRENT = "fitted_current"
SOURCE_PRIOR_MODEL = "prior_model"
SOURCE_GEOMETRY_FALLBACK = "geometry_fallback"


@dataclass
class SessionEvent:
    session_index: int
    event_type: str
    key_label: str
    expected_char: str
    actual_char: str
    corrected_char: str
    is_correct: bool
    norm_x: float
    norm_y: float


@dataclass
class TrainingSample:
    target_key: str
    offset_x: float
    offset_y: float
    key_width: float
    key_height: float


@dataclass
class Gaussian2D:
    mu_x: float
    mu_y: float
    sxx: float
    syy: float
    sxy: float
    pxx: float
    pyy: float
    pxy: float
    log_det: float
    count: int

    def log_score(self, dx: float, dy: float) -> float:
        ux = dx - self.mu_x
        uy = dy - self.mu_y
        m2 = self.pxx * ux * ux + 2.0 * self.pxy * ux * uy + self.pyy * uy * uy
        return -0.5 * (m2 + self.log_det)


def key_color(key: str) -> str:
    semantic = {
        "q": "#FF6FB3",
        "w": "#5DA7FF",
        "e": "#FFE066",
        "r": "#7EE46F",
        "t": "#FFB15E",
        "y": "#FF6FB3",
        "u": "#5DA7FF",
        "i": "#FFE066",
        "o": "#7EE46F",
        "p": "#FFB15E",
        "a": "#FFE066",
        "s": "#FF6FB3",
        "d": "#5DA7FF",
        "f": "#FFB15E",
        "g": "#5DA7FF",
        "h": "#FF6FB3",
        "j": "#7EE46F",
        "k": "#FFB15E",
        "l": "#5DE0D1",
        "z": "#7EE46F",
        "x": "#FFE066",
        "c": "#5DE0D1",
        "v": "#5DA7FF",
        "b": "#FFB15E",
        "n": "#7EE46F",
        "m": "#C78BFF",
        "space": "#C9D2E6",
        "delete": "#F2C5D8",
    }
    return semantic.get(key, "#D1D5DB")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "csv_path",
        nargs="?",
        help="Cleaned keystroke CSV. Omit with --demo to generate synthetic data.",
    )
    parser.add_argument(
        "--output-dir",
        default="session_boundary_outputs",
        help="Directory for SVGs and CSV summaries.",
    )
    parser.add_argument(
        "--raster-step",
        "--gaussian-step",
        dest="raster_step",
        type=int,
        default=RASTER_STEP,
        help="Pixel step for the winner raster. Lower is smoother but larger.",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=MIN_SAMPLES,
        help="Minimum taps required for a session-specific key Gaussian.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate synthetic session data before rendering outputs.",
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


def svg_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def tap_norm(row: dict[str, str]) -> tuple[float, float]:
    if row.get("tap_norm_x") not in (None, "") and row.get("tap_norm_y") not in (None, ""):
        return safe_float(row.get("tap_norm_x"), 0.5), safe_float(row.get("tap_norm_y"), 0.5)

    width = safe_float(row.get("key_width"), 0)
    height = safe_float(row.get("key_height"), 0)
    x = safe_float(row.get("tap_local_x"), 0)
    y = safe_float(row.get("tap_local_y"), 0)
    return (x / width if width > 0 else 0.5), (y / height if height > 0 else 0.5)


def key_for_expected(raw: str) -> str | None:
    if raw == " ":
        return "space"
    key = raw.strip().lower()
    return key if key in VALID_KEYS else None


def event_chars(row: dict[str, str], event_type: str, key_label: str) -> tuple[str, str]:
    actual = row.get("actual_char", "")
    corrected = row.get("corrected_char", "")

    if event_type in {"insert", "replace"} and not actual:
        replacement = row.get("replacement_string", "")
        if replacement:
            actual = replacement[:1]
        elif key_label == "space":
            actual = " "
        elif len(key_label) == 1:
            actual = key_label

    if event_type != "delete":
        corrected = ""

    return actual, corrected


def keyboard_frames() -> dict[str, tuple[float, float, float, float]]:
    left = PANEL_MARGIN + INNER_MARGIN_X
    top = PANEL_MARGIN + INNER_MARGIN_Y
    usable_width = WIDTH - 2 * (PANEL_MARGIN + INNER_MARGIN_X)
    key_w = (usable_width - 2 * SIDE_PAD - 9 * KEY_GAP) / 10
    special_w = (usable_width - 2 * SIDE_PAD - 7 * key_w - 8 * KEY_GAP) / 2
    frames: dict[str, tuple[float, float, float, float]] = {}

    y0 = top + TOP_PAD
    for index, key in enumerate(ROW0):
        frames[key] = (left + SIDE_PAD + index * (key_w + KEY_GAP), y0, key_w, KEY_H)

    y1 = y0 + KEY_H + ROW_GAP
    row1_start = left + (usable_width - 9 * key_w - 8 * KEY_GAP) / 2
    for index, key in enumerate(ROW1):
        frames[key] = (row1_start + index * (key_w + KEY_GAP), y1, key_w, KEY_H)

    y2 = y1 + KEY_H + ROW_GAP
    row2_start = left + SIDE_PAD + special_w + KEY_GAP
    for index, key in enumerate(ROW2):
        frames[key] = (row2_start + index * (key_w + KEY_GAP), y2, key_w, KEY_H)

    frames["delete"] = (left + usable_width - SIDE_PAD - special_w, y2, special_w, KEY_H)
    y3 = y2 + KEY_H + ROW_GAP
    frames["space"] = (
        left + SIDE_PAD + special_w + KEY_GAP,
        y3,
        usable_width - 2 * SIDE_PAD - 2 * special_w - 2 * KEY_GAP,
        KEY_H,
    )
    return frames


def load_session_events(csv_path: Path) -> dict[int, list[SessionEvent]]:
    sessions: dict[int, list[SessionEvent]] = defaultdict(list)
    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            event_type = (row.get("event_type") or "insert").strip().lower()
            key_label = (row.get("key_label") or "").strip().lower()
            if key_label not in VALID_KEYS:
                continue

            flags = row.get("outlier_flags", "")
            if "spatial" in flags or "far_from_target" in flags:
                continue

            session_index = safe_int(row.get("study_session_index"), 1)
            if session_index >= 1:
                session_index -= 1

            norm_x, norm_y = tap_norm(row)
            actual_char, corrected_char = event_chars(row, event_type, key_label)
            sessions[session_index].append(
                SessionEvent(
                    session_index=session_index,
                    event_type=event_type,
                    key_label=key_label,
                    expected_char=row.get("expected_char", ""),
                    actual_char=actual_char,
                    corrected_char=corrected_char,
                    is_correct=row.get("is_correct", "") in {"1", "true", "True"},
                    norm_x=min(max(norm_x, -0.5), 1.5),
                    norm_y=min(max(norm_y, -0.5), 1.5),
                )
            )
    return dict(sorted(sessions.items()))


def sample_for(
    event: SessionEvent,
    target_key: str,
    frames: dict[str, tuple[float, float, float, float]],
) -> TrainingSample | None:
    hit = frames.get(event.key_label)
    target = frames.get(target_key)
    if hit is None or target is None:
        return None

    hit_x, hit_y, hit_w, hit_h = hit
    target_x, target_y, target_w, target_h = target
    absolute_x = hit_x + event.norm_x * hit_w
    absolute_y = hit_y + event.norm_y * hit_h
    return TrainingSample(
        target_key=target_key,
        offset_x=absolute_x - (target_x + target_w / 2.0),
        offset_y=absolute_y - (target_y + target_h / 2.0),
        key_width=target_w,
        key_height=target_h,
    )


def deleted_insert_indices(events: list[SessionEvent]) -> set[int]:
    stack: list[int] = []
    deleted: set[int] = set()
    for idx, event in enumerate(events):
        if event.event_type in {"insert", "replace"} and event.actual_char:
            stack.append(idx)
        elif event.event_type == "delete" and stack:
            removed_idx = stack.pop()
            if not event.corrected_char or event.corrected_char == events[removed_idx].actual_char:
                deleted.add(removed_idx)
    return deleted


def training_samples(
    events: list[SessionEvent],
    frames: dict[str, tuple[float, float, float, float]],
) -> list[TrainingSample]:
    deleted = deleted_insert_indices(events)
    samples: list[TrainingSample] = []
    for idx, event in enumerate(events):
        if event.event_type == "delete":
            if event.key_label == "delete":
                sample = sample_for(event, "delete", frames)
                if sample:
                    samples.append(sample)
            continue

        if event.event_type not in {"insert", "replace"}:
            continue

        intended = key_for_expected(event.expected_char)
        if intended:
            sample = sample_for(event, intended, frames)
        elif idx in deleted:
            continue
        elif event.is_correct:
            sample = sample_for(event, event.key_label, frames)
        else:
            sample = None

        if sample:
            samples.append(sample)
    return samples


def fit_single(samples: list[TrainingSample], min_samples: int) -> Gaussian2D | None:
    n = len(samples)
    if n < min_samples:
        return None

    ox = [sample.offset_x for sample in samples]
    oy = [sample.offset_y for sample in samples]
    mean_kw = sum(sample.key_width for sample in samples) / n
    mu_x = sum(ox) / n
    mu_y = sum(oy) / n

    denom = max(1, n - 1)
    sxx = sum((x - mu_x) ** 2 for x in ox) / denom
    syy = sum((y - mu_y) ** 2 for y in oy) / denom
    sxy = sum((ox[i] - mu_x) * (oy[i] - mu_y) for i in range(n)) / denom

    ridge = (RIDGE_FRAC * mean_kw) ** 2
    sxx += ridge
    syy += ridge

    det = sxx * syy - sxy * sxy
    if det <= 0:
        return None

    inv = 1.0 / det
    return Gaussian2D(
        mu_x=mu_x,
        mu_y=mu_y,
        sxx=sxx,
        syy=syy,
        sxy=sxy,
        pxx=syy * inv,
        pyy=sxx * inv,
        pxy=-sxy * inv,
        log_det=math.log(det),
        count=n,
    )


def fit_model(
    samples: list[TrainingSample],
    *,
    prior_model: dict[str, Gaussian2D] | None,
    min_samples: int,
) -> tuple[dict[str, Gaussian2D], dict[str, str], dict[str, int]]:
    grouped: dict[str, list[TrainingSample]] = defaultdict(list)
    for sample in samples:
        grouped[sample.target_key].append(sample)

    model: dict[str, Gaussian2D] = {}
    sources: dict[str, str] = {}
    sample_counts: dict[str, int] = {}

    for key in ALL_KEYS:
        key_samples = grouped.get(key, [])
        sample_counts[key] = len(key_samples)
        if (gaussian := fit_single(key_samples, min_samples)) is not None:
            model[key] = gaussian
            sources[key] = SOURCE_FITTED_CURRENT
        elif prior_model and key in prior_model:
            model[key] = prior_model[key]
            sources[key] = SOURCE_PRIOR_MODEL

    return model, sources, sample_counts


def fallback_gaussian(frame: tuple[float, float, float, float]) -> Gaussian2D:
    _, _, w, h = frame
    sigma = min(w, h) / 3.0
    s = sigma * sigma
    return Gaussian2D(0.0, 0.0, s, s, 0.0, 1.0 / s, 1.0 / s, 0.0, math.log(s * s), 0)


def spatial_prior(dx: float, dy: float, width: float, height: float) -> float:
    ox = max(0.0, abs(dx) - width / 2.0)
    oy = max(0.0, abs(dy) - height / 2.0)
    sx = SPATIAL_PRIOR_FRAC * width
    sy = SPATIAL_PRIOR_FRAC * height
    return -0.5 * ((ox / sx) ** 2 + (oy / sy) ** 2)


def winner(
    px: float,
    py: float,
    frames: dict[str, tuple[float, float, float, float]],
    model: dict[str, Gaussian2D],
) -> str | None:
    for key, frame in frames.items():
        x, y, w, h = frame
        anchor_r = ANCHOR_FRAC * min(w, h) / 2.0
        dx = px - (x + w / 2.0)
        dy = py - (y + h / 2.0)
        if dx * dx + dy * dy <= anchor_r * anchor_r:
            return key

    best_key = None
    best_score = -math.inf
    for key, frame in frames.items():
        x, y, w, h = frame
        gaussian = model.get(key) or fallback_gaussian(frame)
        dx = px - (x + w / 2.0)
        dy = py - (y + h / 2.0)
        score = gaussian.log_score(dx, dy) + spatial_prior(dx, dy, w, h)
        if score > best_score:
            best_score = score
            best_key = key
    return best_key


def write_keyboard(lines: list[str], frames: dict[str, tuple[float, float, float, float]]) -> None:
    for key, (x, y, w, h) in frames.items():
        lines.append(
            f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
            f'fill="#FFFFFF" fill-opacity="0.05" stroke="#111827" stroke-opacity="0.88" stroke-width="2.2"/>'
        )
        if key in LETTER_KEYS:
            lines.append(
                f'<text x="{x + w / 2.0:.2f}" y="{y + h / 2.0 + 10:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="34" font-weight="700" '
                f'text-anchor="middle" fill="#111111">{svg_escape(key.upper())}</text>'
            )
        elif key == "space":
            lines.append(
                f'<text x="{x + w / 2.0:.2f}" y="{y + h / 2.0 + 6:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="600" '
                f'text-anchor="middle" fill="#111111" fill-opacity="0.55">SPACE</text>'
            )
        elif key == "delete":
            lines.append(
                f'<text x="{x + w / 2.0:.2f}" y="{y + h / 2.0 + 6:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700" '
                f'text-anchor="middle" fill="#111111" fill-opacity="0.60">DEL</text>'
            )


def render_session_svg(
    path: Path,
    *,
    frames: dict[str, tuple[float, float, float, float]],
    model: dict[str, Gaussian2D],
    raster_step: int,
) -> None:
    panel_x = PANEL_MARGIN
    panel_y = PANEL_MARGIN
    panel_w = WIDTH - 2 * PANEL_MARGIN
    panel_h = HEIGHT - 2 * PANEL_MARGIN
    clip_id = "keyboard_panel_clip"
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        '<defs>',
        '  <filter id="panel_shadow" x="-10%" y="-10%" width="120%" height="120%">',
        '    <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#0f172a" flood-opacity="0.14"/>',
        '  </filter>',
        f'  <clipPath id="{clip_id}">',
        f'    <rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" rx="{PANEL_RADIUS}"/>',
        '  </clipPath>',
        '</defs>',
        f'<rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" '
        f'rx="{PANEL_RADIUS}" fill="#F8FAFC" stroke="#0F172A" stroke-opacity="0.18" stroke-width="1.4" filter="url(#panel_shadow)"/>',
        f'<g clip-path="url(#{clip_id})">',
    ]

    background_data_url = raster_background_data_url(
        frames=frames,
        model=model,
        raster_step=raster_step,
    )
    lines.append(
        f'<image x="0" y="0" width="{WIDTH}" height="{HEIGHT}" '
        f'preserveAspectRatio="none" href="{background_data_url}"/>'
    )

    lines.append("</g>")
    lines.append(
        f'<rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" '
        f'rx="{PANEL_RADIUS}" fill="none" stroke="#111827" stroke-width="2.6"/>'
    )
    write_keyboard(lines, frames)
    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def hex_to_rgba(hex_color: str, alpha: int) -> tuple[int, int, int, int]:
    value = hex_color.lstrip("#")
    return (
        int(value[0:2], 16),
        int(value[2:4], 16),
        int(value[4:6], 16),
        alpha,
    )


@dataclass(frozen=True)
class RasterKeyParams:
    center_x: float
    center_y: float
    width: float
    height: float
    anchor_radius: float
    mu_x: float
    mu_y: float
    pxx: float
    pyy: float
    pxy: float
    log_det: float


def raster_key_params(
    frames: dict[str, tuple[float, float, float, float]],
    model: dict[str, Gaussian2D],
) -> list[RasterKeyParams]:
    params: list[RasterKeyParams] = []
    for key in ALL_KEYS:
        frame = frames[key]
        x, y, width, height = frame
        gaussian = model.get(key) or fallback_gaussian(frame)
        params.append(
            RasterKeyParams(
                center_x=x + width / 2.0,
                center_y=y + height / 2.0,
                width=width,
                height=height,
                anchor_radius=ANCHOR_FRAC * min(width, height) / 2.0,
                mu_x=gaussian.mu_x,
                mu_y=gaussian.mu_y,
                pxx=gaussian.pxx,
                pyy=gaussian.pyy,
                pxy=gaussian.pxy,
                log_det=gaussian.log_det,
            )
        )
    return params


def winner_indices_grid(
    sample_x: np.ndarray,
    sample_y: np.ndarray,
    params: list[RasterKeyParams],
) -> np.ndarray:
    x_grid, y_grid = np.meshgrid(sample_x, sample_y)
    best_score = np.full(x_grid.shape, -np.inf, dtype=np.float32)
    best_index = np.full(x_grid.shape, -1, dtype=np.int16)
    anchor_index = np.full(x_grid.shape, -1, dtype=np.int16)
    unassigned_anchor = np.ones(x_grid.shape, dtype=bool)

    for index, param in enumerate(params):
        dx = x_grid - param.center_x
        dy = y_grid - param.center_y

        anchor_mask = unassigned_anchor & ((dx * dx + dy * dy) <= (param.anchor_radius ** 2))
        if anchor_mask.any():
            anchor_index[anchor_mask] = index
            unassigned_anchor &= ~anchor_mask

        ux = dx - param.mu_x
        uy = dy - param.mu_y
        ox = np.maximum(0.0, np.abs(dx) - param.width / 2.0)
        oy = np.maximum(0.0, np.abs(dy) - param.height / 2.0)
        spatial_x = ox / (SPATIAL_PRIOR_FRAC * param.width)
        spatial_y = oy / (SPATIAL_PRIOR_FRAC * param.height)
        score = -0.5 * (
            param.pxx * ux * ux
            + 2.0 * param.pxy * ux * uy
            + param.pyy * uy * uy
            + param.log_det
            + spatial_x * spatial_x
            + spatial_y * spatial_y
        )

        improve_mask = score > best_score
        if improve_mask.any():
            best_score[improve_mask] = score[improve_mask]
            best_index[improve_mask] = index

    return np.where(anchor_index >= 0, anchor_index, best_index)


def raster_background_data_url(
    *,
    frames: dict[str, tuple[float, float, float, float]],
    model: dict[str, Gaussian2D],
    raster_step: int,
) -> str:
    sample_step = max(1, raster_step)
    coarse_w = max(1, math.ceil(WIDTH / sample_step))
    coarse_h = max(1, math.ceil(HEIGHT / sample_step))
    sub_samples = 3 if sample_step >= 4 else 2 if sample_step >= 2 else 1
    fine_w = coarse_w * sub_samples
    fine_h = coarse_h * sub_samples
    fine_step = sample_step / sub_samples

    sample_x = np.minimum(
        WIDTH - 0.5,
        (np.arange(fine_w, dtype=np.float32) + 0.5) * fine_step,
    )
    sample_y = np.minimum(
        HEIGHT - 0.5,
        (np.arange(fine_h, dtype=np.float32) + 0.5) * fine_step,
    )

    key_indices = winner_indices_grid(
        sample_x=sample_x,
        sample_y=sample_y,
        params=raster_key_params(frames, model),
    )
    palette = np.array(
        [hex_to_rgba(key_color(key), 178) for key in ALL_KEYS],
        dtype=np.uint8,
    )
    fine_rgba = palette[key_indices]

    if sub_samples > 1:
        coarse_rgba = fine_rgba.reshape(
            coarse_h,
            sub_samples,
            coarse_w,
            sub_samples,
            4,
        ).mean(axis=(1, 3), dtype=np.float32).astype(np.uint8)
    else:
        coarse_rgba = fine_rgba

    image = Image.fromarray(coarse_rgba, mode="RGBA")

    if sample_step > 1:
        image = image.resize((WIDTH, HEIGHT), resample=Image.Resampling.LANCZOS)
    elif image.size != (WIDTH, HEIGHT):
        image = image.resize((WIDTH, HEIGHT), resample=Image.Resampling.LANCZOS)

    data = io.BytesIO()
    image.save(data, format="PNG")
    encoded = base64.b64encode(data.getvalue()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_outputs(
    sessions: dict[int, list[SessionEvent]],
    output_dir: Path,
    *,
    raster_step: int,
    min_samples: int,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    frames = keyboard_frames()
    summary_rows: list[dict] = []
    by_key_rows: list[dict] = []

    per_session_samples: dict[int, list[TrainingSample]] = {
        session_index: training_samples(events, frames)
        for session_index, events in sessions.items()
    }

    cumulative_prior_samples: list[TrainingSample] = []
    ordered_session_ids = sorted(sessions)
    for ordinal, session_id in enumerate(ordered_session_ids, start=1):
        current_samples = per_session_samples.get(session_id, [])
        prior_model, _, prior_sample_counts = fit_model(
            cumulative_prior_samples,
            prior_model=None,
            min_samples=min_samples,
        )
        session_model, model_sources, current_sample_counts = fit_model(
            current_samples,
            prior_model=prior_model,
            min_samples=min_samples,
        )

        render_session_svg(
            output_dir / f"session_gaussian_boundaries_{ordinal:02d}.svg",
            frames=frames,
            model=session_model,
            raster_step=max(1, raster_step),
        )

        source_counts = Counter(model_sources.get(key, SOURCE_GEOMETRY_FALLBACK) for key in ALL_KEYS)
        summary_rows.append(
            {
                "session_ordinal": ordinal,
                "study_session_index": session_id + 1,
                "clean_events": len(sessions[session_id]),
                "training_samples": len(current_samples),
                "prior_training_samples": len(cumulative_prior_samples),
                "fitted_current_keys": source_counts[SOURCE_FITTED_CURRENT],
                "prior_model_keys": source_counts[SOURCE_PRIOR_MODEL],
                "geometry_fallback_keys": source_counts[SOURCE_GEOMETRY_FALLBACK],
            }
        )

        for key in ALL_KEYS:
            gaussian = session_model.get(key)
            by_key_rows.append(
                {
                    "session_ordinal": ordinal,
                    "study_session_index": session_id + 1,
                    "key": key,
                    "current_session_taps": current_sample_counts.get(key, 0),
                    "prior_cumulative_taps": prior_sample_counts.get(key, 0),
                    "source": model_sources.get(key, SOURCE_GEOMETRY_FALLBACK),
                    "model_taps": 0 if gaussian is None else gaussian.count,
                }
            )

        cumulative_prior_samples.extend(current_samples)

    write_csv(
        output_dir / "session_gaussian_boundaries_summary.csv",
        fieldnames=[
            "session_ordinal",
            "study_session_index",
            "clean_events",
            "training_samples",
            "prior_training_samples",
            "fitted_current_keys",
            "prior_model_keys",
            "geometry_fallback_keys",
        ],
        rows=summary_rows,
    )
    write_csv(
        output_dir / "session_gaussian_boundaries_by_key.csv",
        fieldnames=[
            "session_ordinal",
            "study_session_index",
            "key",
            "current_session_taps",
            "prior_cumulative_taps",
            "source",
            "model_taps",
        ],
        rows=by_key_rows,
    )


def demo_rows() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    session_shifts = [(-0.05, -0.02), (0.01, 0.01), (0.04, 0.03), (0.07, 0.05)]
    timestamp = 0
    for session_index, (shift_x, shift_y) in enumerate(session_shifts, start=1):
        for key in ALL_KEYS:
            base_count = 7 if key not in {"q", "z", "delete"} else 3 + session_index
            if key == "space":
                base_count = 12
            for tap_index in range(base_count):
                angle = tap_index * 1.3 + session_index * 0.7
                radius_x = 0.10 if key == "space" else 0.07
                radius_y = 0.05 if key == "space" else 0.08
                x = 0.5 + shift_x + math.cos(angle) * radius_x
                y = 0.5 + shift_y + math.sin(angle) * radius_y
                rows.append(
                    {
                        "session_mode": "classic",
                        "event_type": "delete" if key == "delete" else "insert",
                        "is_outlier": "0",
                        "study_session_index": str(session_index),
                        "trial_index": str(tap_index // 6),
                        "trial_id": f"s{session_index}-trial-{tap_index // 6}",
                        "timestamp_ms": str(timestamp),
                        "expected_char": "" if key == "delete" else (" " if key == "space" else key),
                        "key_label": key,
                        "actual_char": "" if key == "delete" else (" " if key == "space" else key),
                        "corrected_char": "e" if key == "delete" else "",
                        "is_correct": "1",
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
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()

    if args.demo:
        csv_path = output_dir / "synthetic_session_boundaries_input.csv"
        write_demo_csv(csv_path)
    elif args.csv_path:
        csv_path = Path(args.csv_path).resolve()
    else:
        raise SystemExit("Provide a CSV path or use --demo.")

    sessions = load_session_events(csv_path)
    if not sessions:
        raise SystemExit(f"No usable taps found in {csv_path}")

    write_outputs(
        sessions,
        output_dir,
        raster_step=max(2, args.raster_step),
        min_samples=max(1, args.min_samples),
    )
    print(f"Input CSV: {csv_path}")
    print(f"Output dir: {output_dir}")
    print(f"Sessions: {', '.join(str(index + 1) for index in sessions)}")
    print("Outputs:")
    print("  - session_gaussian_boundaries_XX.svg")
    print("  - session_gaussian_boundaries_summary.csv")
    print("  - session_gaussian_boundaries_by_key.csv")


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
