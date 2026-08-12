#!/usr/bin/env python3
"""Label keystrokes.csv `replace`/`paste` rows with what the user actually did.

The app logs text changes by shape, not intent: autocorrect, a QuickType tap, an
inline prediction accepted with space, smart punctuation and sentence
capitalization all arrive as identical `shouldChangeTextIn` calls and all come
out as `replace`. iOS exposes no API for the source of a change, so intent is
reconstructed here rather than at capture time — a bad rule is then fixed by
re-running this script instead of re-collecting sessions.

Four of the labels are certain, two are inferred. See `substitution_kind` in
.claude/data-dictionary.md.
"""

import argparse
import csv
import os
import string


SUMMARY_FIELDS = [
    "session_dir",
    "keystroke_rows",
    "substitution_rows",
    "manual_overtype_rows",
    "sentence_caps_rows",
    "smart_punct_rows",
    "quicktype_pick_rows",
    "inline_prediction_rows",
    "autocorrect_rows",
    "unknown_rows",
]

# A substitution fired by the keystroke that triggered it lands within a few
# tens of ms. A QuickType tap has no preceding keystroke at all, so this only
# needs to be loose enough to absorb scheduling jitter.
TRIGGER_WINDOW_MS = 200.0

TRIGGER_CHARS = {" ", ".", ",", "!", "?", ";", ":", "\n"}

PUNCTUATION = set(string.punctuation) | {"‘", "’", "“", "”", "–", "—"}


def _number(row, key, number_type=float):
    value = row.get(key)
    if value in (None, ""):
        return None
    return number_type(value)


def resolve_keystrokes_input(keystrokes_input):
    """Accept either a session directory or keystrokes.csv itself."""
    path = os.path.abspath(os.fspath(keystrokes_input))
    if os.path.isdir(path):
        path = os.path.join(path, "keystrokes.csv")
    if not os.path.isfile(path):
        raise FileNotFoundError(f"keystrokes CSV not found: {keystrokes_input}")
    return path


def _is_punctuation(text):
    return bool(text) and all(character in PUNCTUATION for character in text)


def _is_case_variant(old, new):
    return len(old) == 1 and len(new) == 1 and old != new and old.lower() == new.lower()


def _extends(old, new):
    """True when `new` completes `old` rather than correcting it.

    `tomo` -> `tomorrow` is a completion; `teh` -> `the` is a correction. This
    is what separates an inline prediction from an autocorrect when both were
    accepted with the same space keystroke.
    """
    stripped = new.rstrip()
    return bool(old) and len(stripped) > len(old) and stripped.lower().startswith(old.lower())


def classify_rows(keystrokes_path):
    """Return keystroke rows, each with a derived `substitution_kind`.

    Rows that are not substitutions get an empty label rather than a made-up
    one — only `replace` and `paste` are ambiguous.
    """
    classified = []
    previous_insert_char = None
    previous_insert_t_ms = None

    with open(keystrokes_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            event_type = row.get("event_type")
            t_ms = _number(row, "t_ms")
            old = row.get("replaced_text") or ""
            new = row.get("replacement_text") or ""

            if event_type in ("replace", "paste"):
                row["substitution_kind"] = _classify_substitution(
                    row, old, new, t_ms, previous_insert_char, previous_insert_t_ms
                )
            else:
                row["substitution_kind"] = ""

            if event_type == "insert":
                previous_insert_char = new
                previous_insert_t_ms = t_ms

            classified.append(row)

    return classified


def _classify_substitution(row, old, new, t_ms, previous_insert_char, previous_insert_t_ms):
    # Certain: the system never substitutes into a selection, so a non-zero
    # selection means the user highlighted their own text and typed over it.
    if (_number(row, "selected_length_before", int) or 0) > 0:
        return "manual_overtype"

    # Certain: one character each side differing only in case.
    if _is_case_variant(old, new):
        return "sentence_caps"

    # Certain: punctuation swapped for punctuation.
    if _is_punctuation(old) and _is_punctuation(new):
        return "smart_punct"

    triggered = (
        previous_insert_char in TRIGGER_CHARS
        and t_ms is not None
        and previous_insert_t_ms is not None
        and (t_ms - previous_insert_t_ms) <= TRIGGER_WINDOW_MS
    )

    # Certain: nothing preceded this change, so the user tapped the bar. Both
    # autocorrect and an accepted inline prediction require a keystroke.
    if not triggered:
        return "quicktype_pick"

    # Mechanical when present: marked text means a prediction was pending.
    if (_number(row, "marked_text_before", int) or 0) == 1:
        return "inline_prediction"

    # Inferred: completion vs correction, both accepted by the same space.
    if _extends(old, new):
        return "inline_prediction"
    if old:
        return "autocorrect"
    return "unknown"


def summarize(keystrokes_input):
    keystrokes_path = resolve_keystrokes_input(keystrokes_input)
    rows = classify_rows(keystrokes_path)
    summary = {field: 0 for field in SUMMARY_FIELDS if field != "session_dir"}
    summary["session_dir"] = os.path.basename(os.path.dirname(keystrokes_path))
    summary["keystroke_rows"] = len(rows)

    kind_to_field = {
        "manual_overtype": "manual_overtype_rows",
        "sentence_caps": "sentence_caps_rows",
        "smart_punct": "smart_punct_rows",
        "quicktype_pick": "quicktype_pick_rows",
        "inline_prediction": "inline_prediction_rows",
        "autocorrect": "autocorrect_rows",
        "unknown": "unknown_rows",
    }
    for row in rows:
        kind = row["substitution_kind"]
        if kind:
            summary["substitution_rows"] += 1
            summary[kind_to_field[kind]] += 1
    return summary, rows


def main(argv=None):
    parser = argparse.ArgumentParser(description="Label keystrokes.csv substitutions.")
    parser.add_argument("keystrokes_inputs", nargs="+", help="keystrokes.csv files or session folders")
    parser.add_argument("--out", required=True, help="summary CSV path")
    parser.add_argument(
        "--labeled-out",
        help="labeled-row CSV path (only valid with one input)",
    )
    args = parser.parse_args(argv)
    if args.labeled_out and len(args.keystrokes_inputs) != 1:
        parser.error("--labeled-out requires exactly one keystrokes input")

    summaries = []
    labeled_rows = None
    for keystrokes_input in args.keystrokes_inputs:
        summary, rows = summarize(keystrokes_input)
        summaries.append(summary)
        if args.labeled_out:
            labeled_rows = rows

    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(summaries)

    if args.labeled_out:
        fieldnames = list(labeled_rows[0]) if labeled_rows else ["substitution_kind"]
        with open(args.labeled_out, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(labeled_rows)

    # An autocorrect-off session must not contain autocorrect rows. If it does,
    # the Settings switch was not actually flipped and the session is mislabeled.
    for summary in summaries:
        if "ac_off" in summary["session_dir"] and summary["autocorrect_rows"] > 0:
            print(
                f"WARNING: {summary['session_dir']} is tagged autocorrect-off but has "
                f"{summary['autocorrect_rows']} autocorrect rows - condition likely not applied"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
