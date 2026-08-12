import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import substitution_metrics as sm


HEADER = [
    "t_ms", "event_type", "replaced_text", "replacement_text",
    "range_start", "range_length", "resulting_text_length",
    "inter_key_interval_ms", "selected_length_before", "marked_text_before",
]


def write_keystrokes_csv(tmp_path, rows, name="Alex,1,left,ac_on"):
    session = tmp_path / name
    session.mkdir()
    path = session / "keystrokes.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(HEADER)
        writer.writerows(rows)
    return session


def kinds(session):
    return [row["substitution_kind"] for row in sm.classify_rows(session / "keystrokes.csv")]


def test_plain_insert_and_delete_get_no_label(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
        (100, "delete", "a", "", 0, 1, 0, 100, 0, 0),
    ])
    assert kinds(session) == ["", ""]


def test_selection_before_change_is_manual_overtype(tmp_path):
    # Certain: the system never substitutes into a selection.
    session = write_keystrokes_csv(tmp_path, [
        (500, "replace", "cat", "dog", 0, 3, 3, 500, 3, 0),
    ])
    assert kinds(session) == ["manual_overtype"]


def test_case_only_change_is_sentence_caps(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (500, "replace", "i", "I", 0, 1, 1, 500, 0, 0),
    ])
    assert kinds(session) == ["sentence_caps"]


def test_punctuation_swap_is_smart_punct(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (500, "replace", "'", "’", 0, 1, 1, 500, 0, 0),
    ])
    assert kinds(session) == ["smart_punct"]


def test_substitution_with_no_preceding_keystroke_is_a_bar_tap(tmp_path):
    # Certain: autocorrect and inline prediction both need a keystroke to fire,
    # so a substitution out of nowhere can only be a QuickType tap.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "t", 0, 0, 1, 0, 0, 0),
        (5000, "replace", "tomo", "tomorrow ", 0, 4, 9, 5000, 0, 0),
    ])
    assert kinds(session)[-1] == "quicktype_pick"


def test_correction_after_space_is_autocorrect(tmp_path):
    # "teh" -> "the" does not extend what was typed: a correction.
    session = write_keystrokes_csv(tmp_path, [
        (900, "insert", "", " ", 3, 0, 4, 100, 0, 0),
        (920, "replace", "teh", "the", 0, 3, 4, 20, 0, 0),
    ])
    assert kinds(session)[-1] == "autocorrect"


def test_completion_after_space_is_inline_prediction(tmp_path):
    # "tomo" -> "tomorrow" extends what was typed: a completion.
    session = write_keystrokes_csv(tmp_path, [
        (900, "insert", "", " ", 4, 0, 5, 100, 0, 0),
        (920, "replace", "tomo", "tomorrow ", 0, 4, 9, 20, 0, 0),
    ])
    assert kinds(session)[-1] == "inline_prediction"


def test_marked_text_wins_over_the_prefix_heuristic(tmp_path):
    # Marked text is mechanical evidence a prediction was pending, so it
    # outranks the shape of the strings.
    session = write_keystrokes_csv(tmp_path, [
        (900, "insert", "", " ", 3, 0, 4, 100, 0, 0),
        (920, "replace", "teh", "the", 0, 3, 4, 20, 0, 1),
    ])
    assert kinds(session)[-1] == "inline_prediction"


def test_stale_keystroke_does_not_count_as_a_trigger(tmp_path):
    # A space long ago did not cause this substitution.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", " ", 3, 0, 4, 0, 0, 0),
        (9000, "replace", "teh", "the", 0, 3, 4, 9000, 0, 0),
    ])
    assert kinds(session)[-1] == "quicktype_pick"


def test_summary_counts_each_kind(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
        (500, "replace", "cat", "dog", 0, 3, 3, 500, 3, 0),
        (900, "insert", "", " ", 3, 0, 4, 400, 0, 0),
        (920, "replace", "teh", "the", 0, 3, 4, 20, 0, 0),
    ])
    summary, _ = sm.summarize(session)
    assert summary["keystroke_rows"] == 4
    assert summary["substitution_rows"] == 2
    assert summary["manual_overtype_rows"] == 1
    assert summary["autocorrect_rows"] == 1


def test_session_dir_accepted_as_well_as_file(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
    ])
    from_dir, _ = sm.summarize(session)
    from_file, _ = sm.summarize(session / "keystrokes.csv")
    assert from_dir == from_file


def test_labeled_output_keeps_original_columns(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (900, "insert", "", " ", 3, 0, 4, 100, 0, 0),
        (920, "replace", "teh", "the", 0, 3, 4, 20, 0, 0),
    ])
    out = tmp_path / "summary.csv"
    labeled = tmp_path / "labeled.csv"
    sm.main([str(session), "--out", str(out), "--labeled-out", str(labeled)])
    with labeled.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert [column in rows[0] for column in HEADER] == [True] * len(HEADER)
    assert rows[-1]["substitution_kind"] == "autocorrect"
