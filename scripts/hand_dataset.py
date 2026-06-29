#!/usr/bin/env python3
"""
hand_dataset.py
---------------
Reads the holding-hand manifest CSV exported from the TypingResearch iOS app
and returns (image_paths, labels) suitable for the training pipeline.

Manifest CSV schema (one row per HandSample):
    participant_first, participant_last, study_id, session_id,
    study_session_index, captured_at_iso, holding_hand,
    image_relative_path, image_pixel_width, image_pixel_height,
    camera_position, device_model, system_version, notes

`holding_hand` values: left | right | both | unknown
`image_relative_path` is relative to --images-root (e.g. "hand_images/<uuid>.jpg").

Usage:
    python3 scripts/hand_dataset.py <manifest.csv> --images-root <dir>
    python3 scripts/hand_dataset.py --demo

Outputs:
    Prints the number of loaded samples and the label distribution.
    Returns (image_paths, labels) when used as a module.

Missing images are skipped with a warning — never aborted.

External dataset layout
-----------------------
Any directory of JPEGs + a 14-column manifest in the schema above works
unchanged.  The participant grouping key is ``participant_first|participant_last``
(lowercased + stripped).  Time order within a participant is determined by
``study_session_index`` (ascending integer), then ``captured_at_iso``, then
``image_relative_path`` as stable tiebreakers.
"""

from __future__ import annotations

import argparse
import csv
import io
import sys
import tempfile
import warnings
from pathlib import Path

# ---------------------------------------------------------------------------
# Optional dependency: Pillow
# ---------------------------------------------------------------------------
try:
    from PIL import Image
    _PIL_AVAILABLE = True
except ImportError:
    _PIL_AVAILABLE = False


def _require_pil() -> None:
    if not _PIL_AVAILABLE:
        raise ImportError(
            "Pillow is required to load images.\n"
            "Install it with:  pip install pillow"
        )


# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------

VALID_LABELS = {"left", "right", "both", "unknown"}


def load_dataset(
    manifest_path: str,
    images_root: str,
) -> tuple[list[str], list[str]]:
    """Read *manifest_path* and resolve image paths under *images_root*.

    Rows whose image file is missing on disk are skipped with a warning.
    Rows with `holding_hand == "unknown"` are included but callers may wish
    to filter them before training.

    Returns
    -------
    image_paths : list[str]
        Absolute paths to image files.
    labels : list[str]
        Corresponding holding_hand labels ("left"/"right"/"both"/"unknown").
    """
    manifest = Path(manifest_path)
    root = Path(images_root)

    image_paths: list[str] = []
    labels: list[str] = []
    skipped = 0

    with manifest.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row_num, row in enumerate(reader, start=2):  # 2 = first data row
            label = (row.get("holding_hand") or "").strip().lower()
            rel_path = (row.get("image_relative_path") or "").strip()

            if label not in VALID_LABELS:
                warnings.warn(
                    f"Row {row_num}: unknown label {label!r} — skipping",
                    stacklevel=2,
                )
                skipped += 1
                continue

            if not rel_path:
                # Label-only sample (no photo taken); skip silently for image pipeline
                skipped += 1
                continue

            abs_path = root / rel_path
            if not abs_path.exists():
                warnings.warn(
                    f"Row {row_num}: image not found at {abs_path} — skipping",
                    stacklevel=2,
                )
                skipped += 1
                continue

            image_paths.append(str(abs_path))
            labels.append(label)

    return image_paths, labels


def load_dataset_records(
    manifest_path: str,
    images_root: str,
) -> list[dict]:
    """Return list[dict], one per usable row, each with keys:

        image_path        (str, absolute)
        label             (str, one of VALID_LABELS including 'unknown')
        participant_key   (str: f"{first}|{last}" lowercased+stripped)
        sort_key          (tuple: (study_session_index_int, captured_at_iso,
                           image_relative_path))

    Skips rows with missing/invalid label or missing image file (same rules as
    load_dataset: warn on not-found and bad-label, silent skip on empty
    image_relative_path).  Includes 'unknown' rows — caller filters.

    study_session_index parsing: int(...) with fallback to 10**9 on parse
    failure so unparseable rows sort last deterministically; warns once.
    """
    manifest = Path(manifest_path)
    root = Path(images_root)

    records: list[dict] = []
    _warned_parse = False

    with manifest.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row_num, row in enumerate(reader, start=2):
            label = (row.get("holding_hand") or "").strip().lower()
            rel_path = (row.get("image_relative_path") or "").strip()

            if label not in VALID_LABELS:
                warnings.warn(
                    f"Row {row_num}: unknown label {label!r} — skipping",
                    stacklevel=2,
                )
                continue

            if not rel_path:
                continue

            abs_path = root / rel_path
            if not abs_path.exists():
                warnings.warn(
                    f"Row {row_num}: image not found at {abs_path} — skipping",
                    stacklevel=2,
                )
                continue

            # Participant key
            first = (row.get("participant_first") or "").strip().lower()
            last = (row.get("participant_last") or "").strip().lower()
            participant_key = f"{first}|{last}"

            # Sort key — time order within a participant
            raw_idx = (row.get("study_session_index") or "").strip()
            try:
                session_idx = int(raw_idx)
            except (ValueError, TypeError):
                session_idx = 10 ** 9
                if not _warned_parse:
                    warnings.warn(
                        f"Row {row_num}: could not parse study_session_index "
                        f"{raw_idx!r}; assigning sentinel 10^9 for ordering.",
                        stacklevel=2,
                    )
                    _warned_parse = True

            captured_at = (row.get("captured_at_iso") or "").strip()
            sort_key = (session_idx, captured_at, rel_path)

            records.append({
                "image_path": str(abs_path),
                "label": label,
                "participant_key": participant_key,
                "sort_key": sort_key,
            })

    return records


def load_images(image_paths: list[str]) -> "list[Image.Image]":
    """Load PIL Images from *image_paths*. Requires Pillow."""
    _require_pil()
    images = []
    for p in image_paths:
        try:
            img = Image.open(p).convert("RGB")
            images.append(img)
        except Exception as exc:
            warnings.warn(f"Could not open {p}: {exc} — skipping", stacklevel=2)
    return images


# ---------------------------------------------------------------------------
# Demo synthetic data
# ---------------------------------------------------------------------------

def _make_demo_manifest_and_images(
    tmp_dir: Path,
) -> tuple[str, str]:
    """Create a synthetic multi-frame manifest + JPEG images for pipeline testing.

    Generates 2 participants x 3 conditions x 20 frames = 120 rows.
    Each (participant, condition) block has study_session_index 0..19 so
    the time-ordered 80/20 split is exercised.

    Per-condition images use a filled rectangle whose horizontal position
    encodes the class (left third / right third / center), giving the centroid
    baseline real separability signal.

    Returns (manifest_csv_path, images_root).
    """
    _require_pil()

    import random

    images_dir = tmp_dir / "hand_images"
    images_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = tmp_dir / "hand_manifest_demo.csv"
    fieldnames = [
        "participant_first", "participant_last", "study_id", "session_id",
        "study_session_index", "captured_at_iso", "holding_hand",
        "image_relative_path", "image_pixel_width", "image_pixel_height",
        "camera_position", "device_model", "system_version", "notes",
    ]

    # 2 participants, 3 conditions, 20 frames each
    participants = [
        ("Alice", "Alpha"),
        ("Bob",   "Beta"),
    ]
    conditions = ["left", "right", "both"]
    frames_per_condition = 20
    img_size = 64

    # Horizontal rectangle positions per condition (left-third / right-third / center)
    # Gives centroid baseline measurable signal
    condition_rect = {
        "left":  (0,            img_size // 3),          # x_start, x_end
        "right": (2 * img_size // 3, img_size),
        "both":  (img_size // 3, 2 * img_size // 3),
    }
    # Base colors per condition (slight variation added per frame for realism)
    condition_color = {
        "left":  (200, 100, 100),
        "right": (100, 200, 100),
        "both":  (100, 100, 200),
    }

    rng = random.Random(42)
    row_idx = 0

    with manifest_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()

        for p_first, p_last in participants:
            study_id = f"00000000-0000-0000-0000-{abs(hash(p_first)):012d}"[:47]
            for cond in conditions:
                x0, x1 = condition_rect[cond]
                base_r, base_g, base_b = condition_color[cond]
                for frame_idx in range(frames_per_condition):
                    img_name = f"demo_{row_idx:04d}.jpg"
                    img_path = images_dir / img_name

                    # White background + colored rectangle at the condition position
                    bg = Image.new("RGB", (img_size, img_size), color=(240, 240, 240))
                    # Add small noise to color (deterministic via rng)
                    noise = rng.randint(-10, 10)
                    rect_color = (
                        max(0, min(255, base_r + noise)),
                        max(0, min(255, base_g + noise)),
                        max(0, min(255, base_b + noise)),
                    )
                    # Draw the filled rectangle directly via pixel manipulation
                    arr_bg = list(bg.getdata())
                    w = img_size
                    for py in range(img_size // 4, 3 * img_size // 4):
                        for px in range(x0, x1):
                            arr_bg[py * w + px] = rect_color
                    bg.putdata(arr_bg)
                    bg.save(str(img_path), format="JPEG", quality=80)

                    captured_at = f"2026-01-01T{frame_idx:02d}:00:00Z"
                    writer.writerow({
                        "participant_first": p_first,
                        "participant_last":  p_last,
                        "study_id":          study_id,
                        "session_id":        f"session-{row_idx}",
                        "study_session_index": str(frame_idx),
                        "captured_at_iso":   captured_at,
                        "holding_hand":      cond,
                        "image_relative_path": f"hand_images/{img_name}",
                        "image_pixel_width":  str(img_size),
                        "image_pixel_height": str(img_size),
                        "camera_position":   "front",
                        "device_model":      "Demo",
                        "system_version":    "0.0",
                        "notes":             "",
                    })
                    row_idx += 1

    return str(manifest_path), str(tmp_dir)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest",
        nargs="?",
        help="Path to the hand manifest CSV. Omit with --demo.",
    )
    parser.add_argument(
        "--images-root",
        default=".",
        help="Directory that `image_relative_path` values are resolved against.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate a tiny synthetic dataset and run without real data.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.demo:
        print("-- demo mode: generating synthetic manifest and images --")
        tmp = Path(tempfile.mkdtemp(prefix="hand_dataset_demo_"))
        manifest_path, images_root = _make_demo_manifest_and_images(tmp)
        print(f"Manifest : {manifest_path}")
        print(f"Images   : {images_root}")
    else:
        if not args.manifest:
            print("Error: provide a manifest CSV path, or use --demo")
            sys.exit(1)
        manifest_path = args.manifest
        images_root = args.images_root

    image_paths, labels = load_dataset(manifest_path, images_root)

    print(f"\nLoaded {len(image_paths)} samples")
    if labels:
        from collections import Counter
        dist = Counter(labels)
        for label, count in sorted(dist.items()):
            print(f"  {label:<10} {count}")
    else:
        print("  (no samples found)")

    if image_paths:
        print(f"\nFirst image path : {image_paths[0]}")
        print(f"First label      : {labels[0]}")


if __name__ == "__main__":
    main()
