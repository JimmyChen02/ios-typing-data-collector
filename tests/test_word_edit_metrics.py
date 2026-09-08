import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import word_edit_metrics as wem


HEADER = [
    "t_ms", "event_type", "replaced_text", "replacement_text",
    "range_start", "range_length", "resulting_text_length",
    "inter_key_interval_ms", "selected_length_before", "marked_text_before",
]


def _write_session(tmp_path, events):
    """events: list of (event_type, replaced, replacement, start, length).

    resulting_text_length is derived by replaying the ranges, so tests only
    describe the edits.
    """
    rows = []
    text_len = 0
    t = 0.0
    for event_type, replaced, replacement, start, length in events:
        text_len = text_len - length + len(replacement.encode("utf-16-le")) // 2
        rows.append({
            "t_ms": f"{t:.3f}",
            "event_type": event_type,
            "replaced_text": replaced,
            "replacement_text": replacement,
            "range_start": start,
            "range_length": length,
            "resulting_text_length": text_len,
            "inter_key_interval_ms": "100.000",
            "selected_length_before": 0,
            "marked_text_before": 0,
        })
        t += 250.0
    path = tmp_path / "keystrokes.csv"
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER)
        writer.writeheader()
        writer.writerows(rows)
    return path


def _type(text, start_at=0):
    return [("insert", "", ch, start_at + i, 0) for i, ch in enumerate(text)]


def test_clean_words_are_not_edited(tmp_path):
    path = _write_session(tmp_path, _type("hi there"))
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["hi", "there"]
    assert totals["edited_words"] == 0
    assert all(not w["edited"] for w in words)
    assert totals["total_words"] == 2
    assert totals["total_chars"] == len("hi there")


def test_midword_backspace_is_backspace_retype(tmp_path):
    # types "teh", backspaces "h" and "e", retypes "he" -> final "the"
    events = _type("teh")
    events += [("delete", "h", "", 2, 1), ("delete", "e", "", 1, 1)]
    events += [("insert", "", "h", 1, 0), ("insert", "", "e", 2, 0)]
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["the"]
    assert words[0]["edited"]
    assert words[0]["mechanisms"] == [wem.BACKSPACE]
    assert totals["edited_words"] == 1


def test_full_word_delete_and_retype_is_attributed(tmp_path):
    # "teh" deleted entirely, then "the" typed in its place
    events = _type("teh")
    events += [
        ("delete", "h", "", 2, 1),
        ("delete", "e", "", 1, 1),
        ("delete", "t", "", 0, 1),
    ]
    events += _type("the")
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["the"]
    assert words[0]["edited"]
    assert words[0]["mechanisms"] == [wem.BACKSPACE]


def test_deleting_neighbor_word_does_not_mark_survivor(tmp_path):
    # "hi xyz" -> delete "xyz" char by char -> final "hi " ; "hi" untouched
    events = _type("hi xyz")
    events += [
        ("delete", "z", "", 5, 1),
        ("delete", "y", "", 4, 1),
        ("delete", "x", "", 3, 1),
    ]
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["hi"]
    # the first two deletes touch no surviving word; the last one lands
    # next to the trailing space, still outside any word
    assert not words[0]["edited"]
    assert totals["unattributed_events"] == 3


def test_autocorrect_replace_marks_word(tmp_path):
    # "teh" + autocorrect replace at the space -> "the "
    events = _type("teh")
    events += [("replace", "teh", "the", 0, 3), ("insert", "", " ", 3, 0)]
    events += _type("cat", start_at=4)
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["the", "cat"]
    assert words[0]["edited"]
    assert words[0]["mechanisms"] == ["autocorrect"]
    assert not words[1]["edited"]
    assert words[0]["examples"] == [("autocorrect", "teh → the")]


def test_post_commit_revision_counts_as_edited(tmp_path):
    # types "the cat", then goes back and deletes/retypes "a" in "cat"
    events = _type("the cat")
    events += [("delete", "a", "", 5, 1), ("insert", "", "a", 5, 0)]
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert [w["text"] for w in words] == ["the", "cat"]
    assert not words[0]["edited"]
    assert words[1]["edited"]
    assert words[1]["mechanisms"] == [wem.BACKSPACE]


def test_percentages_and_multi_word_session(tmp_path):
    # 4 words, 1 edited
    events = _type("one two three ")
    events += _type("fuor", start_at=14)
    events += [("delete", "r", "", 17, 1), ("delete", "o", "", 16, 1),
               ("delete", "u", "", 15, 1)]
    events += _type("our", start_at=15)
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    assert totals["total_words"] == 4
    assert totals["edited_words"] == 1
    assert words[3]["text"] == "four"
    assert words[3]["edited"]


def test_summary_md_contents(tmp_path):
    events = _type("teh")
    events += [("replace", "teh", "the", 0, 3), ("insert", "", " ", 3, 0)]
    path = _write_session(tmp_path, events)
    words, totals = wem.analyze_session(path)
    out = tmp_path / "summary.md"
    wem.write_summary_md("test", words, totals, out)
    content = out.read_text(encoding="utf-8")
    assert "Purpose of this export" in content
    assert "edited words: 1 (100.0%)" in content
    assert "`teh → the`" in content
    assert "<details>" in content


def test_word_csv_round_trip(tmp_path):
    events = _type("hi there")
    path = _write_session(tmp_path, events)
    words, _totals = wem.analyze_session(path)
    out = tmp_path / "words.csv"
    wem.write_word_csv(words, out)
    with open(out, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert [r["word"] for r in rows] == ["hi", "there"]
    assert [r["edited"] for r in rows] == ["0", "0"]


def test_cli_groups_word_artifacts_by_session(tmp_path):
    path = _write_session(tmp_path, _type("hi there"))
    out_dir = tmp_path / "processed"
    wem.main([str(path), "--out-dir", str(out_dir)])
    session_dir = out_dir / tmp_path.name
    assert (session_dir / f"{tmp_path.name}_word_edits.csv").is_file()
    assert (session_dir / f"{tmp_path.name}_word_summary.md").is_file()
