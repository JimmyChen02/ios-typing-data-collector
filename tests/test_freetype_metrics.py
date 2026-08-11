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
