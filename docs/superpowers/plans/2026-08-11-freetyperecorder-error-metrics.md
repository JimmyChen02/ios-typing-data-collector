# FreeTypeRecorder Error Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute error metrics for FreeTypeRecorder free-typing sessions by recovering the user's intended text from their four natural repair mechanisms, since no target text exists to score against.

**Architecture:** A single script `scripts/freetype_metrics.py` with four pure stages — replay the text buffer from the event stream, classify each event into a repair mechanism, extract `(typed, intended)` string pairs from repair episodes and align them, then accumulate keystroke counts into the Soukoreff & MacKenzie error-rate family. Each stage is a pure function over the previous stage's output and is tested in isolation.

**Tech Stack:** Python 3, stdlib only (`csv`, `json`, `dataclasses`, `argparse`, `collections`). pytest 7.4.4 for tests. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-11-freetyperecorder-error-metrics-design.md`

## Global Constraints

- **Python interpreter:** `/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/.venv-ml/bin/python`. Referred to below as `$PY`. Export it once per shell: `export PY=/Users/jimmy2/Downloads/Cornell/Hyunchul_Research/ios-typing-data-collector/.venv-ml/bin/python`
- **Stdlib only.** No new third-party dependencies.
- **No changes to any Swift file.** This is analysis-only. The CSV schema is frozen.
- **No changes to the study protocol.**
- Tests live in `tests/` at repo root, flat, named `test_*.py` — matching `tests/test_hand_pipeline.py`.
- Script style follows `scripts/clean_keystrokes.py`: `#!/usr/bin/env python3`, module docstring with a `---` underline, a documented Usage section.
- `MAX_ALIGNMENTS = 64`, `AC_WINDOW_MS = 30.0` — module-level constants.
- Every `INF`-dependent metric is emitted with a `_lower_bound` suffix. Never report them as point estimates.
- `IF_a`, `IF_m`, and `assistance_share` are gated: emitted only when `--assisted-metrics` is passed, because the autocorrect/suggestion detection rule is unvalidated (spec, Departure 2).

---

### Task 1: Buffer replay

Rebuilds the exact text buffer after every logged event. Everything downstream depends on this.

**Files:**
- Create: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: nothing
- Produces: `Event` dataclass (fields `t_ms: float`, `event_type: str`, `replacement_text: str`, `range_start: int`, `range_length: int`, `resulting_text_length: int`, `inter_key_interval_ms: float`); `ReplayedEvent` dataclass (fields `event: Event`, `index: int`, `buffer_before: str`, `buffer_after: str`, `cursor_before: int`, `cursor_after: int`); `read_events(csv_path: str) -> list[Event]`; `replay(events: list[Event]) -> tuple[list[ReplayedEvent], list[str]]` returning replayed events and a list of warning strings.

**Background the implementer needs:** `range_start` and `range_length` are Swift `NSRange` values measured in **UTF-16 code units** (`LoggingTextView.swift:50`). But `resulting_text_length` is produced by Swift's `String.count`, which counts **grapheme clusters** (`LoggingTextView.swift:63`). For ASCII text these are identical; for emoji they diverge. So the length invariant is asserted only for pure-ASCII sessions, and produces a warning otherwise. Do not "fix" this by making it always assert — it would fail on legitimate data.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_freetype_metrics.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import freetype_metrics as fm


def make_event(event_type, replacement_text, range_start, range_length,
               resulting_text_length, t_ms=0.0, iki=0.0):
    return fm.Event(
        t_ms=t_ms,
        event_type=event_type,
        replacement_text=replacement_text,
        range_start=range_start,
        range_length=range_length,
        resulting_text_length=resulting_text_length,
        inter_key_interval_ms=iki,
    )


def test_replay_builds_buffer_for_simple_typing():
    events = [
        make_event("insert", "b", 0, 0, 1),
        make_event("insert", "i", 1, 0, 2),
        make_event("insert", "p", 2, 0, 3),
        make_event("insert", "e", 3, 0, 4),
    ]
    replayed, warnings = fm.replay(events)
    assert [r.buffer_after for r in replayed] == ["b", "bi", "bip", "bipe"]
    assert replayed[-1].cursor_after == 4
    assert warnings == []


def test_replay_handles_delete_and_replace():
    events = [
        make_event("insert", "b", 0, 0, 1),
        make_event("insert", "x", 1, 0, 2),
        make_event("delete", "", 1, 1, 1),
        make_event("replace", "bike", 0, 1, 4),
    ]
    replayed, warnings = fm.replay(events)
    assert replayed[2].buffer_after == "b"
    assert replayed[3].buffer_after == "bike"
    assert replayed[3].cursor_after == 4
    assert warnings == []


def test_replay_warns_on_length_mismatch():
    events = [make_event("insert", "b", 0, 0, 99)]
    replayed, warnings = fm.replay(events)
    assert replayed[0].buffer_after == "b"
    assert len(warnings) == 1
    assert "length mismatch" in warnings[0]


def test_replay_handles_non_bmp_characters():
    # An emoji is 2 UTF-16 code units but 1 grapheme, so range indices and
    # resulting_text_length disagree. Replay must follow the UTF-16 indices
    # and skip the length check rather than corrupt every later index.
    events = [
        make_event("insert", "a", 0, 0, 1),
        make_event("insert", "\U0001F600", 1, 0, 2),  # cursor advances by 2
        make_event("insert", "b", 3, 0, 3),
    ]
    replayed, warnings = fm.replay(events)
    assert replayed[-1].buffer_after == "a\U0001F600b"
    assert replayed[1].cursor_after == 3
    assert any("non-ASCII" in w for w in warnings)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'freetype_metrics'`

- [ ] **Step 3: Write minimal implementation**

```python
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
    non-BMP input.
    """
    replayed = []
    warnings = []
    buffer_bytes = b""
    cursor = 0

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
        elif not after.isascii():
            warnings.append(
                f"event {index}: non-ASCII buffer, length invariant not checked"
            )

        replayed.append(ReplayedEvent(
            event=event,
            index=index,
            buffer_before=before,
            buffer_after=after,
            cursor_before=cursor_before,
            cursor_after=cursor,
        ))

    return replayed, warnings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 4 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Add buffer replay for FreeTypeRecorder keystroke streams

Rebuilds the exact text buffer after every logged event, slicing on
UTF-16-LE bytes so indices match the logged NSRange values. The
resulting_text_length invariant is checked only for ASCII buffers,
since that column is Swift's grapheme count while the ranges are
UTF-16 code units."
```

---

### Task 2: Alignment engine

Enumerates **all** minimum-cost alignments between two strings and weights each operation by `1/n`, per Wobbrock & Myers (2006). Validated against their published worked example.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `WeightedOp` dataclass (fields `op: str` one of `"match" | "sub" | "omit" | "ins"`, `typed: str | None`, `intended: str | None`, `weight: float`); `all_optimal_alignments(a: str, b: str, cap: int = MAX_ALIGNMENTS) -> tuple[int, list[list[tuple[str, str | None, str | None]]]]`; `weighted_ops(a: str, b: str, cap: int = MAX_ALIGNMENTS) -> tuple[list[WeightedOp], bool]` where the bool is `True` if the alignment cap was hit.

**Semantics of the four ops**, where `a` is the typed string and `b` the intended string:
- `match` — same character in both; a correct keystroke
- `sub` — different characters; an erroneous keystroke whose intent is now known
- `omit` — character in `a` with no counterpart in `b`; an extra character the user typed
- `ins` — character in `b` with no counterpart in `a`; a character the user *failed* to type. **No erroneous keystroke exists for this**, so it must never be counted as `IF`.

- [ ] **Step 1: Write the failing test**

```python
def test_all_optimal_alignments_matches_published_example():
    # Wobbrock & Myers (2006), Figures 3-4: P="quickly", T="qucehkly".
    # MSD = 3 with exactly 4 optimal alignments.
    msd, alignments = fm.all_optimal_alignments("quickly", "qucehkly")
    assert msd == 3
    assert len(alignments) == 4


def test_weighted_ops_reproduces_published_fractional_weights():
    # Same example: 3 of the 4 alignments substitute for "i", one omits it.
    # The paper reports 0.75 substitution / 0.25 omission for "i".
    ops, cap_hit = fm.weighted_ops("quickly", "qucehkly")
    assert cap_hit is False
    sub_i = sum(o.weight for o in ops if o.op == "sub" and o.typed == "i")
    omit_i = sum(o.weight for o in ops if o.op == "omit" and o.typed == "i")
    assert round(sub_i, 6) == 0.75
    assert round(omit_i, 6) == 0.25


def test_weighted_ops_on_unambiguous_repair():
    # bipe -> bike: one substitution p->k, two correct characters retained.
    ops, cap_hit = fm.weighted_ops("ipe", "ike")
    assert cap_hit is False
    subs = [o for o in ops if o.op == "sub"]
    assert len(subs) == 1
    assert subs[0].typed == "p"
    assert subs[0].intended == "k"
    assert subs[0].weight == 1.0
    assert round(sum(o.weight for o in ops if o.op == "match"), 6) == 2.0


def test_weighted_ops_normalises_across_alignments():
    _, alignments = fm.all_optimal_alignments("quickly", "qucehkly")
    ops, _ = fm.weighted_ops("quickly", "qucehkly")
    # Optimal alignments need not all be the same length: three of these four
    # have 8 columns and one has 9. Total weight must therefore equal the mean
    # column count, not any single alignment's length.
    expected = sum(len(a) for a in alignments) / len(alignments)
    assert round(expected, 6) == 8.25
    assert round(sum(o.weight for o in ops), 6) == round(expected, 6)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k alignment or weighted`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'all_optimal_alignments'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 8 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Add all-optimal-alignments engine with fractional weighting

Implements the Wobbrock & Myers (2006) technique: enumerate every
minimum-cost alignment rather than picking one, and weight each
operation by 1/n so ambiguous repairs contribute partial credit.

Validated against their published worked example (quickly/qucehkly),
which has 4 optimal alignments and a documented 0.75/0.25 split
between substitution and omission for the letter i."
```

---

### Task 3: Mechanism classification

Labels every event with the repair mechanism that produced it.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: `ReplayedEvent` from Task 1
- Produces: `classify(replayed: list[ReplayedEvent], ac_window_ms: float = AC_WINDOW_MS) -> list[str]`, one label per event, each of `"smart_punctuation" | "autocorrect" | "suggestion" | "cursor_move" | "backspace" | "bulk_delete" | "select_retype" | "insert" | "paste"`.

**Rule priority** (first match wins), per the spec's Stage 1 table. `AC_WINDOW_MS` is an unvalidated calibration parameter — see the spec's Departure 2.

- [ ] **Step 1: Write the failing test**

```python
def test_classify_labels_ordinary_typing_and_backspace():
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=200),
        make_event("delete", "", 1, 1, 1, t_ms=400),
    ]
    replayed, _ = fm.replay(events)
    assert fm.classify(replayed) == ["insert", "insert", "backspace"]


def test_classify_detects_smart_punctuation():
    events = [
        make_event("insert", "a", 0, 0, 1, t_ms=0),
        make_event("insert", "'", 1, 0, 2, t_ms=200),
        make_event("replace", "’", 1, 1, 2, t_ms=210),
    ]
    replayed, _ = fm.replay(events)
    assert fm.classify(replayed)[2] == "smart_punctuation"


def test_classify_distinguishes_autocorrect_from_suggestion():
    # Autocorrect: a replace sitting within AC_WINDOW_MS of a character insert,
    # because it fires inside the triggering keystroke's runloop turn.
    autocorrect = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("insert", " ", 4, 0, 5, t_ms=600),
        make_event("replace", "bike ", 0, 5, 5, t_ms=605),
    ]
    replayed, _ = fm.replay(autocorrect)
    assert fm.classify(replayed)[5] == "autocorrect"

    # Suggestion: a temporally isolated replace, no adjacent character insert.
    suggestion = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("replace", "bike ", 0, 2, 5, t_ms=900),
    ]
    replayed, _ = fm.replay(suggestion)
    assert fm.classify(replayed)[2] == "suggestion"


def test_classify_detects_cursor_movement():
    # Type "bipe", then reach back and delete the "p" at index 2.
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("delete", "", 2, 1, 3, t_ms=1200),
    ]
    replayed, _ = fm.replay(events)
    assert fm.classify(replayed)[4] == "cursor_move"


def test_classify_detects_bulk_delete():
    events = [
        make_event("insert", "bike", 0, 0, 4, t_ms=0),
        make_event("delete", "", 0, 4, 0, t_ms=500),
    ]
    replayed, _ = fm.replay(events)
    assert fm.classify(replayed)[1] == "bulk_delete"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k classify`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'classify'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 13 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Add repair-mechanism classification for keystroke events

Labels each event as backspace, autocorrect, suggestion, cursor
movement, bulk delete, select-and-retype, smart punctuation, or
ordinary insert.

Autocorrect and suggestion are separated by temporal isolation rather
than interval sign, since autocorrect fires inside the triggering
keystroke's runloop turn while a QuickType tap is standalone. The
AC_WINDOW_MS threshold is unvalidated and documented as such."
```

---

### Task 4: Episode grouping and intent-pair extraction

Groups events into editing episodes (Alharbi et al.) and extracts the `(typed, intended)` pair each one reveals.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: `ReplayedEvent` (Task 1), `weighted_ops` (Task 2), `classify` output (Task 3)
- Produces: `Episode` dataclass (fields `kind: str`, `start_index: int`, `end_index: int`, `typed: str`, `intended: str`, `is_completion: bool`, `is_abandoned: bool`, `is_reverted: bool`, `fix_keystrokes: int`, `ops: list[WeightedOp]`, `cap_hit: bool`, `latency_ms: float`); `extract_episodes(replayed: list[ReplayedEvent], labels: list[str]) -> list[Episode]`

`is_reverted` is declared here but always left `False`; Task 5 sets it.

**The three episode shapes:**

1. **Manual** (`backspace`, `bulk_delete`, `cursor_move`) — opens at the first such event. `anchor` = `range_start + range_length` of that event, `pre_buffer` = its `buffer_before`. Track `min_cursor`, the lowest cursor reached. Closes at the first event whose `cursor_after >= anchor`. Then `typed = pre_buffer[min_cursor:anchor]` and `intended = closing_buffer[min_cursor:closing_cursor]`.
2. **Assisted** (`autocorrect`, `suggestion`) — single event. `typed` = replaced range, `intended` = replacement with any trailing space stripped. `fix_keystrokes = 0`.
3. **`select_retype`** — single event, but manual: `fix_keystrokes = 1`.

**Abandonment.** If a manual episode never closes, or closes with `intended == ""`, the user deleted text without replacing it — a rewrite or a deleted phrase, not a typo correction. Intent is unrecoverable. Mark `is_abandoned=True`, emit no ops, but still count `fix_keystrokes`. The backoff paper filters exactly these cases, and Wobbrock & Myers' "backspaces are accurate and intentional" assumption does not cover them.

**Completion.** If `typed` is a strict prefix of `intended`, set `is_completion=True` and emit no ops — `Bi -> bike` is a completion, not a repair.

- [ ] **Step 1: Write the failing test**

```python
def _episodes_for(events):
    replayed, _ = fm.replay(events)
    return fm.extract_episodes(replayed, fm.classify(replayed))


def test_backspace_episode_extracts_intent_pair():
    # bipe -> 3 backspaces -> retype "ike" -> bike
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=100),
        make_event("insert", "p", 2, 0, 3, t_ms=200),
        make_event("insert", "e", 3, 0, 4, t_ms=300),
        make_event("delete", "", 3, 1, 3, t_ms=800),
        make_event("delete", "", 2, 1, 2, t_ms=900),
        make_event("delete", "", 1, 1, 1, t_ms=1000),
        make_event("insert", "i", 1, 0, 2, t_ms=1100),
        make_event("insert", "k", 2, 0, 3, t_ms=1200),
        make_event("insert", "e", 3, 0, 4, t_ms=1300),
    ]
    episodes = _episodes_for(events)
    assert len(episodes) == 1
    episode = episodes[0]
    assert episode.typed == "ipe"
    assert episode.intended == "ike"
    assert episode.fix_keystrokes == 3
    assert episode.is_abandoned is False
    subs = [o for o in episode.ops if o.op == "sub"]
    assert len(subs) == 1
    assert (subs[0].typed, subs[0].intended) == ("p", "k")


def test_cursor_move_episode_extracts_local_pair():
    # bipe, reach back to delete "p" at index 2, type "k"
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=100),
        make_event("insert", "p", 2, 0, 3, t_ms=200),
        make_event("insert", "e", 3, 0, 4, t_ms=300),
        make_event("delete", "", 2, 1, 3, t_ms=1200),
        make_event("insert", "k", 2, 0, 4, t_ms=1400),
    ]
    episodes = _episodes_for(events)
    assert len(episodes) == 1
    assert episodes[0].kind == "cursor_move"
    assert episodes[0].typed == "p"
    assert episodes[0].intended == "k"
    assert episodes[0].fix_keystrokes == 1


def test_suggestion_completion_yields_no_errors():
    # "Bi" -> choose "bike": typed text is a strict prefix, so no error.
    events = [
        make_event("insert", "B", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("replace", "Bike ", 0, 2, 5, t_ms=900),
    ]
    episodes = _episodes_for(events)
    assert len(episodes) == 1
    assert episodes[0].is_completion is True
    assert episodes[0].ops == []
    assert episodes[0].fix_keystrokes == 0


def test_suggestion_correction_scores_a_substitution():
    # "Be" -> choose "bike": not a prefix, so the "e" was a mistyped "i".
    events = [
        make_event("insert", "B", 0, 0, 1, t_ms=0),
        make_event("insert", "e", 1, 0, 2, t_ms=150),
        make_event("replace", "Bike ", 0, 2, 5, t_ms=900),
    ]
    episodes = _episodes_for(events)
    assert len(episodes) == 1
    assert episodes[0].is_completion is False
    assert episodes[0].fix_keystrokes == 0
    assert any(o.op == "sub" for o in episodes[0].ops)


def test_abandoned_deletion_yields_no_ops():
    # Delete a whole word and never replace it - intent unrecoverable.
    events = [
        make_event("insert", "bike", 0, 0, 4, t_ms=0),
        make_event("delete", "", 0, 4, 0, t_ms=500),
    ]
    episodes = _episodes_for(events)
    assert len(episodes) == 1
    assert episodes[0].is_abandoned is True
    assert episodes[0].ops == []
    assert episodes[0].fix_keystrokes == 1


def test_smart_punctuation_produces_no_episode():
    events = [
        make_event("insert", "a", 0, 0, 1, t_ms=0),
        make_event("insert", "'", 1, 0, 2, t_ms=200),
        make_event("replace", "’", 1, 1, 2, t_ms=210),
    ]
    assert _episodes_for(events) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k episode`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'extract_episodes'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
MANUAL_OPENERS = {"backspace", "bulk_delete", "cursor_move"}
ASSISTED_KINDS = {"autocorrect", "suggestion"}


@dataclass
class Episode:
    kind: str
    start_index: int
    end_index: int
    typed: str
    intended: str
    is_completion: bool = False
    is_abandoned: bool = False
    is_reverted: bool = False
    fix_keystrokes: int = 0
    ops: list = field(default_factory=list)
    cap_hit: bool = False
    latency_ms: float = 0.0


def _build_ops(typed, intended):
    """Align a (typed, intended) pair, short-circuiting the trivial cases."""
    if typed == intended:
        return [], False
    if not typed or not intended:
        return [], False
    return weighted_ops(typed, intended)


def extract_episodes(replayed, labels):
    """Group events into editing episodes and recover each one's intent pair.

    An editing episode runs from the first backspace or cursor movement until
    forward typing resumes past the repair point (Alharbi et al. 2020).
    Autocorrect, suggestion and select-and-retype are single-event episodes.
    """
    episodes = []
    position = 0

    while position < len(replayed):
        label = labels[position]
        item = replayed[position]
        event = item.event

        if label in ASSISTED_KINDS or label == "select_retype":
            typed = item.buffer_before[
                event.range_start:event.range_start + event.range_length
            ]
            intended = event.replacement_text.rstrip(" ")
            is_completion = bool(typed) and intended.startswith(typed) and typed != intended
            ops, cap_hit = ([], False) if is_completion else _build_ops(typed, intended)
            episodes.append(Episode(
                kind=label,
                start_index=position,
                end_index=position,
                typed=typed,
                intended=intended,
                is_completion=is_completion,
                is_abandoned=not typed,
                fix_keystrokes=0 if label in ASSISTED_KINDS else 1,
                ops=ops,
                cap_hit=cap_hit,
                latency_ms=event.inter_key_interval_ms,
            ))
            position += 1
            continue

        if label not in MANUAL_OPENERS:
            position += 1
            continue

        anchor = event.range_start + event.range_length
        pre_buffer = item.buffer_before
        start_position = position
        start_t_ms = event.t_ms
        min_cursor = item.cursor_after
        fix_keystrokes = 0
        end_position = None

        scan = position
        while scan < len(replayed):
            scanned = replayed[scan]
            if labels[scan] in MANUAL_OPENERS or scanned.event.event_type == "delete":
                fix_keystrokes += 1
            min_cursor = min(min_cursor, scanned.cursor_after)
            if scanned.cursor_after >= anchor:
                end_position = scan
                break
            scan += 1

        if end_position is None:
            episodes.append(Episode(
                kind=label,
                start_index=start_position,
                end_index=len(replayed) - 1,
                typed=pre_buffer[min_cursor:anchor],
                intended="",
                is_abandoned=True,
                fix_keystrokes=fix_keystrokes,
                latency_ms=replayed[-1].event.t_ms - start_t_ms,
            ))
            position = len(replayed)
            continue

        closing = replayed[end_position]
        typed = pre_buffer[min_cursor:anchor]
        intended = closing.buffer_after[min_cursor:closing.cursor_after]
        is_abandoned = not intended
        ops, cap_hit = ([], False) if is_abandoned else _build_ops(typed, intended)

        episodes.append(Episode(
            kind=label,
            start_index=start_position,
            end_index=end_position,
            typed=typed,
            intended=intended,
            is_abandoned=is_abandoned,
            fix_keystrokes=fix_keystrokes,
            ops=ops,
            cap_hit=cap_hit,
            latency_ms=closing.event.t_ms - start_t_ms,
        ))
        position = end_position + 1

    return episodes
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 19 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Extract intent pairs from editing episodes

Groups events into editing episodes per Alharbi et al. and recovers the
(typed, intended) string pair each repair reveals, then aligns it.

Handles the two cases that would otherwise corrupt the counts: a
suggestion whose typed text is a strict prefix of the chosen word is a
completion with no error, and a deletion never followed by replacement
is an abandoned rewrite whose intent is unrecoverable and is excluded."
```

---

### Task 5: Autocorrect revert detection

When autocorrect changes a word the user actually wanted, the user reverts it. The tap was never an error, and charging one to the user would be wrong.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: `Episode` (Task 4), `ReplayedEvent` (Task 1)
- Produces: `mark_reverts(replayed: list[ReplayedEvent], episodes: list[Episode]) -> list[Episode]`, mutating and returning the same list with `is_reverted` set on reverted assisted episodes.

**Detection.** An assisted episode is reverted when a later event restores the episode's `typed` string at the same buffer position, with no intervening character insert. On iOS, one backspace immediately after autocorrect restores what the user originally typed, so the restoring event usually sits within a few events. Scan forward at most `REVERT_LOOKAHEAD = 4` events; anything further is a fresh edit, not a revert.

**Consequence.** A reverted episode's ops are cleared: the user's original spelling was correct, so there is no user error. The event is still counted as an episode of its mechanism, since it did happen and its latency is exactly Alharbi et al.'s 5.5-second wrong-autocorrect repair cost.

- [ ] **Step 1: Write the failing test**

```python
def test_revert_after_autocorrect_charges_no_user_error():
    # Types "bipe ", autocorrect makes it "bike ", user reverts to "bipe ".
    # "bipe" was intended (a name, say), so the user made no tap error.
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("insert", " ", 4, 0, 5, t_ms=600),
        make_event("replace", "bike ", 0, 5, 5, t_ms=605),
        make_event("replace", "bipe ", 0, 5, 5, t_ms=2000),
    ]
    replayed, _ = fm.replay(events)
    labels = fm.classify(replayed)
    episodes = fm.mark_reverts(replayed, fm.extract_episodes(replayed, labels))
    autocorrects = [e for e in episodes if e.kind == "autocorrect"]
    assert len(autocorrects) == 1
    assert autocorrects[0].is_reverted is True
    assert autocorrects[0].ops == []


def test_unreverted_autocorrect_keeps_its_ops():
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("insert", " ", 4, 0, 5, t_ms=600),
        make_event("replace", "bike ", 0, 5, 5, t_ms=605),
    ]
    replayed, _ = fm.replay(events)
    labels = fm.classify(replayed)
    episodes = fm.mark_reverts(replayed, fm.extract_episodes(replayed, labels))
    autocorrects = [e for e in episodes if e.kind == "autocorrect"]
    assert autocorrects[0].is_reverted is False
    assert any(o.op == "sub" for o in autocorrects[0].ops)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k revert`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'mark_reverts'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
REVERT_LOOKAHEAD = 4


def mark_reverts(replayed, episodes):
    """Flag assisted episodes the user immediately undid.

    When autocorrect replaces a word the user actually wanted, they revert it -
    on iOS a single backspace after the correction restores the original. The
    original tap was never an error, so charging one to the user would invent a
    mistake. Reverted episodes keep their mechanism count and latency (that
    latency is the cost of fighting a wrong autocorrect) but contribute no
    error.
    """
    by_start = {episode.start_index: episode for episode in episodes}

    for episode in episodes:
        if episode.kind not in ASSISTED_KINDS or episode.is_abandoned:
            continue

        original = replayed[episode.start_index].buffer_before

        for offset in range(1, REVERT_LOOKAHEAD + 1):
            position = episode.end_index + offset
            if position >= len(replayed):
                break
            candidate = replayed[position]
            if _is_character_insert(candidate):
                break
            if candidate.buffer_after.rstrip() != original.rstrip():
                continue

            episode.is_reverted = True
            episode.ops = []

            # The undo is itself classified as an episode (usually
            # select_retype, since it rewrites the whole word). Left alone it
            # would align "bike " against "bipe" and charge the user an error
            # for undoing the machine's mistake, so neutralise it too. Its
            # fix_keystrokes still count - the user really did press a key.
            undoing = by_start.get(position)
            if undoing is not None:
                undoing.is_reverted = True
                undoing.ops = []
            break

    return episodes
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 21 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Detect and discount reverted autocorrections

When autocorrect changes a word the user actually wanted and they undo
it, the original tap was never an error. Charging one would invent a
mistake the user did not make.

Reverted episodes keep their mechanism count and latency, since that
latency is the real cost of fighting a wrong autocorrect, but they
contribute nothing to the error counts."
```

---

### Task 6: Keystroke accounting

Turns episodes into the counted quantities the metrics are built from.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: `Episode` (Task 4), `ReplayedEvent` (Task 1), `classify` labels (Task 3)
- Produces: `Counts` dataclass (fields `T_len: int`, `S: float`, `U: float`, `IF_m: float`, `IF_a: float`, `CNE: float`, `corrected_omissions: float`, `F: int`, `K: float`); `accumulate(replayed: list[ReplayedEvent], labels: list[str], episodes: list[Episode]) -> Counts`

**Mapping from aligned op to count**, exactly as the spec's Stage 2 table specifies:

| op | contributes to |
|---|---|
| `match` | `CNE` |
| `sub` | `IF_m` if the episode is manual, `IF_a` if assisted |
| `omit` | same as `sub` — an extra character the user typed and then removed |
| `ins` | `corrected_omissions` — **never** `IF`, because no erroneous keystroke exists |

`S` = the sum over assisted episodes of `max(0, len(intended) - len(typed))`, the characters the system supplied for free. `U = T_len - S`. `K = U + IF_m + IF_a + CNE`.

- [ ] **Step 1: Write the failing test**

```python
def _counts_for(events):
    replayed, _ = fm.replay(events)
    labels = fm.classify(replayed)
    episodes = fm.mark_reverts(replayed, fm.extract_episodes(replayed, labels))
    return fm.accumulate(replayed, labels, episodes)


def test_accumulate_ignores_reverted_autocorrect():
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("insert", " ", 4, 0, 5, t_ms=600),
        make_event("replace", "bike ", 0, 5, 5, t_ms=605),
        make_event("replace", "bipe ", 0, 5, 5, t_ms=2000),
    ]
    counts = _counts_for(events)
    assert round(counts.IF_a, 6) == 0.0
    assert round(counts.IF_m, 6) == 0.0
    assert round(counts.S, 6) == 0.0


def test_accumulate_counts_backspace_repair():
    # bipe -> bike by backspacing. One real error (p->k), two correct
    # characters erased as collateral, three fixing keystrokes.
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=100),
        make_event("insert", "p", 2, 0, 3, t_ms=200),
        make_event("insert", "e", 3, 0, 4, t_ms=300),
        make_event("delete", "", 3, 1, 3, t_ms=800),
        make_event("delete", "", 2, 1, 2, t_ms=900),
        make_event("delete", "", 1, 1, 1, t_ms=1000),
        make_event("insert", "i", 1, 0, 2, t_ms=1100),
        make_event("insert", "k", 2, 0, 3, t_ms=1200),
        make_event("insert", "e", 3, 0, 4, t_ms=1300),
    ]
    counts = _counts_for(events)
    assert counts.T_len == 4
    assert round(counts.IF_m, 6) == 1.0
    assert round(counts.IF_a, 6) == 0.0
    assert round(counts.CNE, 6) == 2.0
    assert counts.F == 3
    assert round(counts.S, 6) == 0.0
    assert round(counts.U, 6) == 4.0
    assert round(counts.K, 6) == 7.0


def test_accumulate_counts_autocorrect_with_zero_fixes():
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("insert", "p", 2, 0, 3, t_ms=300),
        make_event("insert", "e", 3, 0, 4, t_ms=450),
        make_event("insert", " ", 4, 0, 5, t_ms=600),
        make_event("replace", "bike ", 0, 5, 5, t_ms=605),
    ]
    counts = _counts_for(events)
    assert round(counts.IF_a, 6) == 1.0
    assert round(counts.IF_m, 6) == 0.0
    assert counts.F == 0


def test_accumulate_credits_suggestion_completion_to_system_characters():
    events = [
        make_event("insert", "B", 0, 0, 1, t_ms=0),
        make_event("insert", "i", 1, 0, 2, t_ms=150),
        make_event("replace", "Bike ", 0, 2, 5, t_ms=900),
    ]
    counts = _counts_for(events)
    # "Bike" is 2 characters longer than the typed "Bi".
    assert round(counts.S, 6) == 2.0
    assert round(counts.IF_a, 6) == 0.0
    assert round(counts.IF_m, 6) == 0.0


def test_accumulate_scores_suggestion_correction_and_credits_system_chars():
    # "Be" -> choose "bike": the "e" was a mistyped "i" (one assisted error),
    # and "bike" is 2 characters longer than what was typed.
    events = [
        make_event("insert", "B", 0, 0, 1, t_ms=0),
        make_event("insert", "e", 1, 0, 2, t_ms=150),
        make_event("replace", "Bike ", 0, 2, 5, t_ms=900),
    ]
    counts = _counts_for(events)
    assert round(counts.IF_a, 6) == 1.0
    assert round(counts.IF_m, 6) == 0.0
    assert round(counts.S, 6) == 2.0
    assert counts.F == 0


def test_accumulate_never_counts_corrected_omission_as_an_error():
    # Typed "bke", repaired to "bike": the "i" was never typed, so there is
    # no erroneous keystroke to charge.
    events = [
        make_event("insert", "b", 0, 0, 1, t_ms=0),
        make_event("insert", "k", 1, 0, 2, t_ms=100),
        make_event("insert", "e", 2, 0, 3, t_ms=200),
        make_event("delete", "", 2, 1, 2, t_ms=800),
        make_event("delete", "", 1, 1, 1, t_ms=900),
        make_event("insert", "i", 1, 0, 2, t_ms=1000),
        make_event("insert", "k", 2, 0, 3, t_ms=1100),
        make_event("insert", "e", 3, 0, 4, t_ms=1200),
    ]
    counts = _counts_for(events)
    assert round(counts.corrected_omissions, 6) == 1.0
    assert round(counts.IF_m, 6) == 0.0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k accumulate`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'accumulate'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
@dataclass
class Counts:
    T_len: int = 0
    S: float = 0.0
    U: float = 0.0
    IF_m: float = 0.0
    IF_a: float = 0.0
    CNE: float = 0.0
    corrected_omissions: float = 0.0
    F: int = 0
    K: float = 0.0


def accumulate(replayed, labels, episodes):
    """Reduce episodes to the counted quantities the metrics are built from.

    The "ins" alignment op - a character present in the intended string but
    never typed - is deliberately excluded from IF. It is a corrected omission:
    the user failed to press a key, so there is no erroneous keystroke to
    charge. Folding it into IF would invent errors that never happened.
    """
    counts = Counts()
    counts.T_len = len(replayed[-1].buffer_after) if replayed else 0

    for episode in episodes:
        counts.F += episode.fix_keystrokes

        if episode.is_reverted:
            # The system's characters were undone, so they never reached the
            # final text and the user's original tap was not an error.
            continue

        if episode.kind in ASSISTED_KINDS:
            counts.S += max(0, len(episode.intended) - len(episode.typed))

        if episode.is_abandoned or episode.is_completion:
            continue

        assisted = episode.kind in ASSISTED_KINDS
        for op in episode.ops:
            if op.op == "match":
                counts.CNE += op.weight
            elif op.op in ("sub", "omit"):
                if assisted:
                    counts.IF_a += op.weight
                else:
                    counts.IF_m += op.weight
            elif op.op == "ins":
                counts.corrected_omissions += op.weight

    counts.U = counts.T_len - counts.S
    counts.K = counts.U + counts.IF_m + counts.IF_a + counts.CNE
    return counts
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 27 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Accumulate episodes into keystroke counts

Reduces aligned repair episodes to C/INF/IF/F-style quantities, with IF
split into manual and assisted ledgers since autocorrect fixes a real
tap error with zero fixing keystrokes.

Corrected omissions are tracked separately and never folded into IF: a
character the user failed to type has no erroneous keystroke behind it,
so counting it as an error would invent mistakes that never happened."
```

---

### Task 7: Vocabulary-based INF lower bound

Estimates uncorrected errors — the only quantity that cannot be recovered from repairs.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `load_vocabulary(path: str = "/usr/share/dict/words", allowlist: set[str] | None = None) -> set[str]`; `estimate_inf(final_text: str, vocab: set[str]) -> int`

**Why this is a lower bound.** Out-of-vocabulary tokens catch non-word errors (`bipe`). Real-word errors (`their` for `there`) are invisible to a dictionary. Every metric derived from this therefore carries a `_lower_bound` suffix. This is the spec's Departure 4.

For each OOV token, add its minimum edit distance to any vocabulary word of similar length, capped at the token's own length. Restricting candidates to `abs(len(word) - len(token)) <= 2` keeps this fast enough on a ~236k-word list without changing the result, because a larger length gap cannot beat the cap.

- [ ] **Step 1: Write the failing test**

```python
def test_estimate_inf_returns_zero_for_clean_text():
    vocab = {"the", "bike", "is", "red"}
    assert fm.estimate_inf("the bike is red", vocab) == 0


def test_estimate_inf_counts_edit_distance_of_out_of_vocabulary_words():
    vocab = {"the", "bike", "is", "red"}
    # "bipe" is one substitution away from "bike".
    assert fm.estimate_inf("the bipe is red", vocab) == 1


def test_estimate_inf_is_case_and_punctuation_insensitive():
    vocab = {"the", "bike", "is", "red"}
    assert fm.estimate_inf("The bike, is red!", vocab) == 0


def test_estimate_inf_misses_real_word_errors_by_design():
    # This is the documented lower-bound behaviour, not a bug: "their" is a
    # real word, so a dictionary cannot know "there" was meant.
    vocab = {"their", "there", "car"}
    assert fm.estimate_inf("their car", vocab) == 0


def test_load_vocabulary_reads_system_word_list():
    vocab = fm.load_vocabulary()
    assert "bike" in vocab
    assert len(vocab) > 10000


def test_load_vocabulary_applies_allowlist():
    vocab = fm.load_vocabulary(allowlist={"freetyperecorder"})
    assert "freetyperecorder" in vocab
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k inf or vocabulary`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'estimate_inf'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
import re

SYSTEM_WORD_LIST = "/usr/share/dict/words"
_TOKEN_PATTERN = re.compile(r"[a-z']+")


def load_vocabulary(path=SYSTEM_WORD_LIST, allowlist=None):
    """Load a lowercase vocabulary, plus any project-specific allowlist."""
    vocab = set()
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            word = line.strip().lower()
            if word:
                vocab.add(word)
    if allowlist:
        vocab.update(w.lower() for w in allowlist)
    return vocab


def _edit_distance(a, b):
    if a == b:
        return 0
    previous = list(range(len(b) + 1))
    for i, char_a in enumerate(a, start=1):
        current = [i]
        for j, char_b in enumerate(b, start=1):
            cost = 0 if char_a == char_b else 1
            current.append(min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + cost,
            ))
        previous = current
    return previous[-1]


def estimate_inf(final_text, vocab):
    """Lower bound on uncorrected errors left in the final text.

    Counts, for every out-of-vocabulary token, its minimum edit distance to a
    vocabulary word. Real-word errors (their/there) are invisible to this
    method by construction, which is exactly why the result is a lower bound
    and why every metric derived from it is reported as such.
    """
    by_length = {}
    for word in vocab:
        by_length.setdefault(len(word), []).append(word)

    total = 0
    for token in _TOKEN_PATTERN.findall(final_text.lower()):
        if token in vocab:
            continue
        best = len(token)
        for length in range(len(token) - 2, len(token) + 3):
            for candidate in by_length.get(length, ()):
                distance = _edit_distance(token, candidate)
                if distance < best:
                    best = distance
                    if best == 1:
                        break
            if best == 1:
                break
        total += best
    return total
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 33 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Add vocabulary-based lower bound for uncorrected errors

Uncorrected errors are the one quantity repairs cannot reveal, since
the user never touched those characters. Estimates them from
out-of-vocabulary tokens in the final text.

Real-word errors are invisible to a dictionary, so this is strictly a
lower bound, and a test pins that behaviour so it is not later mistaken
for a defect."
```

---

### Task 8: Metric computation

Turns counts into the reported metric set, with bounded metrics clearly named and assisted metrics gated.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: `Counts` (Task 5), `Episode` (Task 4)
- Produces: `compute_metrics(counts: Counts, inf_lower_bound: int, episodes: list[Episode], total_keystrokes: int, include_assisted: bool = False) -> dict[str, float | int]`

**Formulas**, verbatim from the spec's Stage 3. `D = U + IF`.

```
corrected_error_rate           = IF / D
kspc_effort                    = (U + IF + F) / D
kspc_output                    = (K + F) / T_len
manual_correction_efficiency   = IF_m / F
coverage                       = (IF + CNE) / K
raw_tap_error_rate_lower_bound = (IF_m + IF_a + INF) / D
uncorrected_error_rate_lower_bound = INF / D
total_error_rate_lower_bound   = (INF + IF) / D
conscientiousness_upper_bound  = IF / (IF + INF)
```

Note `conscientiousness` is an **upper** bound, not a lower one: `INF` sits in its denominator, so understating `INF` overstates the ratio. Every zero denominator yields `0.0`.

- [ ] **Step 1: Write the failing test**

```python
def test_compute_metrics_uses_spec_formulas():
    counts = fm.Counts(
        T_len=100, S=0.0, U=100.0,
        IF_m=8.0, IF_a=2.0, CNE=5.0, corrected_omissions=0.0,
        F=6, K=115.0,
    )
    metrics = fm.compute_metrics(counts, inf_lower_bound=4, episodes=[],
                                 total_keystrokes=121, include_assisted=True)
    # D = U + IF = 100 + 10 = 110
    assert round(metrics["corrected_error_rate"], 6) == round(10 / 110, 6)
    assert round(metrics["kspc_effort"], 6) == round((100 + 10 + 6) / 110, 6)
    assert round(metrics["kspc_output"], 6) == round((115 + 6) / 100, 6)
    assert round(metrics["manual_correction_efficiency"], 6) == round(8 / 6, 6)
    assert round(metrics["coverage"], 6) == round((10 + 5) / 115, 6)
    assert round(metrics["raw_tap_error_rate_lower_bound"], 6) == round(14 / 110, 6)
    assert round(metrics["total_error_rate_lower_bound"], 6) == round(14 / 110, 6)
    assert round(metrics["uncorrected_error_rate_lower_bound"], 6) == round(4 / 110, 6)


def test_compute_metrics_gates_assisted_metrics_by_default():
    counts = fm.Counts(T_len=10, U=10.0, IF_m=1.0, IF_a=1.0, F=1, K=12.0)
    gated = fm.compute_metrics(counts, 0, [], 13)
    assert "assistance_share" not in gated
    assert "IF_a" not in gated

    ungated = fm.compute_metrics(counts, 0, [], 13, include_assisted=True)
    assert round(ungated["assistance_share"], 6) == 0.5


def test_compute_metrics_survives_empty_session():
    metrics = fm.compute_metrics(fm.Counts(), 0, [], 0)
    assert metrics["corrected_error_rate"] == 0.0
    assert metrics["coverage"] == 0.0


def test_compute_metrics_reports_per_mechanism_episode_counts():
    episodes = [
        fm.Episode(kind="backspace", start_index=0, end_index=1, typed="a", intended="b"),
        fm.Episode(kind="backspace", start_index=2, end_index=3, typed="c", intended="d"),
        fm.Episode(kind="cursor_move", start_index=4, end_index=5, typed="e", intended="f"),
    ]
    metrics = fm.compute_metrics(fm.Counts(T_len=1, U=1.0, K=1.0), 0, episodes, 1)
    assert metrics["episodes_backspace"] == 2
    assert metrics["episodes_cursor_move"] == 1
    assert metrics["episodes_autocorrect"] == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k compute_metrics`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'compute_metrics'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
ALL_MECHANISMS = (
    "backspace", "bulk_delete", "cursor_move",
    "autocorrect", "suggestion", "select_retype",
)


def _ratio(numerator, denominator):
    return numerator / denominator if denominator else 0.0


def compute_metrics(counts, inf_lower_bound, episodes, total_keystrokes,
                    include_assisted=False):
    """Compute the reported metric set from accumulated counts.

    Metrics depending on INF carry a _lower_bound suffix, because INF comes
    from a dictionary check that cannot see real-word errors. Conscientiousness
    is an *upper* bound instead: INF sits in its denominator, so understating
    INF overstates the ratio.

    Assisted metrics are gated behind include_assisted because the
    autocorrect/suggestion detection rule is not yet validated against
    hand-labelled screen recordings (spec, Departure 2).
    """
    total_if = counts.IF_m + counts.IF_a
    denominator = counts.U + total_if

    metrics = {
        "final_text_length": counts.T_len,
        "system_supplied_chars": round(counts.S, 4),
        "user_chars_in_text": round(counts.U, 4),
        "IF": round(total_if, 4),
        "CNE": round(counts.CNE, 4),
        "corrected_omissions": round(counts.corrected_omissions, 4),
        "F": counts.F,
        "INF_lower_bound": inf_lower_bound,

        "corrected_error_rate": _ratio(total_if, denominator),
        "kspc_effort": _ratio(counts.U + total_if + counts.F, denominator),
        "kspc_output": _ratio(counts.K + counts.F, counts.T_len),
        "manual_correction_efficiency": _ratio(counts.IF_m, counts.F),
        "coverage": _ratio(total_if + counts.CNE, counts.K),

        "raw_tap_error_rate_lower_bound": _ratio(total_if + inf_lower_bound, denominator),
        "total_error_rate_lower_bound": _ratio(total_if + inf_lower_bound, denominator),
        "uncorrected_error_rate_lower_bound": _ratio(inf_lower_bound, denominator),
        "conscientiousness_upper_bound": _ratio(total_if, total_if + inf_lower_bound),

        "alignment_cap_hits": sum(1 for e in episodes if e.cap_hit),
        "abandoned_episodes": sum(1 for e in episodes if e.is_abandoned),
        "completions": sum(1 for e in episodes if e.is_completion),
        "total_keystrokes": total_keystrokes,
    }

    for mechanism in ALL_MECHANISMS:
        metrics[f"episodes_{mechanism}"] = sum(1 for e in episodes if e.kind == mechanism)

    for mechanism in ALL_MECHANISMS:
        latencies = [e.latency_ms for e in episodes if e.kind == mechanism]
        metrics[f"mean_latency_ms_{mechanism}"] = (
            round(sum(latencies) / len(latencies), 3) if latencies else 0.0
        )

    if include_assisted:
        metrics["IF_m"] = round(counts.IF_m, 4)
        metrics["IF_a"] = round(counts.IF_a, 4)
        metrics["assistance_share"] = _ratio(counts.IF_a, total_if)

    return metrics
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 37 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Compute the reported error-metric set

Implements the Soukoreff & MacKenzie error-rate family over the
accumulated counts, plus per-mechanism episode counts and latencies.

Metrics that depend on the dictionary-estimated INF carry an explicit
_lower_bound suffix so they cannot be mistaken for point estimates, and
the assisted-fix metrics are gated behind a flag until the autocorrect
detection rule is validated against screen recordings."
```

---

### Task 9: CLI and report output

Wires the stages together into a runnable tool over session directories.

**Files:**
- Modify: `scripts/freetype_metrics.py`
- Test: `tests/test_freetype_metrics.py`

**Interfaces:**
- Consumes: everything from Tasks 1–7
- Produces: `analyze_session(session_dir: str, vocab: set[str], include_assisted: bool = False) -> dict`; `main(argv: list[str] | None = None) -> int`

A session directory is one FreeTypeRecorder session folder containing `keystrokes.csv` and optionally `session_meta.json` (participant, hand, session number — see the app README). Metadata fields are merged into the output row when present, so results can be grouped by participant and hand condition.

Output: a summary CSV with one row per session, plus `freetype_episodes.json` written **into each session directory**, holding that session's episode list so any number can be traced back to the events that produced it.

- [ ] **Step 1: Write the failing test**

```python
import json


def _write_session(tmp_path, rows, meta=None):
    session_dir = tmp_path / "Alex,1,left"
    session_dir.mkdir()
    header = ("t_ms,event_type,replacement_text,range_start,range_length,"
              "resulting_text_length,inter_key_interval_ms\n")
    lines = [header]
    for row in rows:
        lines.append(",".join(str(value) for value in row) + "\n")
    (session_dir / "keystrokes.csv").write_text("".join(lines))
    if meta:
        (session_dir / "session_meta.json").write_text(json.dumps(meta))
    return session_dir


def test_analyze_session_reads_a_session_directory(tmp_path):
    rows = [
        (0, "insert", "b", 0, 0, 1, 0),
        (100, "insert", "i", 1, 0, 2, 100),
        (200, "insert", "p", 2, 0, 3, 100),
        (300, "insert", "e", 3, 0, 4, 100),
        (800, "delete", "", 3, 1, 3, 500),
        (900, "delete", "", 2, 1, 2, 100),
        (1000, "delete", "", 1, 1, 1, 100),
        (1100, "insert", "i", 1, 0, 2, 100),
        (1200, "insert", "k", 2, 0, 3, 100),
        (1300, "insert", "e", 3, 0, 4, 100),
    ]
    session_dir = _write_session(tmp_path, rows,
                                 meta={"participant": "Alex", "hand": "left"})
    result = fm.analyze_session(str(session_dir), vocab={"bike"})
    assert result["final_text"] == "bike"
    assert result["participant"] == "Alex"
    assert result["hand"] == "left"
    assert result["episodes_backspace"] == 1
    assert result["INF_lower_bound"] == 0
    assert (session_dir / "freetype_episodes.json").exists()


def test_main_writes_summary_csv(tmp_path):
    rows = [
        (0, "insert", "b", 0, 0, 1, 0),
        (100, "insert", "i", 1, 0, 2, 100),
        (200, "insert", "k", 2, 0, 3, 100),
        (300, "insert", "e", 3, 0, 4, 100),
    ]
    session_dir = _write_session(tmp_path, rows)
    out_csv = tmp_path / "summary.csv"
    exit_code = fm.main([str(session_dir), "--out", str(out_csv)])
    assert exit_code == 0
    text = out_csv.read_text()
    assert "final_text_length" in text
    assert len(text.strip().splitlines()) == 2


def test_main_reports_replay_warnings(tmp_path, capsys):
    rows = [(0, "insert", "b", 0, 0, 99, 0)]
    session_dir = _write_session(tmp_path, rows)
    fm.main([str(session_dir), "--out", str(tmp_path / "s.csv")])
    assert "length mismatch" in capsys.readouterr().out
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v -k analyze_session or main`
Expected: FAIL — `AttributeError: module 'freetype_metrics' has no attribute 'analyze_session'`

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/freetype_metrics.py`:

```python
import argparse
import json
import os
import sys

META_FIELDS = ("participant", "hand", "session", "prompt", "phone")


def analyze_session(session_dir, vocab, include_assisted=False):
    """Run the full pipeline over one session directory."""
    events = read_events(os.path.join(session_dir, "keystrokes.csv"))
    replayed, warnings = replay(events)
    labels = classify(replayed)
    episodes = mark_reverts(replayed, extract_episodes(replayed, labels))
    counts = accumulate(replayed, labels, episodes)

    final_text = replayed[-1].buffer_after if replayed else ""
    inf_lower_bound = estimate_inf(final_text, vocab)

    metrics = compute_metrics(
        counts, inf_lower_bound, episodes,
        total_keystrokes=len(events),
        include_assisted=include_assisted,
    )
    metrics["session_dir"] = os.path.basename(os.path.normpath(session_dir))
    metrics["final_text"] = final_text
    metrics["replay_warnings"] = len(warnings)

    meta_path = os.path.join(session_dir, "session_meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, encoding="utf-8") as handle:
            meta = json.load(handle)
        for key in META_FIELDS:
            if key in meta:
                metrics[key] = meta[key]

    with open(os.path.join(session_dir, "freetype_episodes.json"), "w",
              encoding="utf-8") as handle:
        json.dump([
            {
                "kind": episode.kind,
                "start_index": episode.start_index,
                "end_index": episode.end_index,
                "typed": episode.typed,
                "intended": episode.intended,
                "is_completion": episode.is_completion,
                "is_abandoned": episode.is_abandoned,
                "fix_keystrokes": episode.fix_keystrokes,
                "latency_ms": episode.latency_ms,
                "cap_hit": episode.cap_hit,
                "ops": [
                    {"op": op.op, "typed": op.typed,
                     "intended": op.intended, "weight": op.weight}
                    for op in episode.ops
                ],
            }
            for episode in episodes
        ], handle, indent=2)

    metrics["_warnings"] = warnings
    return metrics


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Error metrics for FreeTypeRecorder free-typing sessions."
    )
    parser.add_argument("session_dirs", nargs="+",
                        help="session directories containing keystrokes.csv")
    parser.add_argument("--out", required=True, help="summary CSV path")
    parser.add_argument("--assisted-metrics", action="store_true",
                        help="emit IF_m / IF_a / assistance_share. The "
                             "autocorrect detection rule is unvalidated; do "
                             "not use for reported results until calibrated.")
    parser.add_argument("--allowlist", default=None,
                        help="file of extra vocabulary words, one per line")
    args = parser.parse_args(argv)

    allowlist = None
    if args.allowlist:
        with open(args.allowlist, encoding="utf-8") as handle:
            allowlist = {line.strip() for line in handle if line.strip()}
    vocab = load_vocabulary(allowlist=allowlist)

    rows = []
    for session_dir in args.session_dirs:
        result = analyze_session(session_dir, vocab, args.assisted_metrics)
        for warning in result.pop("_warnings"):
            print(f"{result['session_dir']}: {warning}")
        rows.append(result)

    if not rows:
        print("no sessions analysed")
        return 1

    fieldnames = list(rows[0].keys())
    for row in rows[1:]:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)

    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    print(f"wrote {len(rows)} session rows to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 40 passed

- [ ] **Step 5: Verify the CLI runs end to end**

```bash
mkdir -p /tmp/ftr_check/"Alex,1,left"
printf 't_ms,event_type,replacement_text,range_start,range_length,resulting_text_length,inter_key_interval_ms\n0,insert,b,0,0,1,0\n100,insert,i,1,0,2,100\n200,insert,p,2,0,3,100\n300,insert,e,3,0,4,100\n800,delete,,3,1,3,500\n900,delete,,2,1,2,100\n1000,delete,,1,1,1,100\n1100,insert,i,1,0,2,100\n1200,insert,k,2,0,3,100\n1300,insert,e,3,0,4,100\n' > /tmp/ftr_check/"Alex,1,left"/keystrokes.csv
$PY scripts/freetype_metrics.py /tmp/ftr_check/"Alex,1,left" --out /tmp/ftr_check/summary.csv
```

Expected: `wrote 1 session rows to /tmp/ftr_check/summary.csv`, and the CSV shows `episodes_backspace` = 1, `IF` = 1.0, `CNE` = 2.0, `F` = 3.

- [ ] **Step 6: Commit**

```bash
git add scripts/freetype_metrics.py tests/test_freetype_metrics.py
git commit -m "Add CLI over session directories with per-session episode dumps

Wires the stages into a runnable tool: one summary CSV row per session,
merged with session_meta.json when present so results group by
participant and hand, plus a freetype_episodes.json in each session
directory so every number traces back to the events behind it.

Assisted-fix metrics stay behind --assisted-metrics, with the flag help
stating they are not fit for reported results until calibrated."
```

---

### Task 10: Documentation

Records the new script where the project's other analysis tooling is documented.

**Files:**
- Modify: `scripts/CLAUDE.md`

- [ ] **Step 1: Add the script to the scripts guide**

Add to `scripts/CLAUDE.md`, as a new section after the "Typical flow" list:

```markdown
## FreeTypeRecorder (free typing, no target text)

`freetype_metrics.py <session_dir> [...] --out summary.csv [--assisted-metrics]`

Error metrics for FreeTypeRecorder sessions. Free composition has no target
text, so intent is recovered from the user's four repair mechanisms
(backspace, autocorrect, suggestion, cursor movement) and mapped onto the
Soukoreff & MacKenzie C/INF/IF/F taxonomy.

Reads `<session_dir>/keystrokes.csv`, writes a summary CSV plus a
`freetype_episodes.json` per session directory.

Metrics ending `_lower_bound` depend on a dictionary estimate of uncorrected
errors and must never be reported as point estimates. `--assisted-metrics`
is gated: the autocorrect/suggestion detection rule is not yet validated
against hand-labelled screen recordings.

Design: `docs/superpowers/specs/2026-08-11-freetyperecorder-error-metrics-design.md`
```

- [ ] **Step 2: Run the full test suite**

Run: `$PY -m pytest tests/test_freetype_metrics.py -v`
Expected: PASS, 40 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/CLAUDE.md
git commit -m "Document freetype_metrics.py in the scripts guide

Notes the two reporting constraints so a future reader does not treat
the bounded metrics as point estimates or use the gated assisted-fix
metrics before the detection rule is calibrated."
```

---

## Validation follow-up (not part of this plan)

The spec requires calibrating `AC_WINDOW_MS` against hand-labelled screen recordings before `IF_m`, `IF_a`, or `assistance_share` can be reported. That work needs the recordings and a labelling pass, so it is a separate task, and until it is done the `--assisted-metrics` flag stays off for any reported result.
