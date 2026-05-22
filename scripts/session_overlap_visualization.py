#!/usr/bin/env python3
"""
Create per-session Gaussian boundary SVGs that mirror the older smooth session viewer.

For each study session, this script:

1. Fits the current session's per-key Gaussian model when a key has enough data.
2. Falls back to the cumulative prior-session model for sparse keys.
3. Uses the geometric key fallback only when no Gaussian exists for that key.

Outputs:

- `session_gaussian_boundaries_XX.svg`: one SVG per session snapshot
- `final_gaussian_ground_truth_boundary.svg`: final classic-only ground-truth SVG
- `session_gaussian_boundaries_XX.pdf`: one PDF per session snapshot
- `final_gaussian_ground_truth_boundary.pdf`: final classic-only ground-truth PDF
- `session_gaussian_boundaries_summary.csv`
- `session_gaussian_boundaries_by_key.csv`
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import tempfile
import time
from collections import Counter, defaultdict
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "matplotlib"))

import gaussian_keyboard_pdf as gkp


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
        help="Directory for SVG/PDF exports and CSV summaries.",
    )
    parser.add_argument(
        "--raster-step",
        type=float,
        default=gkp.RASTER_STEP,
        help="Raster sampling step for the boundary decision surface. Lower is smoother but slower.",
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Generate synthetic shifted sessions before rendering outputs.",
    )
    parser.add_argument(
        "--format",
        choices=["svg", "pdf", "both"],
        default="both",
        help="Output format for boundary renders (default: both).",
    )
    return parser.parse_args()


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
                        "outlier_flags": "",
                        "is_correct": "1",
                        "study_session_index": str(session_index),
                        "trial_index": str(tap_index // 6),
                        "trial_id": f"s{session_index}-trial-{tap_index // 6}",
                        "timestamp_ms": str(timestamp),
                        "expected_char": " " if key == "space" else key,
                        "key_label": key,
                        "tap_norm_x": f"{min(max(x, 0.05), 0.95):.6f}",
                        "tap_norm_y": f"{min(max(y, 0.05), 0.95):.6f}",
                        "tap_local_x": "0",
                        "tap_local_y": "0",
                        "key_width": "54",
                        "key_height": "72",
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


def visible_session_label(session_ids: list[int]) -> str:
    return ",".join(str(session_id + 1) for session_id in session_ids)


def source_counts(model_sources: dict[str, str]) -> Counter[str]:
    return Counter(model_sources.get(key, gkp.SOURCE_GEOMETRY_FALLBACK) for key in gkp.ALL_KEYS)


def make_page(
    *,
    title: str,
    participant: str,
    visible_sessions: list[int],
    prior_event_count: int,
    samples: list[gkp.TrainingSample],
    model: dict[str, gkp.Gaussian2D],
    model_sources: dict[str, str],
    classic_only: bool = False,
) -> gkp.PdfPage:
    return gkp.PdfPage(
        title=title,
        summary_text="",
        detail_text="",
        samples=samples,
        model=model,
        model_sources=model_sources,
    )


def write_summary_csvs(
    output_dir: Path,
    summary_rows: list[dict[str, str | int]],
    by_key_rows: list[dict[str, str | int]],
) -> None:
    with (output_dir / "session_gaussian_boundaries_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        fieldnames = [
            "visible_sessions",
            "latest_session",
            "session_events",
            "prior_events",
            "training_samples",
            "fitted_current_keys",
            "prior_model_keys",
            "geometry_fallback_keys",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(summary_rows)

    with (output_dir / "session_gaussian_boundaries_by_key.csv").open("w", newline="", encoding="utf-8") as handle:
        fieldnames = [
            "visible_sessions",
            "latest_session",
            "key",
            "source",
            "session_samples",
            "prior_model_samples",
            "model_samples",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(by_key_rows)


def write_outputs(
    events: list[gkp.Event],
    participant: str,
    output_dir: Path,
    output_format: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    grouped = grouped_session_events(events)
    if not grouped:
        raise SystemExit("No grouped session events were available after filtering.")

    session_ids = sorted(grouped)
    cumulative_prior_events: list[gkp.Event] = []
    summary_rows: list[dict[str, str | int]] = []
    by_key_rows: list[dict[str, str | int]] = []
    pdf_pages: list[gkp.PdfPage] = []
    wants_svg = output_format in {"svg", "both"}
    wants_pdf = output_format in {"pdf", "both"}

    for count, session_id in enumerate(session_ids, start=1):
        visible_sessions = session_ids[:count]
        current_events = grouped[session_id]

        prior_samples = gkp.training_samples(cumulative_prior_events)
        prior_model, _, _ = gkp.fit_model(prior_samples)

        current_samples = gkp.training_samples(current_events)
        model, model_sources, sample_counts = gkp.fit_model(current_samples, prior_model=prior_model)
        page = make_page(
            title=f"Gaussian Trial {session_id + 1}",
            participant=participant,
            visible_sessions=visible_sessions,
            prior_event_count=len(cumulative_prior_events),
            samples=current_samples,
            model=model,
            model_sources=model_sources,
        )
        if wants_svg:
            gkp.render_boundary_svg(
                output_dir / f"session_gaussian_boundaries_{count:02d}.svg",
                model=model,
                raster_step=gkp.RASTER_STEP,
            )
        if wants_pdf:
            gkp.render_pdf_pages(
                output_dir / f"session_gaussian_boundaries_{count:02d}.pdf",
                participant,
                [page],
            )
            pdf_pages.append(page)

        counts = source_counts(model_sources)
        summary_rows.append(
            {
                "visible_sessions": visible_session_label(visible_sessions),
                "latest_session": session_id + 1,
                "session_events": len(current_events),
                "prior_events": len(cumulative_prior_events),
                "training_samples": len(current_samples),
                "fitted_current_keys": counts[gkp.SOURCE_FITTED_CURRENT],
                "prior_model_keys": counts[gkp.SOURCE_PRIOR_MODEL],
                "geometry_fallback_keys": counts[gkp.SOURCE_GEOMETRY_FALLBACK],
            }
        )

        for key in gkp.ALL_KEYS:
            source = model_sources.get(key, gkp.SOURCE_GEOMETRY_FALLBACK)
            by_key_rows.append(
                {
                    "visible_sessions": visible_session_label(visible_sessions),
                    "latest_session": session_id + 1,
                    "key": key,
                    "source": source,
                    "session_samples": sample_counts.get(key, 0),
                    "prior_model_samples": prior_model[key].count if key in prior_model else 0,
                    "model_samples": model[key].count if key in model else 0,
                }
            )

        cumulative_prior_events.extend(current_events)

    classic_events = [event for event in events if event.session_mode == "classic"]
    if classic_events:
        classic_samples = gkp.training_samples(classic_events)
        classic_model, classic_sources, _ = gkp.fit_model(classic_samples)
        classic_page = make_page(
            title="Gaussian Ground Truth",
            participant=participant,
            visible_sessions=sorted({event.study_session_index for event in classic_events}),
            prior_event_count=0,
            samples=classic_samples,
            model=classic_model,
            model_sources=classic_sources,
            classic_only=True,
        )
        if wants_svg:
            gkp.render_boundary_svg(
                output_dir / "final_gaussian_ground_truth_boundary.svg",
                model=classic_model,
                raster_step=gkp.RASTER_STEP,
            )
        if wants_pdf:
            gkp.render_pdf_pages(
                output_dir / "final_gaussian_ground_truth_boundary.pdf",
                participant,
                [classic_page],
            )

    if wants_pdf and pdf_pages:
        gkp.render_pdf_pages(
            output_dir / "session_gaussian_boundaries_all_sessions.pdf",
            participant,
            pdf_pages,
        )

    write_summary_csvs(output_dir, summary_rows, by_key_rows)


def main() -> None:
    start = time.perf_counter()
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()

    if args.demo:
        csv_path = output_dir / "synthetic_session_overlap_input.csv"
        write_demo_csv(csv_path)
    elif args.csv_path:
        csv_path = Path(args.csv_path).resolve()
    else:
        raise SystemExit("Provide a CSV path or use --demo.")

    gkp.RASTER_STEP = max(float(args.raster_step), 1.0)

    events, participant = gkp.read_events(csv_path)
    if not events:
        raise SystemExit(f"No usable events found in {csv_path}")

    write_outputs(events, participant, output_dir, args.format)
    session_ids = sorted(grouped_session_events(events))

    print(f"Input CSV: {csv_path}")
    print(f"Output dir: {output_dir}")
    print(f"Sessions: {', '.join(str(index + 1) for index in session_ids)}")
    print("Primary outputs:")
    if args.format in {"svg", "both"}:
        print("  - session_gaussian_boundaries_XX.svg")
        print("  - final_gaussian_ground_truth_boundary.svg")
    if args.format in {"pdf", "both"}:
        print("  - session_gaussian_boundaries_XX.pdf")
        print("  - session_gaussian_boundaries_all_sessions.pdf")
        print("  - final_gaussian_ground_truth_boundary.pdf")
    print("  - session_gaussian_boundaries_summary.csv")
    print("  - session_gaussian_boundaries_by_key.csv")
    print(f"Ran in {time.perf_counter() - start:.2f} seconds")


if __name__ == "__main__":
    main()
