#!/usr/bin/env python3
"""Classify cursor.csv rows and write a compact cursor-behavior summary."""

import argparse
import csv
import os
import sys


SUMMARY_FIELDS = [
    "session_dir",
    "cursor_rows",
    "typing_rows",
    "selection_rows",
    "double_tap_selection_rows",
    "tap_reposition_rows",
    "drag_rows",
    "keyboard_gesture_rows",
    "other_rows",
]


def _number(row, key, number_type=float):
    value = row.get(key)
    if value in (None, ""):
        return None
    return number_type(value)


def resolve_cursor_input(cursor_input):
    """Accept either a session directory or cursor.csv itself."""
    path = os.path.abspath(os.fspath(cursor_input))
    if os.path.isdir(path):
        path = os.path.join(path, "cursor.csv")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"cursor CSV not found: {cursor_input}")
    return path


def classify_rows(cursor_path):
    """Return cursor rows with one derived cause per row."""
    classified = []
    previous_text_length = None

    with open(cursor_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {"sel_length", "delta_chars", "touch_phase", "tap_count",
                    "touch_age_ms", "ms_since_last_text_change", "text_length"}
        missing = sorted(required - set(reader.fieldnames or []))
        if missing:
            raise ValueError("cursor.csv is missing columns: " + ", ".join(missing))

        for row in reader:
            selection_length = _number(row, "sel_length", int) or 0
            delta_chars = _number(row, "delta_chars", int) or 0
            tap_count = _number(row, "tap_count", int) or 0
            touch_phase = row.get("touch_phase") or ""
            touch_age = _number(row, "touch_age_ms")
            since_edit = _number(row, "ms_since_last_text_change")
            text_length = _number(row, "text_length", int) or 0
            text_changed = (
                previous_text_length is not None
                and text_length != previous_text_length
            )
            typing = text_changed or (since_edit is not None and since_edit < 50)
            recent_touch = touch_age is not None and touch_age <= 100

            if typing:
                cause = "typing"
            elif tap_count == 2 and selection_length > 0:
                cause = "double_tap_selection"
            elif touch_phase == "began" and recent_touch:
                cause = "tap_reposition"
            elif touch_phase == "moved" and recent_touch:
                cause = "drag"
            elif delta_chars != 0 and not recent_touch:
                cause = "keyboard_gesture"
            else:
                cause = "other"

            enriched = dict(row)
            enriched["cause"] = cause
            classified.append(enriched)
            previous_text_length = text_length

    return classified


def summarize(cursor_path):
    cursor_path = resolve_cursor_input(cursor_path)
    rows = classify_rows(cursor_path)
    summary = {field: 0 for field in SUMMARY_FIELDS if field != "session_dir"}
    summary["session_dir"] = os.path.basename(os.path.dirname(cursor_path))
    summary["cursor_rows"] = len(rows)
    summary["selection_rows"] = sum(
        int(row.get("sel_length") or 0) > 0 for row in rows
    )
    cause_to_field = {
        "typing": "typing_rows",
        "double_tap_selection": "double_tap_selection_rows",
        "tap_reposition": "tap_reposition_rows",
        "drag": "drag_rows",
        "keyboard_gesture": "keyboard_gesture_rows",
        "other": "other_rows",
    }
    for row in rows:
        summary[cause_to_field[row["cause"]]] += 1
    return summary, rows


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarize cursor.csv behavior.")
    parser.add_argument("cursor_inputs", nargs="+", help="cursor.csv files or session folders")
    parser.add_argument("--out", required=True, help="summary CSV path")
    parser.add_argument(
        "--events-out",
        help="classified-row CSV path (only valid with one input)",
    )
    args = parser.parse_args(argv)
    if args.events_out and len(args.cursor_inputs) != 1:
        parser.error("--events-out requires exactly one cursor input")

    summaries = []
    classified_rows = None
    for cursor_input in args.cursor_inputs:
        summary, rows = summarize(cursor_input)
        summaries.append(summary)
        if args.events_out:
            classified_rows = rows

    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(summaries)

    if args.events_out:
        fieldnames = list(classified_rows[0]) if classified_rows else ["cause"]
        with open(args.events_out, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(classified_rows)

    print(f"wrote {len(summaries)} cursor summaries to {args.out}")
    if args.events_out:
        print(f"wrote {len(classified_rows)} classified cursor rows to {args.events_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
