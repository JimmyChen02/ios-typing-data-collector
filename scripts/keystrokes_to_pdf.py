#!/usr/bin/env python3
"""
keystrokes_to_pdf.py
--------------------
Generates a "Tap Distribution — Keyboard View" PDF from a cleaned keystroke
CSV (output of clean_keystrokes.py).

Mirrors the iOS KeyboardViewPDFExporter layout:
    * Purple banner header with participant + date + tap count
    * Dark keyboard canvas with 0.00–1.00 normalized grid
    * Per-key rounded rectangles + subtle top highlight
    * Tap dots colored per intended key, white halo, char centered in dot
    * Legend of keys actually present

Filtering (applied before plotting):
    * outlier_flags must NOT contain "spatial" or "far_from_target"
        → drops taps that landed >½ key-width outside the key boundary or
        more than 1.25 key-widths from the expected key.
        IKI outliers, trial-starts, and delete events are kept — those
        don't distort tap-location data.

Usage:
    python keystrokes_to_pdf.py <cleaned.csv> [output.pdf]

    If output path is omitted, writes <stem>_report.pdf next to the input.
"""

import sys
import csv
import time
from pathlib import Path
from datetime import datetime

import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.patches import Rectangle, Circle, FancyBboxPatch
from matplotlib.colors import hsv_to_rgb

# ── Layout constants (mirror Swift KeyboardViewPDFExporter) ──────────────
PAGE_W = 612
PAGE_H = 792
MARGIN = 36
SIDE_PAD = 3
KEY_GAP = 6
ROW_GAP = 13
TOP_PAD = 11
HEADER_H = 40
HEADER_BOTTOM = 56
DOT_R = 4.5

ROW0 = ["q","w","e","r","t","y","u","i","o","p"]
ROW1 = ["a","s","d","f","g","h","j","k","l"]
ROW2 = ["z","x","c","v","b","n","m"]
ALL_KEYS = ROW0 + ROW1 + ROW2 + ["space", "delete"]
VALID_KEYS = set(ALL_KEYS)


def safe_float(v, default=0.0):
    try:
        return float(v)
    except (ValueError, TypeError):
        return default


def key_color(key: str):
    idx = ALL_KEYS.index(key) if key in ALL_KEYS else 0
    hue = (idx * 0.618033988749895) % 1.0
    sat = 0.82 if idx % 2 == 0 else 0.65
    return hsv_to_rgb([hue, sat, 0.88])


def load_clean_rows(csv_path: Path):
    with open(csv_path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))

    if not rows:
        return [], "", ""

    first = rows[0].get("participant_first", "").strip()
    last  = rows[0].get("participant_last",  "").strip()
    participant = f"{first} {last}".strip()
    session_id = rows[0].get("session_id", "")

    valid = []
    for r in rows:
        if r.get("key_label", "") not in VALID_KEYS:
            continue
        if safe_float(r.get("key_width")) <= 0:
            continue
        flags = r.get("outlier_flags", "")
        if "spatial" in flags or "far_from_target" in flags:
            continue
        valid.append(r)
    return valid, participant, session_id


def build_frames(canvas_left, canvas_top, kw, sp, key_h, canvas_w):
    f: dict[str, tuple[float, float, float, float]] = {}
    y0 = canvas_top + TOP_PAD
    for i, k in enumerate(ROW0):
        f[k] = (canvas_left + SIDE_PAD + i * (kw + KEY_GAP), y0, kw, key_h)
    y1 = y0 + key_h + ROW_GAP
    row1_start = canvas_left + (canvas_w - 9 * kw - 8 * KEY_GAP) / 2
    for i, k in enumerate(ROW1):
        f[k] = (row1_start + i * (kw + KEY_GAP), y1, kw, key_h)
    y2 = y1 + key_h + ROW_GAP
    row2_start = canvas_left + SIDE_PAD + sp + KEY_GAP
    for i, k in enumerate(ROW2):
        f[k] = (row2_start + i * (kw + KEY_GAP), y2, kw, key_h)
    f["delete"] = (canvas_left + canvas_w - SIDE_PAD - sp, y2, sp, key_h)
    y3 = y2 + key_h + ROW_GAP
    f["space"] = (canvas_left + SIDE_PAD + sp + KEY_GAP, y3,
                  canvas_w - 2 * SIDE_PAD - 2 * sp - 2 * KEY_GAP, key_h)
    return f


def render_pdf(rows, participant: str, session_id: str, out_path: Path):
    fig = plt.figure(figsize=(PAGE_W / 72, PAGE_H / 72), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, PAGE_W)
    ax.set_ylim(PAGE_H, 0)
    ax.set_aspect("equal")
    ax.axis("off")

    # ── Purple header banner ──────────────────────────────────────────────
    ax.add_patch(Rectangle((0, 0), PAGE_W, HEADER_H,
                           facecolor="#AF52DE", alpha=0.85, edgecolor="none"))
    ax.text(MARGIN, 20, "Tap Distribution \u2014 Keyboard View",
            fontsize=14, fontweight="bold", color="white", va="center")
    ax.text(PAGE_W - MARGIN, 20, f"{len(rows)} taps",
            fontsize=11, family="monospace", color="white",
            va="center", ha="right")
    date_str = datetime.now().strftime("%Y-%m-%d")
    ax.text(MARGIN, 48,
            f"Participant: {participant or chr(0x2014)}   Date: {date_str}",
            fontsize=8, color="#888888", va="center")

    # ── Canvas geometry ──────────────────────────────────────────────────
    canvas_left = MARGIN + SIDE_PAD
    canvas_right = PAGE_W - MARGIN - SIDE_PAD
    canvas_top = HEADER_BOTTOM + 16
    canvas_w = canvas_right - canvas_left
    kw = (canvas_w - 2 * SIDE_PAD - 9 * KEY_GAP) / 10
    sp = (canvas_w - 2 * SIDE_PAD - 7 * kw - 8 * KEY_GAP) / 2
    key_h = round(kw * 1.35)
    canvas_h = TOP_PAD + 4 * key_h + 3 * ROW_GAP + 8

    frames = build_frames(canvas_left, canvas_top, kw, sp, key_h, canvas_w)

    # Dark background
    ax.add_patch(Rectangle((canvas_left, canvas_top), canvas_w, canvas_h,
                           facecolor=(0.07, 0.07, 0.09), edgecolor="none"))

    # Grid + axis labels
    for t in [0, 0.25, 0.5, 0.75, 1.0]:
        gx = canvas_left + t * canvas_w
        gy = canvas_top + t * canvas_h
        ax.plot([gx, gx], [canvas_top, canvas_top + canvas_h],
                color="white", alpha=0.08, linewidth=0.4)
        ax.plot([canvas_left, canvas_left + canvas_w], [gy, gy],
                color="white", alpha=0.08, linewidth=0.4)
        ax.text(gx, canvas_top + canvas_h + 8, f"{t:.2f}",
                fontsize=6.5, family="monospace", color="#888888",
                ha="center", va="top")
        ax.text(canvas_left - 6, gy, f"{t:.2f}",
                fontsize=6.5, family="monospace", color="#888888",
                ha="right", va="center")

    # Canvas border
    ax.add_patch(Rectangle((canvas_left, canvas_top), canvas_w, canvas_h,
                           facecolor="none", edgecolor=(1, 1, 1, 0.2),
                           linewidth=0.6))

    # ── Key outlines ──────────────────────────────────────────────────────
    for key, (x, y, w, h) in frames.items():
        is_special = len(key) > 1
        fv = 0.18 if is_special else 0.26
        ax.add_patch(FancyBboxPatch(
            (x, y), w, h,
            boxstyle="round,pad=0,rounding_size=5",
            facecolor=(fv, fv, fv),
            edgecolor=(1, 1, 1, 0.12),
            linewidth=0.5,
        ))
        # Top highlight
        ax.plot([x + 3, x + w - 3], [y + 0.5, y + 0.5],
                color=(1, 1, 1, 0.20), linewidth=0.7)
        # Key label (bottom-left corner)
        display = "\u232B" if key == "delete" else (
                  "\u23B5" if key == "space"  else key)
        font_size = 6 if len(key) > 1 else max(5, h * 0.22)
        ax.text(x + 3, y + h - 4, display,
                fontsize=font_size, color=(1, 1, 1, 0.70),
                va="bottom", ha="left")

    # ── Tap dots (batched via scatter) ──────────────────────────────────
    halo_x, halo_y = [], []
    dot_x, dot_y, dot_colors = [], [], []
    labels = []

    for r in rows:
        key = r.get("key_label", "")
        frame = frames.get(key)
        if not frame:
            continue
        tx = safe_float(r.get("tap_local_x"))
        ty = safe_float(r.get("tap_local_y"))
        kw_v = safe_float(r.get("key_width"))
        kh_v = safe_float(r.get("key_height"))
        if kw_v <= 0 or kh_v <= 0:
            continue
        nx = tx / kw_v
        ny = ty / kh_v
        fx, fy, fw, fh = frame
        px = fx + nx * fw
        py = fy + ny * fh

        expected = r.get("expected_char", "").strip()
        color_key = expected if expected in ALL_KEYS else key

        halo_x.append(px); halo_y.append(py)
        dot_x.append(px);  dot_y.append(py)
        dot_colors.append(key_color(color_key))

        if len(color_key) == 1:
            labels.append((px, py, color_key))

    halo_s = (DOT_R + 1) ** 2 * 4        # approx marker area
    dot_s  = DOT_R ** 2 * 4

    ax.scatter(halo_x, halo_y, s=halo_s, c=[(1, 1, 1, 0.8)],
               edgecolors="none", zorder=3)
    ax.scatter(dot_x, dot_y, s=dot_s,
               c=[(*c, 0.95) for c in dot_colors],
               edgecolors="none", zorder=4)
    for px, py, lbl in labels:
        ax.text(px, py, lbl, fontsize=DOT_R * 1.1, color="white",
                ha="center", va="center", fontweight="bold",
                family="monospace", zorder=5)

    # ── Legend ────────────────────────────────────────────────────────────
    legend_y = canvas_top + canvas_h + 25
    shown = sorted({
        (r.get("expected_char", "").strip() or r.get("key_label", ""))
        for r in rows
        if (r.get("expected_char", "").strip() or r.get("key_label", ""))
           in ALL_KEYS
    })
    lx = canvas_left
    for k in shown:
        ax.add_patch(Circle((lx + 3, legend_y), 3.5,
                            facecolor=key_color(k), edgecolor="none"))
        disp = "del" if k == "delete" else ("sp" if k == "space" else k)
        ax.text(lx + 9, legend_y, disp, fontsize=7,
                family="monospace", color="#888888", va="center")
        lx += 24
        if lx + 24 > canvas_right:
            break

    fig.savefig(out_path, format="pdf")
    plt.close(fig)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    in_path  = Path(sys.argv[1]).expanduser()
    out_path = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 \
               else in_path.with_name(in_path.stem + "_report.pdf")

    rows, participant, session_id = load_clean_rows(in_path)
    print(f"\nInput : {in_path}")
    print(f"Output: {out_path}")
    print(f"Rows plotted: {len(rows)} (excluded spatial + far_from_target outliers)")

    if not rows:
        print("No valid rows to plot.")
        sys.exit(1)

    render_pdf(rows, participant, session_id, out_path)
    print(f"\nPDF written to: {out_path}")


if __name__ == "__main__":
    _start_time = time.perf_counter()
    try:
        main()
    finally:
        print(f"Ran in {time.perf_counter() - _start_time:.2f} seconds")
