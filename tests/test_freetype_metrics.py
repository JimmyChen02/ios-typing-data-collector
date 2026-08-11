import csv
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


def test_replay_warns_non_ascii_only_once():
    # Once the buffer contains a non-BMP character, every later event is also
    # a non-ASCII buffer for the same, already-known reason. A session-level
    # `len(warnings)` count would be wildly misleading if this fired per
    # event, so replay() must emit exactly one "non-ASCII" warning per call.
    events = [
        make_event("insert", "a", 0, 0, 1),
        make_event("insert", "\U0001F600", 1, 0, 2),  # first non-ASCII event
        make_event("insert", "b", 3, 0, 3),
        make_event("insert", "c", 4, 0, 4),
        make_event("insert", "d", 5, 0, 5),
    ]
    replayed, warnings = fm.replay(events)
    assert replayed[-1].buffer_after == "a\U0001F600bcd"
    non_ascii_warnings = [w for w in warnings if "non-ASCII" in w]
    assert len(non_ascii_warnings) == 1
    assert "event 1" in non_ascii_warnings[0]


def test_read_events_parses_csv(tmp_path):
    csv_path = tmp_path / "keystrokes.csv"
    header = (
        "t_ms,event_type,replacement_text,range_start,range_length,"
        "resulting_text_length,inter_key_interval_ms"
    )
    rows = [
        ["0.0", "insert", "b", "0", "0", "1", "0.0"],
        # replacement_text containing a comma must be RFC4180-quoted by the
        # iOS writer; csv.DictReader must still parse it as one field.
        ["120.5", "replace", "bike, sorry", "0", "1", "11", "120.5"],
    ]
    with open(csv_path, "w", newline="", encoding="utf-8") as handle:
        handle.write(header + "\n")
        writer = csv.writer(handle)
        writer.writerows(rows)

    events = fm.read_events(csv_path)

    assert len(events) == 2
    assert all(isinstance(e, fm.Event) for e in events)

    first = events[0]
    assert first.t_ms == 0.0
    assert isinstance(first.t_ms, float)
    assert first.event_type == "insert"
    assert first.replacement_text == "b"
    assert first.range_start == 0
    assert isinstance(first.range_start, int)
    assert first.range_length == 0
    assert first.resulting_text_length == 1
    assert isinstance(first.resulting_text_length, int)
    assert first.inter_key_interval_ms == 0.0
    assert isinstance(first.inter_key_interval_ms, float)

    second = events[1]
    assert second.t_ms == 120.5
    assert second.event_type == "replace"
    assert second.replacement_text == "bike, sorry"
    assert second.range_start == 0
    assert second.range_length == 1
    assert second.resulting_text_length == 11
    assert second.inter_key_interval_ms == 120.5


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


def test_all_optimal_alignments_handles_long_input_without_recursion_error():
    # A held backspace over a long paragraph in a free-typing session can
    # produce an arbitrarily long typed/intended region. walk()'s traversal
    # must not recurse with Python's call stack - depth used to scale with
    # len(a) + len(b), which `cap` does not bound (cap only limits how many
    # completed alignments are kept), so a long single-path input like this
    # one used to raise RecursionError well before reaching 2000.
    msd, alignments = fm.all_optimal_alignments("x" * 2000, "")
    assert msd == 2000
    # Deleting against an empty intended string is unambiguous: there is
    # exactly one optimal alignment (omit every character).
    assert len(alignments) == 1


def test_all_optimal_alignments_respects_cap_and_flags_cap_hit():
    # "xxxxx" typed vs "xxx" intended: every optimal alignment matches 3 of
    # the 5 x's and omits the other 2, so the true count is C(5,2) = 10,
    # which exceeds a small explicit cap of 8. The truncated set must still
    # be internally valid even though it's incomplete.
    msd, alignments = fm.all_optimal_alignments("xxxxx", "xxx", cap=8)
    assert msd == 2
    assert len(alignments) <= 8

    ops, cap_hit = fm.weighted_ops("xxxxx", "xxx", cap=8)
    assert cap_hit is True

    for alignment in alignments:
        typed = "".join(op[1] for op in alignment)
        intended = "".join(op[2] for op in alignment)
        assert typed == "xxxxx"
        assert intended == "xxx"


def test_omit_op_carries_typed_char_with_empty_intended():
    # "abc" typed vs "ac" intended: the user typed an extra "b" that was
    # never intended. This is unambiguous (one edit), so there's exactly one
    # optimal alignment. `omit` must carry the typed character with
    # intended == "" - never the reverse - since a later task keys off
    # `intended == ""` to identify omissions.
    _, alignments = fm.all_optimal_alignments("abc", "ac")
    assert len(alignments) == 1
    omits = [op for op in alignments[0] if op[0] == "omit"]
    assert len(omits) == 1
    _, typed, intended = omits[0]
    assert typed == "b"
    assert intended == ""


def test_ins_op_carries_intended_char_with_empty_typed():
    # "ac" typed vs "abc" intended: the user never typed the intended "b" at
    # all. `ins` must carry intended == "b" with typed == "" - critically,
    # `typed` must never be non-empty for an `ins` op, or a later task would
    # wrongly count it as an erroneous keystroke the user actually made.
    _, alignments = fm.all_optimal_alignments("ac", "abc")
    assert len(alignments) == 1
    inserts = [op for op in alignments[0] if op[0] == "ins"]
    assert len(inserts) == 1
    _, typed, intended = inserts[0]
    assert typed == ""
    assert intended == "b"
