#!/usr/bin/env python3
"""Per-word edit metrics for FreeTypeRecorder keystroke logs.

Purpose of the keystrokes.csv export: (1) compute typing performance
metrics (CER/WER, per-word edit rates); (2) serve as behavioral ground
truth for evaluating the adaptive (Gaussian) keyboard.

For every word in the session's final text this script decides one binary:
was the word ever edited (any backspace, replacement, or substitution that
touched it, mid-typing or later), or was it typed clean? Edited words are
then broken down by correction mechanism — the categories an adaptive
keyboard could prevent (backspace+retype) or replace (autocorrect,
suggestion bar, inline prediction) — and reported as percentages of the
word and character totals, with observed examples.

Attribution: substitutions (replace/paste) are attributed to the word that
still holds their inserted characters in the final text. Deletes carry a
position marker that is shifted through every subsequent edit into
final-text coordinates; the delete is attributed to the word at (or just
left of) that final position. A delete whose final position touches no
word — e.g. a word deleted entirely, leaving only its delimiter — stays
unattributed and is reported as such; wholly deleted words are not in the
word denominator (they remain visible as `deleted_entirely` in
substitution_metrics).

Summaries and word CSVs quote participant free-typed text: handle them
with the same care as `sessions_raw/` (see scripts/CLAUDE.md).
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prefix_error_metrics as pem
import substitution_metrics as sm

# substitution_source -> reported mechanism name
SOURCE_MECHANISMS = {
    "manual_overtype": "select_overtype",
    "smart_typography": "smart_typography",
    "suggestion_bar": "suggestion_bar",
    "inline_prediction": "inline_prediction",
    "autocorrect_engine": "autocorrect",
    "unknown": "unknown_substitution",
}
BACKSPACE = "backspace_retype"
MECHANISMS = [BACKSPACE] + list(SOURCE_MECHANISMS.values())

MECHANISM_DEFS = {
    BACKSPACE: "user deleted characters (backspace or selection delete) and retyped",
    "select_overtype": "user selected text and typed/pasted over it",
    "smart_typography": "iOS smart punctuation rewrote characters",
    "suggestion_bar": "user tapped a word on the suggestion bar",
    "inline_prediction": "user accepted inline predictive text",
    "autocorrect": "iOS autocorrect changed the word at a delimiter",
    "unknown_substitution": "a substitution whose mechanism could not be attributed",
}

MAX_EXAMPLES = 3


def _shift_marker(marker, start, removed, inserted):
    """Transform a text position through one edit (UIKit range semantics).

    Left-biased: an insertion exactly at the marker does not move it —
    otherwise ordinary forward typing after a delete drags the marker to
    the end of the session. A deletion ending at the marker pulls it left.
    """
    end = start + removed
    if end <= marker and (removed > 0 or end < marker):
        return marker + inserted - removed
    if start < marker:
        return start + inserted
    return marker


def replay_with_events(rows):
    """Replay the session keeping per-unit cell identity and edit markers.

    Returns (final_cells, events). `final_cells` is the final text as a list
    of [utf16_unit, cell_id]. `events` has one entry per delete/replace/paste
    row: the row index, the cell ids it inserted, and `marker` — the edit
    position carried forward through all later edits, i.e. a final-text
    UTF-16 offset. Range semantics mirror prefix_error_metrics.replay_rows,
    including unknown-unit padding and resulting-length reconciliation.
    """
    state = []  # list of [unit, cell_id]
    next_id = 0
    events = []

    def fresh(units):
        nonlocal next_id
        cells = [[unit, next_id + offset] for offset, unit in enumerate(units)]
        next_id += len(units)
        return cells

    for index, row in enumerate(rows):
        row_number = index + 2
        try:
            start = int(row["range_start"])
            length = int(row["range_length"])
            expected_length = int(row["resulting_text_length"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"invalid edit range at CSV row {row_number}: {error}") from error

        replacement = pem._to_utf16_units(row.get("replacement_text", ""))
        if start > len(state):
            state[len(state):] = fresh([pem.UNKNOWN_UNIT] * (start - len(state)))

        inserted = fresh(replacement)
        state[start:start + length] = inserted
        removed = length

        insertion_end = start + len(inserted)
        delta = expected_length - len(state)
        if delta > 0:
            state[insertion_end:insertion_end] = fresh([pem.UNKNOWN_UNIT] * delta)
        elif delta < 0:
            remove = -delta
            after = min(remove, max(0, len(state) - insertion_end))
            del state[insertion_end:insertion_end + after]
            removed += after
            remove -= after
            if remove:
                before_start = max(0, insertion_end - remove)
                del state[before_start:insertion_end]
                removed += insertion_end - before_start

        total_inserted = len(inserted) + max(0, delta)
        for event in events:
            event["marker"] = _shift_marker(event["marker"], start, removed, total_inserted)

        if row.get("event_type") in ("delete", "replace", "paste"):
            events.append({
                "row_index": index,
                "inserted_ids": [cell[1] for cell in inserted],
                "marker": start + total_inserted,
            })

    return state, events


def _final_words(final_cells):
    """Split the final text into words.

    Returns (words, cell_to_word, word_at_unit, text): `words` is a list of
    {"text", "index"}; `cell_to_word` maps surviving cell id -> word index;
    `word_at_unit[i]` is the word index covering UTF-16 offset i (or None).
    Surrogate pairs map both units to the same character.
    """
    units = [cell[0] for cell in final_cells]
    text = pem._from_utf16_units(units)
    unit_to_char = []
    char_index = 0
    unit_index = 0
    while unit_index < len(units):
        unit = units[unit_index]
        unit_to_char.append(char_index)
        if 0xD800 <= unit <= 0xDBFF and unit_index + 1 < len(units) \
                and 0xDC00 <= units[unit_index + 1] <= 0xDFFF:
            unit_to_char.append(char_index)
            unit_index += 2
        else:
            unit_index += 1
        char_index += 1

    spans = [match.span() for match in pem.WORD_RE.finditer(text)]
    words = [{"text": text[lo:hi], "index": i} for i, (lo, hi) in enumerate(spans)]

    word_at_char = {}
    for word_index, (lo, hi) in enumerate(spans):
        for char in range(lo, hi):
            word_at_char[char] = word_index

    word_at_unit = [word_at_char.get(char) for char in unit_to_char]
    cell_to_word = {}
    for position, cell in enumerate(final_cells):
        word_index = word_at_unit[position]
        if word_index is not None:
            cell_to_word[cell[1]] = word_index
    return words, cell_to_word, word_at_unit, text


def _word_for_event(event, cell_to_word, word_at_unit):
    for cell_id in event["inserted_ids"]:
        if cell_id in cell_to_word:
            return cell_to_word[cell_id]
    marker = max(0, min(event["marker"], len(word_at_unit)))
    if marker > 0 and word_at_unit[marker - 1] is not None:
        return word_at_unit[marker - 1]
    if marker < len(word_at_unit) and word_at_unit[marker] is not None:
        return word_at_unit[marker]
    return None


def analyze_session(keystrokes_path):
    """Return (per-word ledger, session totals) for one keystrokes.csv."""
    labeled_rows, _calibration = sm.classify_rows(keystrokes_path)
    final_cells, events = replay_with_events(labeled_rows)
    words, cell_to_word, word_at_unit, final_text = _final_words(final_cells)

    for word in words:
        word["edited"] = False
        word["mechanisms"] = []
        word["first_edit_t_ms"] = ""
        word["examples"] = []

    unattributed = 0
    for event in events:
        row = labeled_rows[event["row_index"]]
        if row.get("event_type") == "delete":
            mechanism = BACKSPACE
        else:
            source = row.get("substitution_source") or "unknown"
            mechanism = SOURCE_MECHANISMS.get(source, "unknown_substitution")

        word_index = _word_for_event(event, cell_to_word, word_at_unit)
        if word_index is None:
            unattributed += 1
            continue

        word = words[word_index]
        word["edited"] = True
        if mechanism not in word["mechanisms"]:
            word["mechanisms"].append(mechanism)
        if word["first_edit_t_ms"] == "":
            word["first_edit_t_ms"] = row.get("t_ms", "")
        if row.get("event_type") in ("replace", "paste"):
            pair = (row.get("replaced_text", ""), row.get("replacement_text", ""))
            if pair[0] or pair[1]:
                word["examples"].append((mechanism, f"{pair[0]} → {pair[1]}"))

    totals = {
        "total_words": len(words),
        "total_chars": len(final_text),
        "edited_words": sum(1 for word in words if word["edited"]),
        "edit_events": len(events) - unattributed,
        "unattributed_events": unattributed,
    }
    mechanism_words = Counter()
    for word in words:
        for mechanism in word["mechanisms"]:
            mechanism_words[mechanism] += 1
    totals["mechanism_words"] = mechanism_words
    return words, totals


def _pct(numerator, denominator):
    if not denominator:
        return "n/a"
    return f"{100.0 * numerator / denominator:.1f}%"


def write_word_csv(words, out_path):
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["word_index", "word", "edited", "mechanisms", "first_edit_t_ms"])
        for word in words:
            writer.writerow([
                word["index"],
                word["text"],
                int(word["edited"]),
                ";".join(word["mechanisms"]),
                word["first_edit_t_ms"],
            ])


def write_summary_md(session_name, words, totals, out_path):
    lines = []
    lines.append(f"# per-word edit metrics — {session_name}")
    lines.append("")
    lines.append("Purpose of this export: (1) compute typing performance metrics "
                 "(CER/WER, per-word edit rates); (2) serve as behavioral ground "
                 "truth for evaluating the adaptive (Gaussian) keyboard.")
    lines.append("")
    total_words = totals["total_words"]
    edited = totals["edited_words"]
    lines.append("## words")
    lines.append(f"- total words (final text): {total_words}")
    lines.append(f"- total characters (final text): {totals['total_chars']}")
    lines.append(f"- edited words: {edited} ({_pct(edited, total_words)})")
    lines.append(f"- untouched words: {total_words - edited} "
                 f"({_pct(total_words - edited, total_words)})")
    if total_words:
        lines.append(f"- edit events per 100 words: "
                     f"{100.0 * totals['edit_events'] / total_words:.1f}")
    if totals["total_chars"]:
        lines.append(f"- edit events per 100 characters: "
                     f"{100.0 * totals['edit_events'] / totals['total_chars']:.1f}")
    if totals["unattributed_events"]:
        lines.append(f"- edit events not attributable to a surviving word: "
                     f"{totals['unattributed_events']} (text deleted entirely; "
                     f"see substitution outcomes)")
    lines.append("")
    lines.append("## edited words by mechanism")
    lines.append("A word may carry more than one mechanism, so mechanism "
                 "counts can sum past the edited-word total.")
    mechanism_words = totals["mechanism_words"]
    for mechanism in MECHANISMS:
        count = mechanism_words.get(mechanism, 0)
        if count == 0:
            continue
        lines.append(f"- {mechanism}: {count} words "
                     f"({_pct(count, total_words)} of all words, "
                     f"{_pct(count, edited)} of edited words)")
        examples = []
        for word in words:
            if mechanism not in word["mechanisms"]:
                continue
            pairs = [text for mech, text in word["examples"] if mech == mechanism]
            examples.append(pairs[0] if pairs else word["text"])
        deduped = []
        for example in examples:
            if example not in deduped:
                deduped.append(example)
        if deduped:
            shown = ", ".join(f"`{example}`" for example in deduped[:MAX_EXAMPLES])
            lines.append(f"    examples: {shown}")
    if not mechanism_words:
        lines.append("- (no edited words)")
    lines.append("")
    lines.append("<details><summary>mechanism definitions</summary>")
    lines.append("")
    for mechanism in MECHANISMS:
        lines.append(f"- `{mechanism}` — {MECHANISM_DEFS[mechanism]}")
    lines.append("")
    lines.append("</details>")
    lines.append("")
    Path(out_path).write_text("\n".join(lines), encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("inputs", nargs="+", help="keystrokes.csv files")
    parser.add_argument("--out-dir", default="processed-keystrokes",
                        help="parent directory for per-session output folders")
    args = parser.parse_args(argv)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for input_path in args.inputs:
        path = Path(input_path)
        session_name = sm.session_label(path)
        session_out_dir = out_dir / session_name
        session_out_dir.mkdir(parents=True, exist_ok=True)
        words, totals = analyze_session(path)
        csv_path = session_out_dir / f"{session_name}_word_edits.csv"
        md_path = session_out_dir / f"{session_name}_word_summary.md"
        write_word_csv(words, csv_path)
        write_summary_md(session_name, words, totals, md_path)
        print(f"{session_name}: {totals['edited_words']}/{totals['total_words']} "
              f"words edited -> {md_path}")


if __name__ == "__main__":
    main()
