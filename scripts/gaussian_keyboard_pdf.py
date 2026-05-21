#!/usr/bin/env python3
"""
gaussian_keyboard_pdf.py
------------------------
Fit and render the same intended-key Gaussian keyboard model used by the app.

Usage:
    python scripts/gaussian_keyboard_pdf.py <keystrokes.csv> [output.pdf]

If output is omitted, writes <stem>_gaussian.pdf next to the input. 
"""

from __future__ import annotations

import csv
import math
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.colors import hsv_to_rgb
from matplotlib.patches import Ellipse, FancyBboxPatch, Rectangle
from matplotlib.transforms import Affine2D


PAGE_W = 612
PAGE_H = 792
MARGIN = 36

PDF_SIDE_PAD = 3.0
PDF_KEY_GAP = 6.0
PDF_ROW_GAP = 13.0
PDF_TOP_PAD = 11.0
HEADER_BOTTOM = 56.0

LIVE_SIDE_PAD = 5.0
LIVE_KEY_GAP = 6.0
LIVE_ROW_GAP = 11.0

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


def safe_float(value: str | None, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def key_color(key: str, alpha: float = 1.0) -> tuple[float, float, float, float]:
    idx = ALL_KEYS.index(key) if key in ALL_KEYS else 0
    hue = (idx * 0.618033988749895) % 1.0
    sat = 0.82 if idx % 2 == 0 else 0.65
    rgb = hsv_to_rgb([hue, sat, 0.88])
    return (float(rgb[0]), float(rgb[1]), float(rgb[2]), alpha)


def key_for_expected(raw: str) -> str | None:
    if raw == " ":
        return "space"
    key = raw.strip().lower()
    return key if key in VALID_KEYS else None


def event_chars(row: dict[str, str], event_type: str, key_label: str) -> tuple[str, str]:
    """Mirror the app's event fields, with compatibility for older CSVs.

    Swift records `actualChar` for inserts/replaces and `correctedChar` as
    the character erased by a delete. The delete key label is the literal
    string "delete", so it must never be used as `correctedChar`.
    """
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
    with open(csv_path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))

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

        flags = row.get("outlier_flags", "")
        if "spatial" in flags or "far_from_target" in flags:
            continue

        actual_char, corrected_char = event_chars(row, event_type, key_label)
        events.append(Event(
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
        ))

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
    kw = inferred_letter_width(event)
    key_h = event.key_height
    if kw <= 0 or key_h <= 0:
        return None

    keyboard_w = 10.0 * kw + 2.0 * LIVE_SIDE_PAD + 9.0 * LIVE_KEY_GAP
    sp = (keyboard_w - 2.0 * LIVE_SIDE_PAD - 7.0 * kw - 8.0 * LIVE_KEY_GAP) / 2.0

    if key in ROW0:
        col = ROW0.index(key)
        return Rect(LIVE_SIDE_PAD + col * (kw + LIVE_KEY_GAP), 0.0, kw, key_h)
    if key in ROW1:
        col = ROW1.index(key)
        row_w = len(ROW1) * kw + (len(ROW1) - 1) * LIVE_KEY_GAP
        return Rect((keyboard_w - row_w) / 2.0 + col * (kw + LIVE_KEY_GAP),
                    key_h + LIVE_ROW_GAP, kw, key_h)
    if key in ROW2:
        col = ROW2.index(key)
        return Rect(LIVE_SIDE_PAD + sp + LIVE_KEY_GAP + col * (kw + LIVE_KEY_GAP),
                    2.0 * (key_h + LIVE_ROW_GAP), kw, key_h)
    if key == "delete":
        return Rect(keyboard_w - LIVE_SIDE_PAD - sp, 2.0 * (key_h + LIVE_ROW_GAP), sp, key_h)
    if key == "space":
        return Rect(LIVE_SIDE_PAD + sp + LIVE_KEY_GAP, 3.0 * (key_h + LIVE_ROW_GAP),
                    keyboard_w - 2.0 * LIVE_SIDE_PAD - 2.0 * sp - 2.0 * LIVE_KEY_GAP, key_h)
    return None


def deleted_insert_indices(events: list[Event]) -> set[int]:
    stack: list[int] = []
    deleted: set[int] = set()
    for idx, event in enumerate(events):
        if event.event_type in {"insert", "replace"} and event.actual_char:
            stack.append(idx)
        elif event.event_type == "delete" and stack:
            removed_idx = stack.pop()
            # Empty corrected_char means an older export did not preserve the
            # erased character; treat the backspace as feedback for the last
            # insert. Otherwise require the erased character to match.
            if not event.corrected_char or event.corrected_char == events[removed_idx].actual_char:
                deleted.add(removed_idx)
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
    for idx, event in enumerate(events):
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
        elif idx in deleted:
            continue
        elif event.is_correct:
            sample = sample_for(event, event.key_label)
        else:
            sample = None

        if sample:
            samples.append(sample)
    return samples


def fit_single(samples: list[TrainingSample]) -> Gaussian2D | None:
    n = len(samples)
    if n < MIN_SAMPLES:
        return None

    ox = [s.offset_x for s in samples]
    oy = [s.offset_y for s in samples]
    mean_kw = sum(s.key_width for s in samples) / n
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
        if (gaussian := fit_single(key_samples)) is not None:
            model[key] = gaussian
            model_sources[key] = SOURCE_FITTED_CURRENT
        elif prior_model and key in prior_model:
            model[key] = prior_model[key]
            model_sources[key] = SOURCE_PRIOR_MODEL

    return model, model_sources, sample_counts


def fallback_gaussian(frame: Rect) -> Gaussian2D:
    sigma = min(frame.w, frame.h) / 3.0
    s = sigma * sigma
    return Gaussian2D(0.0, 0.0, s, s, 0.0, 1.0 / s, 1.0 / s, 0.0, math.log(s * s), 0)


def spatial_prior(dx: float, dy: float, kw: float, kh: float) -> float:
    ox = max(0.0, abs(dx) - kw / 2.0)
    oy = max(0.0, abs(dy) - kh / 2.0)
    sx = SPATIAL_PRIOR_FRAC * kw
    sy = SPATIAL_PRIOR_FRAC * kh
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
    kw = (canvas_w - 2.0 * PDF_SIDE_PAD - 9.0 * PDF_KEY_GAP) / 10.0
    sp = (canvas_w - 2.0 * PDF_SIDE_PAD - 7.0 * kw - 8.0 * PDF_KEY_GAP) / 2.0
    key_h = round(kw * 1.35)
    frames: dict[str, Rect] = {}

    y0 = canvas_top + PDF_TOP_PAD
    for i, key in enumerate(ROW0):
        frames[key] = Rect(canvas_left + PDF_SIDE_PAD + i * (kw + PDF_KEY_GAP), y0, kw, key_h)

    y1 = y0 + key_h + PDF_ROW_GAP
    row1_start = canvas_left + (canvas_w - 9.0 * kw - 8.0 * PDF_KEY_GAP) / 2.0
    for i, key in enumerate(ROW1):
        frames[key] = Rect(row1_start + i * (kw + PDF_KEY_GAP), y1, kw, key_h)

    y2 = y1 + key_h + PDF_ROW_GAP
    row2_start = canvas_left + PDF_SIDE_PAD + sp + PDF_KEY_GAP
    for i, key in enumerate(ROW2):
        frames[key] = Rect(row2_start + i * (kw + PDF_KEY_GAP), y2, kw, key_h)

    frames["delete"] = Rect(canvas_left + canvas_w - PDF_SIDE_PAD - sp, y2, sp, key_h)
    y3 = y2 + key_h + PDF_ROW_GAP
    frames["space"] = Rect(canvas_left + PDF_SIDE_PAD + sp + PDF_KEY_GAP, y3,
                           canvas_w - 2.0 * PDF_SIDE_PAD - 2.0 * sp - 2.0 * PDF_KEY_GAP, key_h)
    return frames


def ellipse_params(gaussian: Gaussian2D, frame: Rect) -> tuple[float, float, float, float, float]:
    cx = frame.mid_x + gaussian.mu_x
    cy = frame.mid_y + gaussian.mu_y
    tr = gaussian.sxx + gaussian.syy
    det = gaussian.sxx * gaussian.syy - gaussian.sxy * gaussian.sxy
    disc = max(0.0, (tr * tr) / 4.0 - det)
    root = math.sqrt(disc)
    l1 = tr / 2.0 + root
    l2 = max(0.0, tr / 2.0 - root)
    if abs(gaussian.sxy) > 1e-12:
        angle = math.atan2(l1 - gaussian.sxx, gaussian.sxy)
    else:
        angle = 0.0 if gaussian.sxx >= gaussian.syy else math.pi / 2.0
    return cx, cy, math.sqrt(l1), math.sqrt(l2), angle


def render_pdf(
    out_path: Path,
    participant: str,
    events: list[Event],
    samples: list[TrainingSample],
    model: dict[str, Gaussian2D],
    model_sources: dict[str, str],
) -> None:
    fig = plt.figure(figsize=(PAGE_W / 72, PAGE_H / 72), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, PAGE_W)
    ax.set_ylim(PAGE_H, 0)
    ax.set_aspect("equal")
    ax.axis("off")

    ax.add_patch(Rectangle((0, 0), PAGE_W, 40, facecolor=(0.0, 0.55, 0.55, 0.9), edgecolor="none"))
    ax.text(MARGIN, 20, "Gaussian Keyboard - Intended-Key Boundaries",
            fontsize=14, fontweight="bold", color="white", va="center")
    fitted_count = sum(1 for source in model_sources.values() if source == SOURCE_FITTED_CURRENT)
    borrowed_count = sum(1 for source in model_sources.values() if source == SOURCE_PRIOR_MODEL)
    geometry_count = len(ALL_KEYS) - len(model)
    ax.text(PAGE_W - MARGIN, 20,
            f"{len(samples)} samples  fitted={fitted_count}  borrowed={borrowed_count}  geometry={geometry_count}",
            fontsize=10, family="monospace", color="white", ha="right", va="center")
    ax.text(MARGIN, 48,
            f"Participant: {participant or '-'}   min-n={MIN_SAMPLES}  anchor={ANCHOR_FRAC}  spatial={SPATIAL_PRIOR_FRAC}",
            fontsize=8, color="#777777", va="center")

    canvas_left = MARGIN + PDF_SIDE_PAD
    canvas_right = PAGE_W - MARGIN - PDF_SIDE_PAD
    canvas_top = HEADER_BOTTOM + 16.0
    canvas_w = canvas_right - canvas_left
    frames = build_pdf_frames(canvas_left, canvas_top, canvas_w)
    key_h = next(iter(frames.values())).h
    canvas_h = PDF_TOP_PAD + 4.0 * key_h + 3.0 * PDF_ROW_GAP + 8.0
    canvas = Rect(canvas_left, canvas_top, canvas_w, canvas_h)

    ax.add_patch(Rectangle((canvas.x, canvas.y), canvas.w, canvas.h,
                           facecolor=(0.07, 0.07, 0.09), edgecolor="none"))

    cols = int(math.ceil(canvas.w / RASTER_STEP))
    rows = int(math.ceil(canvas.h / RASTER_STEP))
    raster = np.zeros((rows, cols, 4), dtype=float)
    for row in range(rows):
        py = canvas.y + row * RASTER_STEP + RASTER_STEP / 2.0
        for col in range(cols):
            px = canvas.x + col * RASTER_STEP + RASTER_STEP / 2.0
            key = winner(px, py, frames, model)
            if key:
                raster[row, col] = key_color(key, 0.55)
    ax.imshow(
        raster,
        extent=(canvas.x, canvas.x + canvas.w, canvas.y + canvas.h, canvas.y),
        interpolation="nearest",
        zorder=1,
    )

    for key, frame in frames.items():
        ax.add_patch(FancyBboxPatch(
            (frame.x, frame.y), frame.w, frame.h,
            boxstyle="round,pad=0,rounding_size=5",
            facecolor=(0, 0, 0, 0),
            edgecolor=(1, 1, 1, 0.35),
            linewidth=0.6,
        ))
        label = "<" if key == "delete" else ("space" if key == "space" else key)
        ax.text(frame.x + 3, frame.y + frame.h - 4, label,
                fontsize=7 if len(key) > 1 else max(6, frame.h * 0.22),
                color=(1, 1, 1, 0.85), va="bottom", ha="left", fontweight="bold")

    for key, gaussian in model.items():
        frame = frames.get(key)
        if not frame:
            continue
        cx, cy, semi_a, semi_b, angle = ellipse_params(gaussian, frame)
        transform = Affine2D().rotate_around(cx, cy, angle) + ax.transData
        ax.add_patch(Ellipse((cx, cy), semi_a * 4, semi_b * 4,
                             fill=False, edgecolor=key_color(key, 0.50),
                             linewidth=0.5, linestyle="--", transform=transform))
        ax.add_patch(Ellipse((cx, cy), semi_a * 2, semi_b * 2,
                             fill=False, edgecolor=key_color(key, 0.95),
                             linewidth=1.0, transform=transform))
        ax.plot([cx - 3, cx + 3], [cy, cy], color="white", linewidth=0.9)
        ax.plot([cx, cx], [cy - 3, cy + 3], color="white", linewidth=0.9)

    grouped = defaultdict(list)
    for sample in samples:
        grouped[sample.target_key].append(sample)
    for key, key_samples in grouped.items():
        frame = frames.get(key)
        if not frame:
            continue
        for sample in key_samples:
            px = frame.mid_x + sample.offset_x
            py = frame.mid_y + sample.offset_y
            ax.scatter([px], [py], s=18, c=[(1, 1, 1, 0.35)], edgecolors="none", zorder=4)
            ax.scatter([px], [py], s=8, c=[key_color(key, 0.95)], edgecolors="none", zorder=5)

    legend_y = canvas.y + canvas.h + 20
    lx = canvas.x
    counts = Counter(sample.target_key for sample in samples)
    for key in ALL_KEYS:
        if counts[key] == 0:
            continue
        ax.scatter([lx + 3], [legend_y], s=18, c=[key_color(key, 1.0)], edgecolors="none")
        label = "del" if key == "delete" else ("sp" if key == "space" else key)
        ax.text(lx + 9, legend_y, f"{label} ({counts[key]})",
                fontsize=7, family="monospace", color="#777777", va="center")
        lx += 44
        if lx + 44 > canvas_right:
            break

    with PdfPages(out_path) as pdf:
        pdf.savefig(fig)
    plt.close(fig)


def print_summary(
    events: list[Event],
    samples: list[TrainingSample],
    model: dict[str, Gaussian2D],
    model_sources: dict[str, str],
    sample_counts: dict[str, int],
) -> None:
    old_counts = Counter(e.key_label for e in events if e.is_correct and e.event_type != "delete")
    new_counts = Counter(sample.target_key for sample in samples)
    print("Old correct-landed counts:")
    print("  " + " ".join(f"{k}={old_counts[k]}" for k in ALL_KEYS if old_counts[k]))
    print("New intended-feedback counts:")
    print("  " + " ".join(f"{k}={new_counts[k]}" for k in ALL_KEYS if new_counts[k]))
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
            f"{k}(trial_n={sample_counts.get(k, 0)}, source={model_sources.get(k, SOURCE_GEOMETRY_FALLBACK)}, model_n={model[k].count if k in model else 0})"
            for k in ALL_KEYS
            if sample_counts.get(k, 0) or k in model
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
    render_pdf(out_path, participant, events, samples, model, model_sources)

    print(f"Input : {in_path}")
    print(f"Output: {out_path}")
    print(f"Events used: {len(events)}")
    print(f"Training samples: {len(samples)}")
    print_summary(events, samples, model, model_sources, sample_counts)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
