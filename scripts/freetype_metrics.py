#!/usr/bin/env python3
"""
freetype_metrics.py
-------------------
Error metrics for FreeTypeRecorder free-typing sessions.

Free composition has no target text, so error cannot be scored the way
TypingResearch scores it (indexing into trial.targetText). Instead, intent is
recovered from the four natural repair mechanisms the user performs -
backspace, autocorrection, suggestion pick, and cursor-movement edit - and the
recovered (typed, intended) pairs are mapped onto the Soukoreff & MacKenzie
(2003) C/INF/IF/F taxonomy.

See docs/superpowers/specs/2026-08-11-freetyperecorder-error-metrics-design.md
for the full design, including the four documented departures from published
method.

Usage:
    python scripts/freetype_metrics.py <session_dir> [more_dirs ...] \\
        --out summary.csv [--assisted-metrics]
"""

import csv
from dataclasses import dataclass, field

MAX_ALIGNMENTS = 64
AC_WINDOW_MS = 30.0


@dataclass
class Event:
    t_ms: float
    event_type: str
    replacement_text: str
    range_start: int
    range_length: int
    resulting_text_length: int
    inter_key_interval_ms: float


@dataclass
class ReplayedEvent:
    event: Event
    index: int
    buffer_before: str
    buffer_after: str
    cursor_before: int
    cursor_after: int


def read_events(csv_path):
    """Read a FreeTypeRecorder keystrokes.csv into a list of Event."""
    events = []
    with open(csv_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            events.append(Event(
                t_ms=float(row["t_ms"]),
                event_type=row["event_type"],
                replacement_text=row["replacement_text"],
                range_start=int(row["range_start"]),
                range_length=int(row["range_length"]),
                resulting_text_length=int(row["resulting_text_length"]),
                inter_key_interval_ms=float(row["inter_key_interval_ms"]),
            ))
    return events


def _u16(text):
    """Encode to UTF-16-LE bytes so slicing matches NSRange code-unit indices."""
    return text.encode("utf-16-le")


def _from_u16(data):
    return data.decode("utf-16-le")


def replay(events):
    """Rebuild the buffer after every event.

    Returns (replayed, warnings). Indices in the CSV are UTF-16 code units, so
    slicing is done on UTF-16-LE bytes. The resulting_text_length invariant is
    only checked for ASCII buffers, because that column is Swift's String.count
    (grapheme clusters) while the ranges are UTF-16 - the two disagree on
    non-BMP input. Once the buffer goes non-ASCII, a single warning is emitted
    (not one per subsequent event) since every later event would otherwise be
    flagged for the same, already-known reason.
    """
    replayed = []
    warnings = []
    buffer_bytes = b""
    cursor = 0
    non_ascii_warned = False

    for index, event in enumerate(events):
        before = _from_u16(buffer_bytes)
        cursor_before = cursor

        start = event.range_start * 2
        length = event.range_length * 2
        replacement = _u16(event.replacement_text)
        buffer_bytes = buffer_bytes[:start] + replacement + buffer_bytes[start + length:]

        cursor = event.range_start + len(replacement) // 2
        after = _from_u16(buffer_bytes)

        if after.isascii() and len(after) != event.resulting_text_length:
            warnings.append(
                f"event {index}: length mismatch - replayed {len(after)}, "
                f"logged {event.resulting_text_length}"
            )
        elif not after.isascii() and not non_ascii_warned:
            warnings.append(
                f"event {index}: non-ASCII buffer, length invariant not checked"
            )
            non_ascii_warned = True

        replayed.append(ReplayedEvent(
            event=event,
            index=index,
            buffer_before=before,
            buffer_after=after,
            cursor_before=cursor_before,
            cursor_after=cursor,
        ))

    return replayed, warnings


@dataclass
class WeightedOp:
    op: str          # "match" | "sub" | "omit" | "ins"
    typed: str       # character from the typed string, or "" for "ins"
    intended: str    # character from the intended string, or "" for "omit"
    weight: float


def all_optimal_alignments(a, b, cap=MAX_ALIGNMENTS):
    """All minimum-cost alignments of a (typed) against b (intended).

    Returns (msd, alignments). Each alignment is a list of
    (op, typed_char, intended_char) tuples in left-to-right order, where a
    missing character on either side is "".

    Enumerating every optimal alignment - rather than picking one - is the
    Wobbrock & Myers (2006) technique for handling the fact that a single
    repair often has several equally valid readings.
    """
    n, m = len(a), len(b)
    dist = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dist[i][0] = i
    for j in range(m + 1):
        dist[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            dist[i][j] = min(
                dist[i - 1][j] + 1,
                dist[i][j - 1] + 1,
                dist[i - 1][j - 1] + cost,
            )

    alignments = []

    # Iterative DFS with an explicit stack instead of recursion: `walk`'s
    # call depth used to scale with len(a) + len(b), which `cap` does not
    # bound (`cap` only limits how many completed alignments are kept), so a
    # long single-path input (e.g. one string empty, the other very long)
    # blew Python's recursion limit. `acc` is a singly linked list of ops;
    # each step conses the newly-decided (rightmost-so-far) op onto the
    # front, so by the time a path reaches (0, 0) the list head is the
    # leftmost op and the tail is the rightmost - walking head-to-tail
    # yields left-to-right order directly, with no reverse needed.
    stack = [(n, m, None)]

    while stack:
        if len(alignments) >= cap:
            break
        i, j, acc = stack.pop()
        if i == 0 and j == 0:
            ops = []
            node = acc
            while node is not None:
                ops.append(node[0])
                node = node[1]
            alignments.append(ops)
            continue

        # Collect every tied-minimum transition (diagonal/up/left checked
        # independently, not elif) so no optimal alignment is missed.
        frames = []
        if i > 0 and j > 0:
            cost = 0 if a[i - 1] == b[j - 1] else 1
            if dist[i][j] == dist[i - 1][j - 1] + cost:
                op = "match" if cost == 0 else "sub"
                frames.append((i - 1, j - 1, ((op, a[i - 1], b[j - 1]), acc)))
        if i > 0 and dist[i][j] == dist[i - 1][j] + 1:
            frames.append((i - 1, j, (("omit", a[i - 1], ""), acc)))
        if j > 0 and dist[i][j] == dist[i][j - 1] + 1:
            frames.append((i, j - 1, (("ins", "", b[j - 1]), acc)))

        # Stack is LIFO, so push in reverse to explore diagonal/omit/ins in
        # the same priority order the old recursive calls did.
        for frame in reversed(frames):
            stack.append(frame)

    return dist[n][m], alignments


def weighted_ops(a, b, cap=MAX_ALIGNMENTS):
    """Fractionally-weighted operations across all optimal alignments.

    Each operation is weighted by 1/(number of alignments), so an ambiguous
    repair contributes partial credit to each reading rather than forcing a
    single guess. Returns (ops, cap_hit).
    """
    _, alignments = all_optimal_alignments(a, b, cap=cap)
    if not alignments:
        return [], False

    cap_hit = len(alignments) >= cap
    weight = 1.0 / len(alignments)

    tally = {}
    for alignment in alignments:
        for op, typed, intended in alignment:
            key = (op, typed, intended)
            tally[key] = tally.get(key, 0.0) + weight

    return [
        WeightedOp(op=op, typed=typed, intended=intended, weight=value)
        for (op, typed, intended), value in tally.items()
    ], cap_hit


SMART_PUNCTUATION = {
    ("'", "’"),   # straight to curly apostrophe
    ("'", "‘"),
    ('"', "“"),
    ('"', "”"),
    ("--", "—"),  # double hyphen to em dash
    ("...", "…"),
}


def _is_character_insert(replayed_event):
    event = replayed_event.event
    return event.event_type == "insert" and len(event.replacement_text) == 1


def classify(replayed, ac_window_ms=AC_WINDOW_MS):
    """Label every event with the mechanism that produced it.

    Autocorrect versus suggestion is decided by *temporal isolation*: an
    autocorrect fires synchronously inside the triggering keystroke's runloop
    turn, so a character insert sits within ac_window_ms of it, whereas a
    QuickType tap is a standalone user action. Discriminating on isolation
    rather than on interval sign avoids depending on which order UIKit fires
    the two delegate calls.

    ac_window_ms is a calibration parameter, not a known constant. See the
    spec's Departure 2 - it must be fitted against hand-labelled screen
    recordings before any reported number depends on it.
    """
    labels = []

    for position, item in enumerate(replayed):
        event = item.event
        old_text = item.buffer_before[
            event.range_start:event.range_start + event.range_length
        ]

        if event.event_type == "replace" and (old_text, event.replacement_text) in SMART_PUNCTUATION:
            labels.append("smart_punctuation")
            continue

        if event.event_type == "replace":
            near_character_insert = False
            for other_position, other in enumerate(replayed):
                if other_position == position:
                    continue
                if not _is_character_insert(other):
                    continue
                if abs(other.event.t_ms - event.t_ms) <= ac_window_ms:
                    near_character_insert = True
                    break
            if near_character_insert:
                labels.append("autocorrect")
            elif event.range_length > 1 and not _replaces_trailing_word(item):
                labels.append("select_retype")
            else:
                labels.append("suggestion")
            continue

        edit_end = event.range_start + event.range_length
        contiguous = (
            event.range_start == item.cursor_before
            or edit_end == item.cursor_before
        )
        if not contiguous:
            labels.append("cursor_move")
            continue

        if event.event_type == "delete":
            labels.append("backspace" if event.range_length == 1 else "bulk_delete")
            continue

        labels.append(event.event_type)

    return labels


def _replaces_trailing_word(item):
    """True if the replaced range is the word immediately before the cursor."""
    event = item.event
    edit_end = event.range_start + event.range_length
    if edit_end != item.cursor_before:
        return False
    old_text = item.buffer_before[event.range_start:edit_end]
    return bool(old_text) and " " not in old_text
