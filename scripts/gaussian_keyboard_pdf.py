#!/usr/bin/env python3
"""
gaussian_keyboard_pdf.py
------------------------
Fit and render the same intended-key Gaussian keyboard model used by the app.

Usage:
    python scripts/gaussian_keyboard_pdf.py <keystrokes.csv> [output.pdf]

If output is omitted, writes <stem>_gaussian.pdf next to the input.
Pass an `.svg` output path to export the old-style smooth SVG boundary view.
"""

from __future__ import annotations

import base64
import colorsys
import csv
import io
import math
import os
import sys
import tempfile
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "matplotlib"))
os.environ.setdefault("XDG_CACHE_HOME", str(Path(tempfile.gettempdir()) / "xdg-cache"))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.patches import Circle, FancyBboxPatch, Rectangle


PAGE_W = 612
PAGE_H = 792
MARGIN = 36

PDF_SIDE_PAD = 3.0
PDF_KEY_GAP = 6.0
PDF_ROW_GAP = 13.0
PDF_TOP_PAD = 11.0
HEADER_BOTTOM = 84.0

LIVE_SIDE_PAD = 5.0
LIVE_KEY_GAP = 6.0
LIVE_ROW_GAP = 11.0

SVG_WIDTH = 980
SVG_SIDE_PAD = 16.0
SVG_TOP_PAD = 18.0
SVG_KEY_GAP = 10.0
SVG_ROW_GAP = 22.0
SVG_KEY_H = 76.0
SVG_BOTTOM_PAD = 18.0
SVG_PANEL_MARGIN = 10.0
SVG_PANEL_RADIUS = 20.0
SVG_INNER_MARGIN_X = 14.0
SVG_INNER_MARGIN_Y = 14.0
SVG_HEIGHT = int(
    SVG_TOP_PAD + 4.0 * SVG_KEY_H + 3.0 * SVG_ROW_GAP + SVG_BOTTOM_PAD + 2.0 * (SVG_PANEL_MARGIN + SVG_INNER_MARGIN_Y)
)

MIN_SAMPLES = 5
RIDGE_FRAC = 0.05
ANCHOR_FRAC = 0.20
SPATIAL_PRIOR_FRAC = 0.40
RASTER_STEP = 2.0

ROW0 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
ROW1 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
ROW2 = ["z", "x", "c", "v", "b", "n", "m"]
ALL_KEYS = ROW0 + ROW1 + ROW2 + ["space", "delete"]
LETTER_KEYS = set(ROW0 + ROW1 + ROW2)
VALID_KEYS = set(ALL_KEYS)
SOURCE_FITTED_CURRENT = "fitted_current"
SOURCE_PRIOR_MODEL = "prior_model"
SOURCE_GEOMETRY_FALLBACK = "geometry_fallback"

def rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{max(0, min(255, round(channel * 255))):02X}" for channel in rgb)


def hex_to_rgb_unit(hex_color: str) -> tuple[float, float, float]:
    value = hex_color.lstrip("#")
    return (
        int(value[0:2], 16) / 255.0,
        int(value[2:4], 16) / 255.0,
        int(value[4:6], 16) / 255.0,
    )


def color_distance(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    dr = a[0] - b[0]
    dg = a[1] - b[1]
    db = a[2] - b[2]
    lum_a = 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]
    lum_b = 0.2126 * b[0] + 0.7152 * b[1] + 0.0722 * b[2]
    return 2.0 * dr * dr + 3.0 * dg * dg + 2.0 * db * db + 0.6 * (lum_a - lum_b) ** 2


def build_distinct_semantic_colors() -> dict[str, str]:
    seed_hex = [
        "#D60000",
        "#005FDD",
        "#00A651",
        "#FFB000",
        "#7A00CC",
        "#00C8C8",
        "#FF1493",
        "#7A4A00",
        "#39FF14",
        "#111111",
    ]
    selected = [hex_to_rgb_unit(value) for value in seed_hex]

    candidates: list[tuple[float, float, float]] = []
    for hue in range(0, 360, 5):
        for saturation in (0.98, 0.86, 0.74):
            for value in (0.98, 0.86, 0.72):
                rgb = colorsys.hsv_to_rgb(hue / 360.0, saturation, value)
                if max(rgb) - min(rgb) < 0.28:
                    continue
                candidates.append(rgb)

    while len(selected) < len(ALL_KEYS):
        best_candidate = max(
            candidates,
            key=lambda candidate: min(color_distance(candidate, current) for current in selected),
        )
        selected.append(best_candidate)
        candidates = [candidate for candidate in candidates if candidate != best_candidate]

    return {
        key: rgb_to_hex(color)
        for key, color in zip(ALL_KEYS, selected[: len(ALL_KEYS)])
    }


SEMANTIC_COLORS = build_distinct_semantic_colors()


@dataclass
class Event:
    event_type: str
    key_label: str
    expected_char: str
    actual_char: str
    corrected_char: str
    is_correct: bool
    tap_local_x: float
    tap_local_y: float
    key_width: float
    key_height: float
    session_mode: str
    study_session_index: int
    trial_index: int
    timestamp_ms: int


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    @property
    def mid_x(self) -> float:
        return self.x + self.w / 2.0

    @property
    def mid_y(self) -> float:
        return self.y + self.h / 2.0


@dataclass
class TrainingSample:
    target_key: str
    offset_x: float
    offset_y: float
    key_width: float
    key_height: float
    plot_x: float
    plot_y: float


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


@dataclass
class PdfPage:
    title: str
    summary_text: str
    detail_text: str
    samples: list[TrainingSample]
    model: dict[str, Gaussian2D]
    model_sources: dict[str, str]


@dataclass(frozen=True)
class RasterKeyParams:
    center_x: float
    center_y: float
    width: float
    height: float
    anchor_radius_sq: float
    mu_x: float
    mu_y: float
    pxx: float
    pyy: float
    pxy: float
    log_det: float


def safe_float(value: str | None, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def safe_int(value: str | None, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def svg_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def hex_to_rgba(hex_color: str, alpha: int) -> tuple[int, int, int, int]:
    value = hex_color.lstrip("#")
    return (
        int(value[0:2], 16),
        int(value[2:4], 16),
        int(value[4:6], 16),
        alpha,
    )


def key_color(key: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    value = SEMANTIC_COLORS.get(key, "#D1D5DB").lstrip("#")
    rgb = (
        int(value[0:2], 16) / 255.0,
        int(value[2:4], 16) / 255.0,
        int(value[4:6], 16) / 255.0,
    )
    return (rgb[0], rgb[1], rgb[2], alpha)


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


def read_events(csv_path: Path) -> tuple[list[Event], str]:
    with csv_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    events: list[Event] = []
    for row in rows:
        event_type = (row.get("event_type") or "insert").strip()
        key_label = row.get("key_label", "").strip()
        if key_label not in VALID_KEYS:
            continue
        key_width = safe_float(row.get("key_width"))
        key_height = safe_float(row.get("key_height"))
        if key_width <= 0 or key_height <= 0:
            continue

        if row.get("is_outlier", "0") not in {"", "0", "false", "False"}:
            continue
        flags = row.get("outlier_flags", "")
        if "spatial" in flags or "far_from_target" in flags:
            continue

        actual_char, corrected_char = event_chars(row, event_type, key_label)
        events.append(
            Event(
                event_type=event_type,
                key_label=key_label,
                expected_char=row.get("expected_char", ""),
                actual_char=actual_char,
                corrected_char=corrected_char,
                is_correct=row.get("is_correct", "") in {"1", "true", "True"},
                tap_local_x=safe_float(row.get("tap_local_x")),
                tap_local_y=safe_float(row.get("tap_local_y")),
                key_width=key_width,
                key_height=key_height,
                session_mode=(row.get("session_mode") or "").strip().lower(),
                study_session_index=max(0, safe_int(row.get("study_session_index"), 1) - 1),
                trial_index=safe_int(row.get("trial_index"), 0),
                timestamp_ms=safe_int(row.get("timestamp_ms"), 0),
            )
        )

    participant = ""
    if rows:
        participant = f"{rows[0].get('participant_first', '').strip()} {rows[0].get('participant_last', '').strip()}".strip()
    return events, participant


def inferred_letter_width(event: Event) -> float:
    if event.key_label in LETTER_KEYS:
        return event.key_width
    if event.key_label == "delete":
        return max(0.0, (2.0 * event.key_width - LIVE_KEY_GAP) / 3.0)
    if event.key_label == "space":
        return max(0.0, (event.key_width - 6.0 * LIVE_KEY_GAP) / 7.0)
    return event.key_width


def live_frame(key: str, event: Event) -> Rect | None:
    key_w = inferred_letter_width(event)
    key_h = event.key_height
    if key_w <= 0 or key_h <= 0:
        return None

    keyboard_w = 10.0 * key_w + 2.0 * LIVE_SIDE_PAD + 9.0 * LIVE_KEY_GAP
    special_w = (keyboard_w - 2.0 * LIVE_SIDE_PAD - 7.0 * key_w - 8.0 * LIVE_KEY_GAP) / 2.0

    if key in ROW0:
        column = ROW0.index(key)
        return Rect(LIVE_SIDE_PAD + column * (key_w + LIVE_KEY_GAP), 0.0, key_w, key_h)
    if key in ROW1:
        column = ROW1.index(key)
        row_w = len(ROW1) * key_w + (len(ROW1) - 1) * LIVE_KEY_GAP
        return Rect((keyboard_w - row_w) / 2.0 + column * (key_w + LIVE_KEY_GAP), key_h + LIVE_ROW_GAP, key_w, key_h)
    if key in ROW2:
        column = ROW2.index(key)
        return Rect(
            LIVE_SIDE_PAD + special_w + LIVE_KEY_GAP + column * (key_w + LIVE_KEY_GAP),
            2.0 * (key_h + LIVE_ROW_GAP),
            key_w,
            key_h,
        )
    if key == "delete":
        return Rect(keyboard_w - LIVE_SIDE_PAD - special_w, 2.0 * (key_h + LIVE_ROW_GAP), special_w, key_h)
    if key == "space":
        return Rect(
            LIVE_SIDE_PAD + special_w + LIVE_KEY_GAP,
            3.0 * (key_h + LIVE_ROW_GAP),
            keyboard_w - 2.0 * LIVE_SIDE_PAD - 2.0 * special_w - 2.0 * LIVE_KEY_GAP,
            key_h,
        )
    return None


def deleted_insert_indices(events: list[Event]) -> set[int]:
    stack: list[int] = []
    deleted: set[int] = set()
    for index, event in enumerate(events):
        if event.event_type in {"insert", "replace"} and event.actual_char:
            stack.append(index)
        elif event.event_type == "delete" and stack:
            removed_index = stack.pop()
            if not event.corrected_char or event.corrected_char == events[removed_index].actual_char:
                deleted.add(removed_index)
    return deleted


def sample_for(event: Event, target_key: str) -> TrainingSample | None:
    hit = live_frame(event.key_label, event)
    target = live_frame(target_key, event)
    if not hit or not target:
        return None

    scale_x = event.key_width / hit.w if hit.w > 0 else 0.0
    scale_y = event.key_height / hit.h if hit.h > 0 else 0.0
    if scale_x <= 0 or scale_y <= 0:
        return None

    absolute_x = hit.x + event.tap_local_x / scale_x
    absolute_y = hit.y + event.tap_local_y / scale_y
    target_w = target.w * scale_x
    target_h = target.h * scale_y
    return TrainingSample(
        target_key=target_key,
        offset_x=(absolute_x - target.mid_x) * scale_x,
        offset_y=(absolute_y - target.mid_y) * scale_y,
        key_width=target_w,
        key_height=target_h,
        plot_x=absolute_x,
        plot_y=absolute_y,
    )


def training_samples(events: list[Event]) -> list[TrainingSample]:
    deleted = deleted_insert_indices(events)
    samples: list[TrainingSample] = []
    for index, event in enumerate(events):
        if event.event_type == "delete":
            if event.key_label == "delete":
                sample = sample_for(event, "delete")
                if sample:
                    samples.append(sample)
            continue

        if event.event_type not in {"insert", "replace"}:
            continue

        intended = key_for_expected(event.expected_char)
        if intended:
            sample = sample_for(event, intended)
        elif index in deleted:
            continue
        elif event.is_correct:
            sample = sample_for(event, event.key_label)
        else:
            sample = None

        if sample:
            samples.append(sample)
    return samples


def fit_single(samples: list[TrainingSample]) -> Gaussian2D | None:
    count = len(samples)
    if count < MIN_SAMPLES:
        return None

    offsets = np.array([(sample.offset_x, sample.offset_y) for sample in samples], dtype=np.float64)
    key_widths = np.array([sample.key_width for sample in samples], dtype=np.float64)
    mu_x, mu_y = offsets.mean(axis=0)
    centered = offsets - np.array([mu_x, mu_y], dtype=np.float64)
    denom = max(1, count - 1)
    cov = (centered.T @ centered) / denom

    ridge = (RIDGE_FRAC * float(key_widths.mean())) ** 2
    sxx = float(cov[0, 0] + ridge)
    syy = float(cov[1, 1] + ridge)
    sxy = float(cov[0, 1])

    det = sxx * syy - sxy * sxy
    if det <= 0:
        return None

    inv = 1.0 / det
    return Gaussian2D(
        mu_x=float(mu_x),
        mu_y=float(mu_y),
        sxx=sxx,
        syy=syy,
        sxy=sxy,
        pxx=syy * inv,
        pyy=sxx * inv,
        pxy=-sxy * inv,
        log_det=math.log(det),
        count=count,
    )


def fit_model(
    samples: list[TrainingSample],
    prior_model: dict[str, Gaussian2D] | None = None,
) -> tuple[dict[str, Gaussian2D], dict[str, str], dict[str, int]]:
    grouped: dict[str, list[TrainingSample]] = defaultdict(list)
    for sample in samples:
        grouped[sample.target_key].append(sample)

    model: dict[str, Gaussian2D] = {}
    model_sources: dict[str, str] = {}
    sample_counts: dict[str, int] = {}

    for key in ALL_KEYS:
        key_samples = grouped.get(key, [])
        sample_counts[key] = len(key_samples)
        gaussian = fit_single(key_samples)
        if gaussian is not None:
            model[key] = gaussian
            model_sources[key] = SOURCE_FITTED_CURRENT
        elif prior_model and key in prior_model:
            model[key] = prior_model[key]
            model_sources[key] = SOURCE_PRIOR_MODEL

    return model, model_sources, sample_counts


def fallback_gaussian(frame: Rect) -> Gaussian2D:
    sigma = min(frame.w, frame.h) / 3.0
    variance = sigma * sigma
    return Gaussian2D(0.0, 0.0, variance, variance, 0.0, 1.0 / variance, 1.0 / variance, 0.0, math.log(variance * variance), 0)


def spatial_prior(dx: float, dy: float, key_w: float, key_h: float) -> float:
    ox = max(0.0, abs(dx) - key_w / 2.0)
    oy = max(0.0, abs(dy) - key_h / 2.0)
    sx = SPATIAL_PRIOR_FRAC * key_w
    sy = SPATIAL_PRIOR_FRAC * key_h
    return -0.5 * ((ox / sx) ** 2 + (oy / sy) ** 2)


def winner(px: float, py: float, frames: dict[str, Rect], model: dict[str, Gaussian2D]) -> str | None:
    for key, frame in frames.items():
        anchor_r = ANCHOR_FRAC * min(frame.w, frame.h) / 2.0
        dx = px - frame.mid_x
        dy = py - frame.mid_y
        if dx * dx + dy * dy <= anchor_r * anchor_r:
            return key

    best_key = None
    best_score = -math.inf
    for key, frame in frames.items():
        gaussian = model.get(key) or fallback_gaussian(frame)
        dx = px - frame.mid_x
        dy = py - frame.mid_y
        score = gaussian.log_score(dx, dy) + spatial_prior(dx, dy, frame.w, frame.h)
        if score > best_score:
            best_score = score
            best_key = key
    return best_key


def build_pdf_frames(canvas_left: float, canvas_top: float, canvas_w: float) -> dict[str, Rect]:
    key_w = (canvas_w - 2.0 * PDF_SIDE_PAD - 9.0 * PDF_KEY_GAP) / 10.0
    special_w = (canvas_w - 2.0 * PDF_SIDE_PAD - 7.0 * key_w - 8.0 * PDF_KEY_GAP) / 2.0
    key_h = round(key_w * 1.35)
    frames: dict[str, Rect] = {}

    y0 = canvas_top + PDF_TOP_PAD
    for index, key in enumerate(ROW0):
        frames[key] = Rect(canvas_left + PDF_SIDE_PAD + index * (key_w + PDF_KEY_GAP), y0, key_w, key_h)

    y1 = y0 + key_h + PDF_ROW_GAP
    row1_start = canvas_left + (canvas_w - 9.0 * key_w - 8.0 * PDF_KEY_GAP) / 2.0
    for index, key in enumerate(ROW1):
        frames[key] = Rect(row1_start + index * (key_w + PDF_KEY_GAP), y1, key_w, key_h)

    y2 = y1 + key_h + PDF_ROW_GAP
    row2_start = canvas_left + PDF_SIDE_PAD + special_w + PDF_KEY_GAP
    for index, key in enumerate(ROW2):
        frames[key] = Rect(row2_start + index * (key_w + PDF_KEY_GAP), y2, key_w, key_h)

    frames["delete"] = Rect(canvas_left + canvas_w - PDF_SIDE_PAD - special_w, y2, special_w, key_h)
    y3 = y2 + key_h + PDF_ROW_GAP
    frames["space"] = Rect(
        canvas_left + PDF_SIDE_PAD + special_w + PDF_KEY_GAP,
        y3,
        canvas_w - 2.0 * PDF_SIDE_PAD - 2.0 * special_w - 2.0 * PDF_KEY_GAP,
        key_h,
    )
    return frames


def frame_bounds(frames: dict[str, Rect]) -> Rect:
    min_x = min(frame.x for frame in frames.values())
    min_y = min(frame.y for frame in frames.values())
    max_x = max(frame.x + frame.w for frame in frames.values())
    max_y = max(frame.y + frame.h for frame in frames.values())
    return Rect(min_x, min_y, max_x - min_x, max_y - min_y)


def offset_frames(frames: dict[str, Rect], dx: float, dy: float) -> dict[str, Rect]:
    return {
        key: Rect(frame.x + dx, frame.y + dy, frame.w, frame.h)
        for key, frame in frames.items()
    }


def build_svg_frames() -> tuple[Rect, dict[str, Rect]]:
    panel_rect = Rect(
        SVG_PANEL_MARGIN,
        SVG_PANEL_MARGIN,
        SVG_WIDTH - 2.0 * SVG_PANEL_MARGIN,
        SVG_HEIGHT - 2.0 * SVG_PANEL_MARGIN,
    )
    inner_rect = Rect(
        panel_rect.x + SVG_INNER_MARGIN_X,
        panel_rect.y + SVG_INNER_MARGIN_Y,
        panel_rect.w - 2.0 * SVG_INNER_MARGIN_X,
        panel_rect.h - 2.0 * SVG_INNER_MARGIN_Y,
    )
    left = inner_rect.x
    top = inner_rect.y
    usable_width = inner_rect.w
    key_w = (usable_width - 2.0 * SVG_SIDE_PAD - 9.0 * SVG_KEY_GAP) / 10.0
    special_w = (usable_width - 2.0 * SVG_SIDE_PAD - 7.0 * key_w - 8.0 * SVG_KEY_GAP) / 2.0
    frames: dict[str, Rect] = {}

    y0 = top + SVG_TOP_PAD
    for index, key in enumerate(ROW0):
        frames[key] = Rect(left + SVG_SIDE_PAD + index * (key_w + SVG_KEY_GAP), y0, key_w, SVG_KEY_H)

    y1 = y0 + SVG_KEY_H + SVG_ROW_GAP
    row1_start = left + (usable_width - 9.0 * key_w - 8.0 * SVG_KEY_GAP) / 2.0
    for index, key in enumerate(ROW1):
        frames[key] = Rect(row1_start + index * (key_w + SVG_KEY_GAP), y1, key_w, SVG_KEY_H)

    y2 = y1 + SVG_KEY_H + SVG_ROW_GAP
    row2_start = left + SVG_SIDE_PAD + special_w + SVG_KEY_GAP
    for index, key in enumerate(ROW2):
        frames[key] = Rect(row2_start + index * (key_w + SVG_KEY_GAP), y2, key_w, SVG_KEY_H)

    frames["delete"] = Rect(left + usable_width - SVG_SIDE_PAD - special_w, y2, special_w, SVG_KEY_H)
    y3 = y2 + SVG_KEY_H + SVG_ROW_GAP
    frames["space"] = Rect(
        left + SVG_SIDE_PAD + special_w + SVG_KEY_GAP,
        y3,
        usable_width - 2.0 * SVG_SIDE_PAD - 2.0 * special_w - 2.0 * SVG_KEY_GAP,
        SVG_KEY_H,
    )
    bounds = frame_bounds(frames)
    dx = inner_rect.mid_x - bounds.mid_x
    dy = inner_rect.mid_y - bounds.mid_y
    return panel_rect, offset_frames(frames, dx, dy)


def raster_key_params(frames: dict[str, Rect], model: dict[str, Gaussian2D]) -> list[RasterKeyParams]:
    params: list[RasterKeyParams] = []
    for key in ALL_KEYS:
        frame = frames[key]
        gaussian = model.get(key) or fallback_gaussian(frame)
        params.append(
            RasterKeyParams(
                center_x=frame.mid_x,
                center_y=frame.mid_y,
                width=frame.w,
                height=frame.h,
                anchor_radius_sq=(ANCHOR_FRAC * min(frame.w, frame.h) / 2.0) ** 2,
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

        anchor_mask = unassigned_anchor & ((dx * dx + dy * dy) <= param.anchor_radius_sq)
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


def raster_background_rgba(
    *,
    canvas: Rect,
    frames: dict[str, Rect],
    model: dict[str, Gaussian2D],
    raster_step: float,
    alpha: int = 208,
) -> np.ndarray:
    sample_step = max(1.0, float(raster_step))
    coarse_w = max(1, int(math.ceil(canvas.w / sample_step)))
    coarse_h = max(1, int(math.ceil(canvas.h / sample_step)))
    sub_samples = 3 if sample_step >= 4 else 2 if sample_step >= 2 else 1
    fine_w = coarse_w * sub_samples
    fine_h = coarse_h * sub_samples

    sample_x = np.linspace(
        canvas.x + canvas.w / (2.0 * fine_w),
        canvas.x + canvas.w - canvas.w / (2.0 * fine_w),
        fine_w,
        dtype=np.float32,
    )
    sample_y = np.linspace(
        canvas.y + canvas.h / (2.0 * fine_h),
        canvas.y + canvas.h - canvas.h / (2.0 * fine_h),
        fine_h,
        dtype=np.float32,
    )

    key_indices = winner_indices_grid(sample_x, sample_y, raster_key_params(frames, model))
    palette = np.array([hex_to_rgba(SEMANTIC_COLORS.get(key, "#D1D5DB"), alpha) for key in ALL_KEYS], dtype=np.uint8)
    fine_rgba = palette[key_indices]

    if sub_samples > 1:
        coarse_rgba = fine_rgba.reshape(coarse_h, sub_samples, coarse_w, sub_samples, 4).mean(axis=(1, 3), dtype=np.float32).astype(np.uint8)
    else:
        coarse_rgba = fine_rgba

    target_w = max(1, int(round(canvas.w)))
    target_h = max(1, int(round(canvas.h)))
    image = Image.fromarray(coarse_rgba, mode="RGBA")
    if image.size != (target_w, target_h):
        image = image.resize((target_w, target_h), resample=Image.Resampling.LANCZOS)
    return np.asarray(image)


def raster_background_data_url(
    *,
    canvas: Rect,
    frames: dict[str, Rect],
    model: dict[str, Gaussian2D],
    raster_step: float,
    alpha: int = 208,
) -> str:
    image = Image.fromarray(raster_background_rgba(canvas=canvas, frames=frames, model=model, raster_step=raster_step, alpha=alpha), mode="RGBA")
    data = io.BytesIO()
    image.save(data, format="PNG")
    encoded = base64.b64encode(data.getvalue()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def draw_keyboard_svg(lines: list[str], frames: dict[str, Rect]) -> None:
    for key, frame in frames.items():
        lines.append(
            f'<rect x="{frame.x:.2f}" y="{frame.y:.2f}" width="{frame.w:.2f}" height="{frame.h:.2f}" '
            f'fill="#FFFFFF" fill-opacity="0.05" stroke="#111827" stroke-opacity="0.88" stroke-width="2.2"/>'
        )
        if key in LETTER_KEYS:
            lines.append(
                f'<text x="{frame.mid_x:.2f}" y="{frame.mid_y + 10:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="34" font-weight="700" '
                f'text-anchor="middle" fill="#111111">{svg_escape(key.upper())}</text>'
            )
        elif key == "space":
            lines.append(
                f'<text x="{frame.mid_x:.2f}" y="{frame.mid_y + 6:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="600" '
                f'text-anchor="middle" fill="#111111" fill-opacity="0.55">SPACE</text>'
            )
        elif key == "delete":
            lines.append(
                f'<text x="{frame.mid_x:.2f}" y="{frame.mid_y + 6:.2f}" '
                f'font-family="Helvetica,Arial,sans-serif" font-size="18" font-weight="700" '
                f'text-anchor="middle" fill="#111111" fill-opacity="0.60">DEL</text>'
            )


def render_boundary_svg(
    path: Path,
    *,
    model: dict[str, Gaussian2D],
    raster_step: float | None = None,
) -> None:
    panel_rect, frames = build_svg_frames()
    panel_x = panel_rect.x
    panel_y = panel_rect.y
    panel_w = panel_rect.w
    panel_h = panel_rect.h
    clip_id = "keyboard_panel_clip"
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SVG_WIDTH}" height="{SVG_HEIGHT}" viewBox="0 0 {SVG_WIDTH} {SVG_HEIGHT}">',
        '<rect width="100%" height="100%" fill="#ffffff"/>',
        "<defs>",
        '  <filter id="panel_shadow" x="-10%" y="-10%" width="120%" height="120%">',
        '    <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#0f172a" flood-opacity="0.14"/>',
        "  </filter>",
        f'  <clipPath id="{clip_id}">',
        f'    <rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" rx="{SVG_PANEL_RADIUS:.2f}"/>',
        "  </clipPath>",
        "</defs>",
        f'<rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" '
        f'rx="{SVG_PANEL_RADIUS:.2f}" fill="#F8FAFC" stroke="#0F172A" stroke-opacity="0.18" stroke-width="1.4" filter="url(#panel_shadow)"/>',
        f'<g clip-path="url(#{clip_id})">',
    ]

    background_data_url = raster_background_data_url(
        canvas=panel_rect,
        frames=frames,
        model=model,
        raster_step=RASTER_STEP if raster_step is None else raster_step,
    )
    lines.append(
        f'<image x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" preserveAspectRatio="none" href="{background_data_url}"/>'
    )
    lines.append("</g>")
    lines.append(
        f'<rect x="{panel_x:.2f}" y="{panel_y:.2f}" width="{panel_w:.2f}" height="{panel_h:.2f}" '
        f'rx="{SVG_PANEL_RADIUS:.2f}" fill="none" stroke="#111827" stroke-width="2.6"/>'
    )
    draw_keyboard_svg(lines, frames)
    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def draw_keyboard_pdf(ax, frames: dict[str, Rect]) -> None:
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
        if key in LETTER_KEYS:
            ax.text(
                frame.mid_x,
                frame.mid_y + 8,
                key.upper(),
                fontsize=max(14, frame.h * 0.40),
                fontweight="bold",
                color="#111111",
                ha="center",
                va="center",
                zorder=4,
            )
        elif key == "space":
            ax.text(
                frame.mid_x,
                frame.mid_y + 4,
                "SPACE",
                fontsize=12,
                fontweight="semibold",
                color=(17 / 255.0, 17 / 255.0, 17 / 255.0, 0.55),
                ha="center",
                va="center",
                zorder=4,
            )
        elif key == "delete":
            ax.text(
                frame.mid_x,
                frame.mid_y + 4,
                "DEL",
                fontsize=12,
                fontweight="bold",
                color=(17 / 255.0, 17 / 255.0, 17 / 255.0, 0.60),
                ha="center",
                va="center",
                zorder=4,
            )


def render_pdf(
    out_path: Path,
    participant: str,
    events: list[Event],
    samples: list[TrainingSample],
    model: dict[str, Gaussian2D],
    model_sources: dict[str, str],
) -> None:
    page = PdfPage(
        title="Gaussian Keyboard Boundary",
        summary_text="",
        detail_text="",
        samples=samples,
        model=model,
        model_sources=model_sources,
    )
    render_pdf_pages(out_path, participant, [page])


def render_pdf_pages(
    out_path: Path,
    participant: str,
    pages: list[PdfPage],
) -> None:
    with PdfPages(out_path) as pdf:
        for page in pages:
            fig = plt.figure(figsize=(PAGE_W / 72, PAGE_H / 72), dpi=100)
            ax = fig.add_axes([0, 0, 1, 1])
            render_pdf_page(ax, participant, page)
            pdf.savefig(fig)
            plt.close(fig)


def render_pdf_page(ax, participant: str, page: PdfPage) -> None:
    ax.set_xlim(0, PAGE_W)
    ax.set_ylim(PAGE_H, 0)
    ax.set_aspect("equal")
    ax.axis("off")

    ax.add_patch(Rectangle((0, 0), PAGE_W, PAGE_H, facecolor="white", edgecolor="none", zorder=0))

    show_summary = bool(page.summary_text.strip())
    show_detail = bool(page.detail_text.strip())
    title_y = 34.0
    ax.text(PAGE_W / 2.0, title_y, page.title, fontsize=20, fontweight="bold", color="#0F172A", ha="center", va="center")
    if show_summary:
        ax.text(PAGE_W - MARGIN, title_y, page.summary_text, fontsize=9.5, family="monospace", color="#334155", ha="right", va="center")
    if show_detail:
        ax.text(MARGIN, 56, page.detail_text, fontsize=8.5, color="#64748B", va="center")

    panel_x = MARGIN - 2.0
    panel_y = HEADER_BOTTOM if (show_summary or show_detail) else 58.0
    panel_w = PAGE_W - 2.0 * panel_x

    canvas_left = panel_x + 18.0
    canvas_w = panel_w - 36.0
    frames = build_pdf_frames(canvas_left, panel_y + 8.0, canvas_w)
    key_h = next(iter(frames.values())).h
    keyboard_h = PDF_TOP_PAD + 4.0 * key_h + 3.0 * PDF_ROW_GAP + 8.0
    panel_h = keyboard_h + 20.0
    panel_rect = Rect(panel_x, panel_y, panel_w, panel_h)

    shadow = FancyBboxPatch(
        (panel_rect.x, panel_rect.y + 6.0),
        panel_rect.w,
        panel_rect.h,
        boxstyle="round,pad=0.0,rounding_size=16",
        facecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.08),
        edgecolor="none",
        zorder=0.5,
    )
    ax.add_patch(shadow)

    panel = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle="round,pad=0.0,rounding_size=16",
        facecolor="#F8FAFC",
        edgecolor=(15 / 255.0, 23 / 255.0, 42 / 255.0, 0.18),
        linewidth=1.2,
        zorder=1,
    )
    ax.add_patch(panel)

    background = raster_background_rgba(
        canvas=panel_rect,
        frames=frames,
        model=page.model,
        raster_step=RASTER_STEP,
        alpha=178,
    )
    image = ax.imshow(
        background,
        extent=(panel_rect.x, panel_rect.x + panel_rect.w, panel_rect.y + panel_rect.h, panel_rect.y),
        interpolation="bilinear",
        zorder=1.5,
    )
    image.set_clip_path(panel)

    draw_keyboard_pdf(ax, frames)

    panel_outline = FancyBboxPatch(
        (panel_rect.x, panel_rect.y),
        panel_rect.w,
        panel_rect.h,
        boxstyle="round,pad=0.0,rounding_size=16",
        facecolor="none",
        edgecolor="#111827",
        linewidth=2.0,
        zorder=4.5,
    )
    ax.add_patch(panel_outline)


def print_summary(
    events: list[Event],
    samples: list[TrainingSample],
    model: dict[str, Gaussian2D],
    model_sources: dict[str, str],
    sample_counts: dict[str, int],
) -> None:
    old_counts = Counter(event.key_label for event in events if event.is_correct and event.event_type != "delete")
    new_counts = Counter(sample.target_key for sample in samples)
    print("Old correct-landed counts:")
    print("  " + " ".join(f"{key}={old_counts[key]}" for key in ALL_KEYS if old_counts[key]))
    print("New intended-feedback counts:")
    print("  " + " ".join(f"{key}={new_counts[key]}" for key in ALL_KEYS if new_counts[key]))
    source_counts = Counter(model_sources.get(key, SOURCE_GEOMETRY_FALLBACK) for key in ALL_KEYS)
    print("Model sources:")
    print(
        "  "
        + " ".join(
            [
                f"{SOURCE_FITTED_CURRENT}={source_counts[SOURCE_FITTED_CURRENT]}",
                f"{SOURCE_PRIOR_MODEL}={source_counts[SOURCE_PRIOR_MODEL]}",
                f"{SOURCE_GEOMETRY_FALLBACK}={source_counts[SOURCE_GEOMETRY_FALLBACK]}",
            ]
        )
    )
    print("Per-key models:")
    print(
        "  "
        + " ".join(
            f"{key}(trial_n={sample_counts.get(key, 0)}, source={model_sources.get(key, SOURCE_GEOMETRY_FALLBACK)}, model_n={model[key].count if key in model else 0})"
            for key in ALL_KEYS
            if sample_counts.get(key, 0) or key in model
        )
    )


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    in_path = Path(sys.argv[1]).expanduser()
    out_path = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else in_path.with_name(in_path.stem + "_gaussian.pdf")
    events, participant = read_events(in_path)
    if not events:
        print(f"No valid events found in {in_path}")
        return 1

    samples = training_samples(events)
    model, model_sources, sample_counts = fit_model(samples)

    if out_path.suffix.lower() == ".svg":
        render_boundary_svg(out_path, model=model)
    else:
        render_pdf(out_path, participant, events, samples, model, model_sources)

    print(f"Input : {in_path}")
    print(f"Output: {out_path}")
    print(f"Events used: {len(events)}")
    print(f"Training samples: {len(samples)}")
    print_summary(events, samples, model, model_sources, sample_counts)
    return 0


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        raise SystemExit(main())
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
