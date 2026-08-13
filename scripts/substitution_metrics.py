#!/usr/bin/env python3
"""Label keystrokes.csv `replace`/`paste` rows along orthogonal axes.

The app logs text changes by shape, not intent: autocorrect, a QuickType tap,
an inline prediction accepted with space, smart punctuation and sentence
capitalization all arrive as identical `shouldChangeTextIn` calls and all come
out as `replace`. iOS exposes no API for the source of a change, so intent is
reconstructed here rather than at capture time - a bad rule is then fixed by
re-running this script instead of re-collecting sessions.

Each substitution row gets four labels instead of the old single enum:

- `substitution_source` - who initiated the change. The only inferred axis;
  `substitution_source_confidence` says how much to trust it.
- `substitution_effect` - what changed. Certain: a pure function of the two
  strings.
- `substitution_outcome` + `revert_latency_ms` - what the user did about it.
  Certain: computed by replaying the session's edit script.
- `substitution_kind` - derived alias reproducing the old flat enum so
  downstream consumers keep working.

`next_delimiter_gap_ms` carries the timing evidence behind the source label so
it ships with the data. Column semantics live in .claude/data-dictionary.md;
the reasoning behind the rules in .claude/decisions/0003-substitution-taxonomy.md.
"""

import argparse
import csv
import os
import string
import sys


# Processed output is the point of the script, so it lands in a folder of its own
# by default and raw exports in sessions_raw/ are never written back to.
DEFAULT_OUT_DIR = "processed-keystrokes"

SOURCES = [
    "manual_overtype",
    "smart_typography",
    "suggestion_bar",
    "inline_prediction",
    "autocorrect_engine",
    "unknown",
]
EFFECTS = [
    "capitalization",
    "punctuation",
    "contraction",
    "completion",
    "spacing",
    "spelling",
    "other",
]
OUTCOMES = ["kept", "reverted_to_original", "reverted_other", "edited_after"]

SUMMARY_FIELDS = (
    ["session_dir", "keystroke_rows", "substitution_rows"]
    + [f"source_{source}" for source in SOURCES]
    + [f"effect_{effect}" for effect in EFFECTS]
    + [f"outcome_{outcome}" for outcome in OUTCOMES]
    + ["grey_zone_rows"]
)

LABEL_COLUMNS = [
    "substitution_source",
    "substitution_source_confidence",
    "substitution_effect",
    "substitution_outcome",
    "revert_latency_ms",
    "next_delimiter_gap_ms",
    "substitution_kind",
]

# A substitution fired by the keystroke that triggered it lands within a few
# tens of ms; anything slower is human timing, not machine latency, and the
# trailing gap below is then undefined.
TRIGGER_WINDOW_MS = 200.0

# iOS commits a replacement and the delimiter that follows it on two internal
# paths with distinct latencies: ~5 ms when a typed delimiter triggered the
# change (autocorrect / accepted inline prediction), ~13 ms when the system
# auto-appends the space itself after a suggestion-bar tap. Across all 19
# corpus substitutions the two groups are 4.3-6.6 ms and 11.8-15.0 ms with an
# empty band between - see the 2026-08-13 touch-capture audit. Measured on one
# device and one iOS version with n=3 confirmed bar taps, so gaps inside the
# grey zone are flagged for manual review rather than trusted.
DELIMITER_GAP_SPLIT_MS = 9.0
GAP_GREY_ZONE_MS = (7.0, 12.0)

TRIGGER_CHARS = {" ", ".", ",", "!", "?", ";", ":", "\n"}

PUNCTUATION = set(string.punctuation) | {"‘", "’", "“", "”", "–", "—"}

CONTRACTION_MARKS = {"'", "’", '"', "“", "”"}


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


def session_label(keystrokes_path):
    """Name for the session in the summary row.

    A session folder holds `keystrokes.csv`, so the folder names it. Exports
    downloaded as a flat `<session>_keystrokes.csv` name themselves instead —
    otherwise every session in `sessions_raw/` would be labelled `sessions_raw`.
    """
    basename = os.path.basename(keystrokes_path)
    if basename == "keystrokes.csv":
        return os.path.basename(os.path.dirname(keystrokes_path))
    stem = os.path.splitext(basename)[0]
    return stem[: -len("_keystrokes")] if stem.endswith("_keystrokes") else stem


def _write_csv(path, fieldnames, rows):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _is_punctuation(text):
    return bool(text) and all(character in PUNCTUATION for character in text)


def _extends(old, new):
    """True when `new` completes `old` rather than correcting it.

    `tomo` -> `tomorrow` is a completion; `teh` -> `the` is a correction.
    Completions are the only shape where bar tap, inline prediction and
    autocorrect overlap, so the timing rules below apply inside this branch
    only - a high trailing gap on a *correction* does not mean bar tap
    (`i` -> `I` and smart punctuation sit in the high group too).
    """
    stripped = new.rstrip()
    return bool(old) and len(stripped) > len(old) and stripped.lower().startswith(old.lower())


def classify_rows(keystrokes_path):
    """Return keystroke rows, each with the four substitution labels.

    Rows that are not substitutions get empty labels rather than made-up
    ones - only `replace` and `paste` are ambiguous.
    """
    with open(keystrokes_path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    for index, row in enumerate(rows):
        for column in LABEL_COLUMNS:
            row[column] = ""
        if row.get("event_type") not in ("replace", "paste"):
            continue

        old = row.get("replaced_text") or ""
        new = row.get("replacement_text") or ""
        gap_ms = _delimiter_gap_ms(rows, index)
        source, confidence = _classify_source(
            row, old, new, gap_ms, _marked_hint(rows, index)
        )
        effect = _classify_effect(old, new)

        row["substitution_source"] = source
        row["substitution_source_confidence"] = confidence
        row["substitution_effect"] = effect
        row["next_delimiter_gap_ms"] = "" if gap_ms is None else f"{gap_ms:.3f}"
        row["substitution_kind"] = _legacy_kind(source, effect)

    _classify_outcomes(rows, keystrokes_path)
    return rows


def _next_insert(rows, index):
    """The first `insert` after `index` - the keystroke that accepted a
    substitution. Returns (char, t_ms), or (None, None) at end of session."""
    for row in rows[index + 1 :]:
        if row.get("event_type") == "insert":
            return row.get("replacement_text") or "", _number(row, "t_ms")
    return None, None


def _delimiter_gap_ms(rows, index):
    """Machine latency between a substitution and its trailing delimiter.

    iOS commits the replacement first, then the delimiter, a few ms apart.
    Undefined (None) when the next insert is not a delimiter or arrives
    outside the trigger window - that interval is human timing.
    """
    t_ms = _number(rows[index], "t_ms")
    char, insert_t_ms = _next_insert(rows, index)
    if char is None or char not in TRIGGER_CHARS or t_ms is None or insert_t_ms is None:
        return None
    gap = insert_t_ms - t_ms
    if gap < 0 or gap > TRIGGER_WINDOW_MS:
        return None
    return gap


def _marked_hint(rows, index):
    """Whether a prediction candidate was pending while this word was typed.

    `marked_text_before` is 0 on every substitution row itself (it clears
    before `shouldChangeTextIn` runs) but fires on mid-word inserts - a
    word-level signal, off by a few rows. Scan back to the previous delimiter.
    """
    for row in reversed(rows[:index]):
        if (
            row.get("event_type") == "insert"
            and (row.get("replacement_text") or "") in TRIGGER_CHARS
        ):
            return False
        if (_number(row, "marked_text_before", int) or 0) == 1:
            return True
    return False


def _classify_source(row, old, new, gap_ms, marked_hint):
    # Certain: the system never substitutes into a selection, so a non-zero
    # selection means the user highlighted their own text and typed over it.
    if (_number(row, "selected_length_before", int) or 0) > 0:
        return "manual_overtype", "certain"

    # Certain: punctuation swapped for punctuation is smartQuotes/smartDashes,
    # a deterministic insert-time rule, not the correction engine.
    if _is_punctuation(old) and _is_punctuation(new):
        return "smart_typography", "certain"

    # Completions: the one shape where bar tap, inline prediction and
    # autocorrect overlap. The trailing delimiter gap separates the bar tap
    # (system auto-appends the space, ~13 ms) from the space-triggered pair
    # (~5 ms), which the word-level marked-text hint then splits - though that
    # low branch is uncalibrated (no confirmed inline prediction in the corpus).
    if _extends(old, new):
        if gap_ms is None:
            return "inline_prediction", "inferred"
        in_band = GAP_GREY_ZONE_MS[0] <= gap_ms <= GAP_GREY_ZONE_MS[1]
        if gap_ms >= DELIMITER_GAP_SPLIT_MS:
            return "suggestion_bar", "grey_zone" if in_band else "inferred"
        if marked_hint:
            return "inline_prediction", "grey_zone"
        return "autocorrect_engine", "grey_zone"

    # Corrections of any shape - spelling, capitalization (`i` -> `I` arrives
    # as a replace only from the correction engine; sentence auto-caps
    # pre-shifts the keyboard and inserts the capital directly), contractions.
    if old:
        return "autocorrect_engine", "inferred"
    return "unknown", ""


def _classify_effect(old, new):
    """What changed, as a pure function of the two strings. First match wins;
    multi-effect rows (`I ask` -> `i asked` is caps + completion) take the
    earlier label."""
    if old and new and old != new and old.lower() == new.lower():
        return "capitalization"
    if _is_punctuation(old) and _is_punctuation(new):
        return "punctuation"
    unmarked = "".join(char for char in new if char not in CONTRACTION_MARKS)
    if old and unmarked != new and unmarked.lower() == old.lower():
        return "contraction"
    if _extends(old, new):
        return "completion"
    if old and new and "".join(old.split()) == "".join(new.split()):
        return "spacing"
    if old and new:
        return "spelling"
    return "other"


def _legacy_kind(source, effect):
    """Reproduce the old flat `substitution_kind` enum from the two axes."""
    if source == "manual_overtype":
        return "manual_overtype"
    if source == "smart_typography":
        return "smart_punct"
    if source == "suggestion_bar":
        return "quicktype_pick"
    if source == "inline_prediction":
        return "inline_prediction"
    if source == "autocorrect_engine":
        return "sentence_caps" if effect == "capitalization" else "autocorrect"
    return "unknown"


def _classify_outcomes(rows, keystrokes_path):
    """Label each substitution with what became of it, by replaying the session.

    The rows form a complete edit script (data-dictionary), so the text state
    is reconstructed exactly. Every character a substitution inserts is tagged
    with its row; a later edit removing tagged characters (or inserting
    strictly inside a run of them) means the user touched the substitution.
    A span whose tagged characters are all gone collapses to a region that
    absorbs the consecutive retyping at that spot; once activity moves
    elsewhere (or the session ends) the region settles and its content decides
    `reverted_to_original` vs `reverted_other`. Touched but never fully
    removed is `edited_after`; untouched to the end is `kept`.
    """
    text = []  # one [char, owner] per character; owner = substitution row index
    states = {}

    for index, row in enumerate(rows):
        event = row.get("event_type")
        if event not in ("insert", "delete", "replace", "paste"):
            continue
        start = _number(row, "range_start", int)
        length = _number(row, "range_length", int) or 0
        replacement = row.get("replacement_text") or ""
        t_ms = _number(row, "t_ms")

        if start is None or start < 0 or start + length > len(text):
            _warn_diverged(rows, keystrokes_path, index)
            _finalize_outcomes(rows, states, text, partial=True)
            return

        # An edit outside a collapsed region means the retyping burst there is
        # over: settle it on the text as it stands.
        for state in states.values():
            if state["phase"] == "collapsed" and not (
                state["lo"] <= start <= state["hi"]
            ):
                _settle(state, text)

        removed = text[start : start + length]
        for sub_index, state in states.items():
            if state["phase"] != "tracking":
                continue
            touched = any(owner == sub_index for _, owner in removed)
            if not touched and length == 0 and 0 < start < len(text):
                touched = (
                    text[start - 1][1] == sub_index and text[start][1] == sub_index
                )
            if touched and state["touched_t_ms"] is None:
                state["touched_t_ms"] = t_ms
                state["touched"] = True

        owner = index if event in ("replace", "paste") else None
        text[start : start + length] = [[char, owner] for char in replacement]

        # While a candidate is pending, resulting_text_length counts the
        # marked (uncommitted) text too, so it legitimately exceeds the
        # replayed length; the row arithmetic itself stays consistent and the
        # next unmarked row matches again. Only unmarked rows can diverge.
        expected_length = _number(row, "resulting_text_length", int)
        if (
            expected_length is not None
            and expected_length != len(text)
            and (_number(row, "marked_text_before", int) or 0) != 1
        ):
            _warn_diverged(rows, keystrokes_path, index)
            _finalize_outcomes(rows, states, text, partial=True)
            return

        delta = len(replacement) - length
        for sub_index, state in states.items():
            if state["phase"] == "collapsed":
                if start <= state["hi"] and start + length >= state["lo"]:
                    state["lo"] = min(state["lo"], start)
                    state["hi"] = max(state["lo"], state["hi"] + delta)
                elif start + length <= state["lo"]:
                    state["lo"] += delta
                    state["hi"] += delta
            elif state["phase"] == "tracking" and state["touched"]:
                if not any(entry[1] == sub_index for entry in text):
                    state["phase"] = "collapsed"
                    state["lo"] = start
                    state["hi"] = start + len(replacement)

        if event in ("replace", "paste"):
            states[index] = {
                "phase": "tracking",
                "touched": False,
                "touched_t_ms": None,
                "t_ms": t_ms,
                "original": row.get("replaced_text") or "",
                "outcome": None,
            }

    _finalize_outcomes(rows, states, text, partial=False)


def _finalize_outcomes(rows, states, text, partial):
    """Write the outcome columns. A partial finalize (replay diverged) keeps
    everything already resolved but cannot certify `kept` - an untouched span
    stays unlabelled rather than guessed."""
    for index, state in states.items():
        if state["phase"] == "collapsed":
            _settle(state, text)
        if state["outcome"] is not None:
            outcome = state["outcome"]
        elif state["touched"]:
            outcome = "edited_after"
        elif partial:
            outcome = ""
        else:
            outcome = "kept"
        rows[index]["substitution_outcome"] = outcome
        if outcome and outcome != "kept" and state["touched_t_ms"] is not None and state["t_ms"] is not None:
            rows[index]["revert_latency_ms"] = f"{state['touched_t_ms'] - state['t_ms']:.3f}"


def _settle(state, text):
    region = "".join(char for char, _ in text[state["lo"] : state["hi"]])
    state["outcome"] = (
        "reverted_to_original" if region == state["original"] else "reverted_other"
    )
    state["phase"] = "settled"


def _warn_diverged(rows, keystrokes_path, index):
    """Replay no longer matches `resulting_text_length`: the edit script is not
    self-consistent (out-of-range edit or a length mismatch, e.g. non-BMP
    characters counted in UTF-16). Outcomes stay empty rather than guessed."""
    print(
        f"WARNING: {keystrokes_path}: edit replay diverged at row {index + 1}; "
        "substitution_outcome left empty",
        file=sys.stderr,
    )


def summarize(keystrokes_input):
    keystrokes_path = resolve_keystrokes_input(keystrokes_input)
    rows = classify_rows(keystrokes_path)
    summary = {field: 0 for field in SUMMARY_FIELDS if field != "session_dir"}
    summary["session_dir"] = session_label(keystrokes_path)
    summary["keystroke_rows"] = len(rows)

    for row in rows:
        source = row["substitution_source"]
        if not source:
            continue
        summary["substitution_rows"] += 1
        summary[f"source_{source}"] += 1
        summary[f"effect_{row['substitution_effect']}"] += 1
        if row["substitution_outcome"]:
            summary[f"outcome_{row['substitution_outcome']}"] += 1
        if row["substitution_source_confidence"] == "grey_zone":
            summary["grey_zone_rows"] += 1
    return summary, rows


def write_processed(rows, path):
    """Write one processed session: every original column plus the labels."""
    fieldnames = list(rows[0]) if rows else LABEL_COLUMNS
    _write_csv(path, fieldnames, rows)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description="Label keystrokes.csv substitutions.")
    parser.add_argument("keystrokes_inputs", nargs="+", help="keystrokes.csv files or session folders")
    parser.add_argument(
        "--out-dir",
        default=DEFAULT_OUT_DIR,
        help=f"folder for processed CSVs, one per input (default: {DEFAULT_OUT_DIR})",
    )
    parser.add_argument(
        "--out",
        help="write one combined summary for this run's inputs at this path, "
        "instead of the per-session <session>_summary.csv files",
    )
    parser.add_argument(
        "--labeled-out",
        help="explicit processed CSV path, overriding --out-dir (one input only)",
    )
    args = parser.parse_args(argv)
    if args.labeled_out and len(args.keystrokes_inputs) != 1:
        parser.error("--labeled-out requires exactly one keystrokes input")

    # Every output is named after its session so a new trial never overwrites
    # an earlier one; a shared summary file would lose other sessions' rows on
    # each run. --out opts into one combined summary for this run's inputs.
    summaries = []
    written = []
    summary_paths = []
    for keystrokes_input in args.keystrokes_inputs:
        summary, rows = summarize(keystrokes_input)
        summaries.append(summary)
        processed_path = args.labeled_out or os.path.join(
            args.out_dir, f"{summary['session_dir']}_processed.csv"
        )
        written.append(write_processed(rows, processed_path))
        if not args.out:
            summary_path = os.path.join(
                args.out_dir, f"{summary['session_dir']}_summary.csv"
            )
            _write_csv(summary_path, SUMMARY_FIELDS, [summary])
            summary_paths.append(summary_path)

    if args.out:
        _write_csv(args.out, SUMMARY_FIELDS, summaries)
        summary_paths.append(args.out)

    for path in written:
        print(f"processed -> {path}")
    for path in summary_paths:
        print(f"summary   -> {path}")

    # The session name promises a device condition; the labels must agree with
    # it. ac_off with autocorrect rows means the Settings switch was never
    # flipped; ac_on with zero means it was silently left off.
    for summary in summaries:
        if "ac_off" in summary["session_dir"] and summary["source_autocorrect_engine"] > 0:
            print(
                f"WARNING: {summary['session_dir']} is tagged autocorrect-off but has "
                f"{summary['source_autocorrect_engine']} autocorrect rows - condition likely not applied"
            )
        elif "ac_on" in summary["session_dir"] and summary["source_autocorrect_engine"] == 0:
            print(
                f"WARNING: {summary['session_dir']} is tagged autocorrect-on but has "
                "zero autocorrect rows - device switch likely off"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
