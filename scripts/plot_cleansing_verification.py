#!/usr/bin/env python3
"""
plot_cleansing_verification.py
------------------------------
Plots raw vs cleaned tap data side-by-side on a QWERTY keyboard layout.
Each dot sits at the actual tap position, colored by intended (expected) key.

Modes:
  Standard (raw + one cleaned):
      python plot_cleansing_verification.py <raw.csv> <cleaned.csv> [output.png] [--max N]

  Threshold comparison (raw + one panel per threshold):
      python plot_cleansing_verification.py <raw.csv> --compare 1.0 1.25 1.5 [--max N]

      Cleans the raw CSV at each threshold, writes _cleaned_t<N>.csv files,
      then shows them all side-by-side. Output defaults to <stem>_compare.png.

  --max N   Max dots per intended key (default: all). Use 30-50 for cleaner visuals.
"""

import subprocess
import sys
import csv
import random
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyBboxPatch
    import matplotlib.patheffects as pe
except ImportError:
    print("matplotlib is required:  python3 -m pip install matplotlib")
    sys.exit(1)

# ── Color scheme: tab20 + tab20b, one distinct color per key ─────────────────

ALL_KEYS = [
    "q","w","e","r","t","y","u","i","o","p",
    "a","s","d","f","g","h","j","k","l",
    "z","x","c","v","b","n","m",
    "space","delete"
]

_c20  = matplotlib.colormaps.get_cmap("tab20").resampled(20)
_c20b = matplotlib.colormaps.get_cmap("tab20b").resampled(20)
_palette = [_c20(i)[:3] for i in range(20)] + [_c20b(i)[:3] for i in range(8)]
KEY_COLOR = {k: _palette[i] for i, k in enumerate(ALL_KEYS)}

# ── Keyboard layout (mirrors TapDotPlotView buildAlphaFrames) ────────────────

ROW0 = list("qwertyuiop")
ROW1 = list("asdfghjkl")
ROW2 = list("zxcvbnm")

SIDE_PAD = 3
KEY_GAP  = 6
ROW_GAP  = 11
TOP_PAD  = 11
KEY_H    = 42
CANVAS_W = 390

def build_frames(W=CANVAS_W):
    kw = (W - 2*SIDE_PAD - 9*KEY_GAP) / 10
    sp = (W - 2*SIDE_PAD - 7*kw - 8*KEY_GAP) / 2
    f = {}
    y0 = TOP_PAD
    for i, k in enumerate(ROW0):
        f[k] = (SIDE_PAD + i*(kw+KEY_GAP), y0, kw, KEY_H)
    y1 = y0 + KEY_H + ROW_GAP
    row1_start = (W - 9*kw - 8*KEY_GAP) / 2
    for i, k in enumerate(ROW1):
        f[k] = (row1_start + i*(kw+KEY_GAP), y1, kw, KEY_H)
    y2 = y1 + KEY_H + ROW_GAP
    row2_start = SIDE_PAD + sp + KEY_GAP
    for i, k in enumerate(ROW2):
        f[k] = (row2_start + i*(kw+KEY_GAP), y2, kw, KEY_H)
    f["delete"] = (W - SIDE_PAD - sp, y2, sp, KEY_H)
    y3 = y2 + KEY_H + ROW_GAP
    f["space"] = (SIDE_PAD + sp + KEY_GAP, y3,
                  W - 2*SIDE_PAD - 2*sp - 2*KEY_GAP, KEY_H)
    return f

FRAMES   = build_frames()
CANVAS_H = TOP_PAD + 4*KEY_H + 3*ROW_GAP + 3


def load_rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def safe_float(val, default=0.0):
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def collect_taps(rows, cleaned_only=False):
    """Return {expected_key: [row, ...]} filtering deletes and bad tap data."""
    by_key = {}
    for row in rows:
        if row.get("event_type", "").strip().lower() == "delete":
            continue
        if cleaned_only and row.get("is_outlier", "0").strip() != "0":
            continue
        key_label = row.get("key_label", "").strip().lower()
        if key_label not in FRAMES:
            continue
        if safe_float(row.get("key_width")) <= 0 or safe_float(row.get("key_height")) <= 0:
            continue
        expected = row.get("expected_char", "").strip().lower()
        if expected == " ":
            expected = "space"
        by_key.setdefault(expected, []).append(row)
    return by_key


def collect_geometric_clean(rows):
    """Rows that passed geometric filters — is_outlier=0 OR only sigma_outlier flagged."""
    by_key = {}
    for row in rows:
        if row.get("event_type", "").strip().lower() == "delete":
            continue
        flags = [f.strip() for f in row.get("outlier_flags", "").split("|") if f.strip()]
        if any(f != "sigma_outlier" for f in flags):
            continue
        key_label = row.get("key_label", "").strip().lower()
        if key_label not in FRAMES:
            continue
        if safe_float(row.get("key_width")) <= 0 or safe_float(row.get("key_height")) <= 0:
            continue
        expected = row.get("expected_char", "").strip().lower()
        if expected == " ":
            expected = "space"
        by_key.setdefault(expected, []).append(row)
    return by_key


def draw_sigma_outliers(ax, by_key):
    """Draw sigma-only outliers as red X marks."""
    n = 0
    for key_rows in by_key.values():
        for row in key_rows:
            flags = [f.strip() for f in row.get("outlier_flags", "").split("|") if f.strip()]
            if "sigma_outlier" not in flags:
                continue
            px, py = _tap_canvas_pos(row)
            if px is None:
                continue
            ax.plot(px, py, "x", color="red", markersize=7, markeredgewidth=1.8, zorder=6)
            n += 1
    return n


def build_sigma_chart(sigma_rows, output_path, max_per_key=None):
    """Two-panel chart: left = geometric-clean taps + red X for sigma outliers,
    right = final clean (sigma removed)."""
    geo_by_key    = collect_geometric_clean(sigma_rows)
    clean_by_key  = collect_taps(sigma_rows, cleaned_only=True)

    if max_per_key:
        geo_by_key   = subsample(geo_by_key,   max_per_key)
        clean_by_key = subsample(clean_by_key, max_per_key)

    panel_w = CANVAS_W / 72 * 2.2
    panel_h = CANVAS_H / 72 * 2.2

    fig, (ax_before, ax_after) = plt.subplots(1, 2, figsize=(panel_w * 2, panel_h + 0.7))

    # Left: geometric-clean taps with sigma outliers highlighted
    draw_keyboard(ax_before)
    n_dots = draw_taps(ax_before, geo_by_key)
    n_x    = draw_sigma_outliers(ax_before, geo_by_key)
    ax_before.set_title(
        f"After geometric filter  —  {n_dots} taps\n"
        f"Red ✕ = sigma outliers ({n_x} taps that would be removed)",
        fontsize=9, pad=6,
    )
    ax_before.set_xlim(0, CANVAS_W)
    ax_before.set_ylim(0, CANVAS_H)
    ax_before.set_aspect("equal")
    ax_before.axis("off")

    # Right: after sigma removal
    draw_keyboard(ax_after)
    n_clean = draw_taps(ax_after, clean_by_key)
    ax_after.set_title(
        f"After sigma filter  —  {n_clean} taps\n"
        f"({n_x} sigma outliers removed)",
        fontsize=9, pad=6,
    )
    ax_after.set_xlim(0, CANVAS_W)
    ax_after.set_ylim(0, CANVAS_H)
    ax_after.set_aspect("equal")
    ax_after.axis("off")

    fig.tight_layout(pad=0.5)
    fig.savefig(output_path, dpi=180, bbox_inches="tight", facecolor="white")
    print(f"Saved: {output_path}")


def subsample(by_key, max_per_key):
    return {k: (random.sample(v, max_per_key) if len(v) > max_per_key else v)
            for k, v in by_key.items()}


def draw_keyboard(ax):
    for key, (x, y, w, h) in FRAMES.items():
        ax.add_patch(FancyBboxPatch(
            (x, CANVAS_H - y - h), w, h,
            boxstyle="round,pad=0,rounding_size=5",
            linewidth=0.5, edgecolor="#cccccc", facecolor="#e8e8e8", zorder=1
        ))
        label = "del" if key == "delete" else ("spc" if key == "space" else key)
        ax.text(x + w/2, CANVAS_H - y - h + 6, label,
                ha="center", va="bottom", fontsize=6, color="#999999",
                fontfamily="monospace", zorder=2)


def _tap_canvas_pos(row):
    """Absolute canvas position of a tap based on the hit key's frame."""
    key_label = row.get("key_label", "").strip().lower()
    if key_label not in FRAMES:
        return None, None
    fx, fy, fw, fh = FRAMES[key_label]
    norm_x = safe_float(row.get("tap_norm_x"), 0.5)
    norm_y = safe_float(row.get("tap_norm_y"), 0.5)
    return fx + norm_x * fw, CANVAS_H - (fy + norm_y * fh)


def draw_taps(ax, by_key):
    dot_r = 3.5
    n = 0
    for expected, key_rows in by_key.items():
        color = KEY_COLOR.get(expected, (0.6, 0.6, 0.6))
        dot_label = "·" if expected == "space" else ("⌫" if expected == "delete" else expected)
        for row in key_rows:
            px, py = _tap_canvas_pos(row)
            if px is None:
                continue

            ax.add_patch(plt.Circle((px, py), dot_r + 1.0, color="white", alpha=0.75, zorder=3))
            ax.add_patch(plt.Circle((px, py), dot_r, color=color, alpha=0.90, zorder=4))
            ax.text(px, py, dot_label,
                    ha="center", va="center",
                    fontsize=max(4, dot_r * 1.1), fontweight="bold",
                    color="white", zorder=5,
                    path_effects=[pe.withStroke(linewidth=0.5, foreground="white")])
            n += 1
    return n


SPATIAL_FLAGS = {"spatial", "far_from_target", "sigma_outlier"}


def collect_flagged_taps(rows):
    """Rows flagged for spatial reasons only — timing/delete/trial_start flags are not visualized."""
    by_key = {}
    for row in rows:
        if row.get("event_type", "").strip().lower() == "delete":
            continue
        if row.get("is_outlier", "0").strip() != "1":
            continue
        flags = {f.strip() for f in row.get("outlier_flags", "").split("|") if f.strip()}
        if not (flags & SPATIAL_FLAGS):
            continue
        key_label = row.get("key_label", "").strip().lower()
        if key_label not in FRAMES:
            continue
        if safe_float(row.get("key_width")) <= 0 or safe_float(row.get("key_height")) <= 0:
            continue
        expected = row.get("expected_char", "").strip().lower()
        if expected == " ":
            expected = "space"
        by_key.setdefault(expected, []).append(row)
    return by_key


def draw_flagged_marks(ax, by_key):
    """Draw flagged outlier taps as red X marks."""
    n = 0
    for key_rows in by_key.values():
        for row in key_rows:
            px, py = _tap_canvas_pos(row)
            if px is None:
                continue
            ax.plot(px, py, "x", color="red", markersize=7, markeredgewidth=1.8, zorder=6)
            n += 1
    return n


def build_chart(cleaned_rows, output_path, max_per_key=None):
    all_by_key   = collect_taps(cleaned_rows, cleaned_only=False)
    clean_by_key = collect_taps(cleaned_rows, cleaned_only=True)

    if max_per_key:
        all_by_key   = subsample(all_by_key,   max_per_key)
        clean_by_key = subsample(clean_by_key, max_per_key)

    panel_w = CANVAS_W / 72 * 2.2
    panel_h = CANVAS_H / 72 * 2.2
    fig, (ax_before, ax_after) = plt.subplots(1, 2, figsize=(panel_w * 2, panel_h + 0.7))

    for ax, by_key, label in [
        (ax_before, all_by_key,   "All taps"),
        (ax_after,  clean_by_key, "Cleaned (is_outlier=0)"),
    ]:
        draw_keyboard(ax)
        n = draw_taps(ax, by_key)
        suffix = f"  ·  max {max_per_key}/key" if max_per_key else ""
        ax.set_title(f"{label} — {n} taps{suffix}", fontsize=9, pad=6)
        ax.set_xlim(0, CANVAS_W)
        ax.set_ylim(0, CANVAS_H)
        ax.set_aspect("equal")
        ax.axis("off")

    fig.tight_layout(pad=0.5)
    fig.savefig(output_path, dpi=180, bbox_inches="tight", facecolor="white")
    print(f"Saved: {output_path}")


def build_compare_chart(raw_rows, panels, output_path, title="Tap distribution comparison", max_per_key=None):
    """N+1 panel figure: raw on the left, one panel per (label, cleaned_rows) entry."""
    n_panels = 1 + len(panels)
    panel_w  = CANVAS_W / 72 * 1.9
    panel_h  = CANVAS_H / 72 * 1.9

    fig, axes = plt.subplots(1, n_panels, figsize=(panel_w * n_panels, panel_h + 0.7))

    raw_by_key = collect_taps(raw_rows, cleaned_only=False)
    if max_per_key:
        raw_by_key = subsample(raw_by_key, max_per_key)
    draw_keyboard(axes[0])
    n = draw_taps(axes[0], raw_by_key)
    axes[0].set_title(f"Raw — {n} taps", fontsize=9, pad=6)
    axes[0].set_xlim(0, CANVAS_W)
    axes[0].set_ylim(0, CANVAS_H)
    axes[0].set_aspect("equal")
    axes[0].axis("off")

    for ax, (label, cleaned_rows) in zip(axes[1:], panels):
        by_key = collect_taps(cleaned_rows, cleaned_only=True)
        if max_per_key:
            by_key = subsample(by_key, max_per_key)
        draw_keyboard(ax)
        n = draw_taps(ax, by_key)
        n_flagged = sum(1 for r in cleaned_rows if r.get("is_outlier") == "1")
        ax.set_title(f"{label}\n{n} clean  ({n_flagged} flagged)", fontsize=9, pad=6)
        ax.set_xlim(0, CANVAS_W)
        ax.set_ylim(0, CANVAS_H)
        ax.set_aspect("equal")
        ax.axis("off")

    fig.suptitle(title, fontsize=10, y=1.01)
    fig.tight_layout(pad=0.5)
    fig.savefig(output_path, dpi=150, bbox_inches="tight", facecolor="white")
    print(f"Saved: {output_path}")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    # Parse shared flags first
    max_per_key = None
    thresholds  = []
    out_path    = None
    positional  = []
    show_sigma  = False

    i = 0
    while i < len(args):
        if args[i] == "--max" and i + 1 < len(args):
            max_per_key = int(args[i + 1])
            i += 2
        elif args[i] == "--compare":
            i += 1
            while i < len(args) and not args[i].startswith("--"):
                thresholds.append(float(args[i]))
                i += 1
        elif args[i] == "--show-sigma":
            show_sigma = True
            i += 1
        elif not args[i].startswith("--"):
            positional.append(args[i])
            i += 1
        else:
            i += 1

    raw_csv = positional[0] if positional else None
    if not raw_csv:
        print(__doc__)
        sys.exit(1)

    # ── Compare mode ─────────────────────────────────────────────────────────
    if thresholds:
        if not thresholds:
            print("--compare requires at least one threshold value, e.g. --compare 1.0 1.25 1.5")
            sys.exit(1)

        cleaner = str(Path(__file__).parent / "clean_keystrokes.py")
        threshold_panels = []
        for t in thresholds:
            t_str = str(t)
            cleaned_path = str(
                Path(raw_csv).with_name(f"{Path(raw_csv).stem}_cleaned_t{t_str}.csv")
            )
            print(f"Cleaning with threshold={t} → {Path(cleaned_path).name}")
            subprocess.run(
                [sys.executable, cleaner, raw_csv, cleaned_path, "--threshold", t_str],
                check=True,
            )
            threshold_panels.append((t, load_rows(cleaned_path)))

        if out_path is None:
            t_str = "_".join(str(t) for t in thresholds)
            out_path = str(Path(raw_csv).with_name(f"{Path(raw_csv).stem}_compare_t{t_str}.png"))

        raw_rows = load_rows(raw_csv)
        print(f"Raw: {len(raw_rows)} rows")
        if max_per_key:
            print(f"Subsampling to max {max_per_key} taps per intended key")
        build_compare_chart(raw_rows, threshold_panels, out_path, max_per_key=max_per_key)
        return

    # ── Sigma highlight mode ──────────────────────────────────────────────────
    if show_sigma:
        if len(positional) < 2:
            print("Usage: plot_cleansing_verification.py <raw.csv> <sigma_cleaned.csv> --show-sigma")
            sys.exit(1)
        sigma_csv = positional[1]
        if out_path is None:
            stem     = Path(sigma_csv).stem
            suffix   = f"_max{max_per_key}" if max_per_key else ""
            out_path = str(Path(sigma_csv).with_name(stem + suffix + "_sigma_chart.png"))
        sigma_rows = load_rows(sigma_csv)
        print(f"Sigma-cleaned CSV: {len(sigma_rows)} rows")
        build_sigma_chart(sigma_rows, out_path, max_per_key=max_per_key)
        return

    # ── Standard mode (raw + one cleaned) ────────────────────────────────────
    if len(positional) < 2:
        print(__doc__)
        sys.exit(1)

    cleaned_csv = positional[1]
    if len(positional) > 2:
        out_path = positional[2]

    if out_path is None:
        stem     = Path(cleaned_csv).stem
        suffix   = f"_max{max_per_key}" if max_per_key else ""
        out_path = str(Path(cleaned_csv).with_name(stem + suffix + "_keyboard_chart.png"))

    cleaned_rows = load_rows(cleaned_csv)

    print(f"Cleaned: {len(cleaned_rows)} rows")
    if max_per_key:
        print(f"Subsampling to max {max_per_key} taps per intended key")

    build_chart(cleaned_rows, out_path, max_per_key=max_per_key)


if __name__ == "__main__":
    main()
