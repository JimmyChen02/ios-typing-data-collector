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

    def walk(i, j, acc):
        if len(alignments) >= cap:
            return
        if i == 0 and j == 0:
            alignments.append(list(reversed(acc)))
            return
        if i > 0 and j > 0:
            cost = 0 if a[i - 1] == b[j - 1] else 1
            if dist[i][j] == dist[i - 1][j - 1] + cost:
                op = "match" if cost == 0 else "sub"
                walk(i - 1, j - 1, acc + [(op, a[i - 1], b[j - 1])])
        if i > 0 and dist[i][j] == dist[i - 1][j] + 1:
            walk(i - 1, j, acc + [("omit", a[i - 1], "")])
        if j > 0 and dist[i][j] == dist[i][j - 1] + 1:
            walk(i, j - 1, acc + [("ins", "", b[j - 1])])

    walk(n, m, [])
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
