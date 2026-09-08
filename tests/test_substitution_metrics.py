import csv
import sys
from pathlib import Path

import pytest

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


def classified(session):
    rows, _ = sm.classify_rows(session / "keystrokes.csv")
    return rows


def kinds(session):
    return [row["substitution_kind"] for row in classified(session)]


def test_plain_insert_and_delete_get_no_label(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
        (100, "delete", "a", "", 0, 1, 0, 100, 0, 0),
    ])
    for row in classified(session):
        assert [row[column] for column in sm.LABEL_COLUMNS] == [""] * len(sm.LABEL_COLUMNS)


def test_selection_before_change_is_manual_overtype(tmp_path):
    # Certain: the system never substitutes into a selection.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "cat", 0, 0, 3, 0, 0, 0),
        (500, "replace", "cat", "dog", 0, 3, 3, 500, 3, 0),
    ])
    rows = classified(session)
    assert rows[-1]["substitution_source"] == "manual_overtype"
    assert rows[-1]["substitution_source_confidence"] == "certain"
    assert rows[-1]["substitution_kind"] == "manual_overtype"


def test_punctuation_swap_is_smart_typography(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "'", 0, 0, 1, 0, 0, 0),
        (500, "replace", "'", "’", 0, 1, 1, 500, 0, 0),
    ])
    rows = classified(session)
    assert rows[-1]["substitution_source"] == "smart_typography"
    assert rows[-1]["substitution_kind"] == "smart_punct"


def test_case_only_correction_is_autocorrect_engine_capitalization(tmp_path):
    # Sentence auto-caps pre-shifts the keyboard and can never emit a replace,
    # so a case-only replace is the correction engine. The legacy alias keeps
    # calling it sentence_caps.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "i", 0, 0, 1, 0, 0, 0),
        (500, "replace", "i", "I", 0, 1, 1, 500, 0, 0),
    ])
    rows = classified(session)
    assert rows[-1]["substitution_source"] == "autocorrect_engine"
    assert rows[-1]["substitution_effect"] == "capitalization"
    assert rows[-1]["substitution_kind"] == "sentence_caps"


def test_multichar_case_correction_is_sentence_caps_too(tmp_path):
    # `Lol` -> `lol` sits in the high trailing-gap group, but the gap rule is
    # scoped to completions - a correction never reaches it.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "Lol", 0, 0, 3, 0, 0, 0),
        (900, "replace", "Lol", "lol", 0, 3, 3, 900, 0, 0),
        (913, "insert", "", " ", 3, 0, 4, 13, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "autocorrect_engine"
    assert rows[1]["substitution_kind"] == "sentence_caps"


def test_completion_with_high_trailing_gap_is_a_bar_tap(tmp_path):
    # The system auto-appends the space after a suggestion-bar tap ~13 ms
    # after the replacement - machine latency, not human timing.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "tomo", 0, 0, 4, 0, 0, 0),
        (900, "replace", "tomo", "tomorrow", 0, 4, 8, 900, 0, 0),
        (913, "insert", "", " ", 8, 0, 9, 13, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "suggestion_bar"
    assert rows[1]["substitution_source_confidence"] == "inferred"
    assert rows[1]["substitution_kind"] == "quicktype_pick"
    assert rows[1]["next_delimiter_gap_ms"] == "13.000"


def test_completion_with_low_trailing_gap_is_autocorrect_side(tmp_path):
    # ~5 ms means the typed space triggered the change. Without a marked-text
    # hint the completion is credited to the engine, flagged grey_zone because
    # the corpus has no confirmed inline prediction to calibrate against.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "read", 0, 0, 4, 0, 0, 0),
        (900, "replace", "read", "reading", 0, 4, 7, 900, 0, 0),
        (905, "insert", "", " ", 7, 0, 8, 5, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "autocorrect_engine"
    assert rows[1]["substitution_source_confidence"] == "grey_zone"
    assert rows[1]["substitution_kind"] == "autocorrect"


def test_marked_text_hint_flips_low_gap_completion_to_inline_prediction(tmp_path):
    # marked_text_before never fires on the substitution row itself; it is a
    # word-level signal on the inserts before it.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "tom", 0, 0, 3, 0, 0, 0),
        (200, "insert", "", "o", 3, 0, 4, 200, 0, 1),
        (900, "replace", "tomo", "tomorrow", 0, 4, 8, 700, 0, 0),
        (905, "insert", "", " ", 8, 0, 9, 5, 0, 0),
    ])
    rows = classified(session)
    assert rows[2]["substitution_source"] == "inline_prediction"
    assert rows[2]["substitution_source_confidence"] == "grey_zone"


def test_marked_text_hint_does_not_cross_a_delimiter(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 1),
        (100, "insert", "", " ", 1, 0, 2, 100, 0, 0),
        (200, "insert", "", "read", 2, 0, 6, 100, 0, 0),
        (900, "replace", "read", "reading", 2, 4, 9, 700, 0, 0),
        (905, "insert", "", " ", 9, 0, 10, 5, 0, 0),
    ])
    rows = classified(session)
    assert rows[3]["substitution_source"] == "autocorrect_engine"


def test_gap_inside_grey_zone_is_flagged(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "tomo", 0, 0, 4, 0, 0, 0),
        (900, "replace", "tomo", "tomorrow", 0, 4, 8, 900, 0, 0),
        (910, "insert", "", " ", 8, 0, 9, 10, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "suggestion_bar"
    assert rows[1]["substitution_source_confidence"] == "grey_zone"


def test_completion_without_following_delimiter_falls_back(tmp_path):
    # No trailing delimiter within the trigger window: the gap is undefined
    # and only the string shape is left.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "tomo", 0, 0, 4, 0, 0, 0),
        (900, "replace", "tomo", "tomorrow", 0, 4, 8, 900, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "inline_prediction"
    assert rows[1]["substitution_source_confidence"] == "inferred"
    assert rows[1]["next_delimiter_gap_ms"] == ""


def test_correction_after_space_is_autocorrect(tmp_path):
    # "teh" -> "the" does not extend what was typed: a correction.
    # iOS applies the correction first, then inserts the space that caused it.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_source"] == "autocorrect_engine"
    assert rows[1]["substitution_kind"] == "autocorrect"


def test_paste_rows_are_classified_like_replaces(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (500, "paste", "teh", "the", 0, 3, 3, 500, 3, 0),
    ])
    rows = classified(session)
    assert rows[-1]["substitution_source"] == "manual_overtype"
    assert rows[-1]["substitution_kind"] == "manual_overtype"


@pytest.mark.parametrize("old,new,effect", [
    ("i", "I", "capitalization"),
    ("Lol", "lol", "capitalization"),
    ("'", "’", "punctuation"),
    (" ", ". ", "punctuation"),   # double-space period
    ("its", "it's", "contraction"),
    ("ithacas", "Ithaca's", "contraction"),
    ("act", "actually", "completion"),
    ("helloworld", "hello world", "spacing"),
    ("teh", "the", "spelling"),
    ("coler", "cooler", "spelling"),
    ("", "x", "other"),
])
def test_classify_effect(old, new, effect):
    assert sm._classify_effect(old, new) == effect


def test_double_space_period_is_punctuation(tmp_path):
    # iOS logs the double-space shortcut as ` ` -> `. `. The flanking spaces
    # fail _is_punctuation on both sides, which used to read as a phantom
    # spelling correction in the summary.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "hi", 0, 0, 2, 0, 0, 0),
        (500, "insert", "", " ", 2, 0, 3, 500, 0, 0),
        (700, "replace", " ", ". ", 2, 1, 4, 200, 0, 0),
    ])
    rows = classified(session)
    assert rows[2]["substitution_effect"] == "punctuation"
    assert rows[2]["substitution_source"] == "autocorrect_engine"


def test_untouched_substitution_is_kept(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (905, "insert", "", " ", 3, 0, 4, 5, 0, 0),
        (1200, "insert", "", "x", 4, 0, 5, 295, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "kept"
    assert rows[1]["revert_latency_ms"] == ""


def test_deleting_and_retyping_the_original_is_reverted_to_original(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (905, "insert", "", " ", 3, 0, 4, 5, 0, 0),
        (2000, "delete", " ", "", 3, 1, 3, 1095, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 100, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "t", 0, 0, 1, 100, 0, 0),
        (2500, "insert", "", "e", 1, 0, 2, 100, 0, 0),
        (2600, "insert", "", "h", 2, 0, 3, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "reverted_to_original"
    assert rows[1]["revert_latency_ms"] == "1200.000"


def test_deleting_and_retyping_something_else_is_replaced_with_other(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 1200, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "t", 0, 0, 1, 100, 0, 0),
        (2500, "insert", "", "e", 1, 0, 2, 100, 0, 0),
        (2600, "insert", "", "a", 2, 0, 3, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "replaced_with_other"
    assert rows[1]["revert_latency_ms"] == "1200.000"


def test_editing_inside_the_substituted_span_is_edited_after(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "they", 0, 3, 4, 900, 0, 0),
        (2000, "delete", "y", "", 3, 1, 3, 1100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "edited_after"
    assert rows[1]["revert_latency_ms"] == "1100.000"


def test_deleted_paste_over_nothing_is_reverted_to_original(tmp_path):
    # A paste with empty replaced_text that the user deletes again restored
    # the original (nothing): region == original must win over the empty
    # test, or this would come out deleted_entirely.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "x ", 0, 0, 2, 0, 0, 0),
        (900, "paste", "", "hi", 2, 0, 4, 900, 0, 0),
        (2000, "delete", "", "", 3, 1, 3, 1100, 0, 0),
        (2100, "delete", "", "", 2, 1, 2, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "reverted_to_original"


def test_deleting_without_retyping_is_deleted_entirely(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 1200, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "deleted_entirely"


def test_episode_final_captured_when_settled_mid_replay(tmp_path):
    # The Jimmy_test_Tran row-167 shape: select `day`, overtype `d`, rebuild
    # `day`, delete it all, type `say`, then edit elsewhere (settles the
    # region). A preceding word keeps the elsewhere-edit outside [lo, hi).
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "hi ", 0, 0, 3, 0, 0, 0),
        (500, "insert", "", "day", 3, 0, 6, 500, 0, 0),
        (1000, "replace", "day", "d", 3, 3, 4, 500, 3, 0),
        (1200, "insert", "", "a", 4, 0, 5, 200, 0, 0),
        (1400, "insert", "", "y", 5, 0, 6, 200, 0, 0),
        (2000, "delete", "", "", 5, 1, 5, 600, 0, 0),
        (2200, "delete", "", "", 4, 1, 4, 200, 0, 0),
        (2400, "delete", "", "", 3, 1, 3, 200, 0, 0),
        (2600, "insert", "", "s", 3, 0, 4, 200, 0, 0),
        (2800, "insert", "", "a", 4, 0, 5, 200, 0, 0),
        (3000, "insert", "", "y", 5, 0, 6, 200, 0, 0),
        (4000, "insert", "", "x", 0, 0, 7, 1000, 0, 0),
    ])
    rows = classified(session)
    assert rows[2]["substitution_outcome"] == "replaced_with_other"
    assert rows[2]["episode_final"] == "say"
    assert rows[2]["episode_final_trusted"] == "1"


def test_episode_final_captured_at_clean_session_end(tmp_path):
    # Same shape as the replaced_with_other test above: the region settles at
    # finalize with a sound buffer, so its content is still trustworthy.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 1200, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "t", 0, 0, 1, 100, 0, 0),
        (2500, "insert", "", "e", 1, 0, 2, 100, 0, 0),
        (2600, "insert", "", "a", 2, 0, 3, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "replaced_with_other"
    assert rows[1]["episode_final"] == "tea"
    assert rows[1]["episode_final_trusted"] == "1"


def test_trailing_burst_settles_at_the_foreign_delimiter(tmp_path):
    # Retype the original and keep typing contiguously. Appending a delimiter
    # the pair never had ends the episode there (ADR 0005), so the region is
    # `teh`, not `teh is fine` - and the outcome is the revert it really was.
    rows = [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (905, "insert", "", " ", 3, 0, 4, 5, 0, 0),
        (2000, "delete", "", "", 3, 1, 3, 1095, 0, 0),
        (2100, "delete", "", "", 2, 1, 2, 100, 0, 0),
        (2200, "delete", "", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "", "", 0, 1, 0, 100, 0, 0),
    ]
    for offset, char in enumerate("teh is fine"):
        rows.append((2400 + offset * 100, "insert", "", char, offset, 0, offset + 1, 100, 0, 0))
    session = write_keystrokes_csv(tmp_path, rows)
    labelled = classified(session)
    assert labelled[1]["substitution_outcome"] == "reverted_to_original"
    assert labelled[1]["episode_final"] == "teh"
    assert labelled[1]["episode_final_trusted"] == "1"


def test_autocorrect_refire_ends_the_first_episode_at_the_retype(tmp_path):
    # The fight: teh -> the, delete, retype teh, space -> autocorrect fires
    # again. The second replace lands inside the first episode's region; the
    # first episode settles as it stood (`teh` == original) instead of
    # absorbing the second substitution's output.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (905, "insert", "", " ", 3, 0, 4, 5, 0, 0),
        (2000, "delete", "", "", 3, 1, 3, 1095, 0, 0),
        (2100, "delete", "", "", 2, 1, 2, 100, 0, 0),
        (2200, "delete", "", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "t", 0, 0, 1, 100, 0, 0),
        (2500, "insert", "", "e", 1, 0, 2, 100, 0, 0),
        (2600, "insert", "", "h", 2, 0, 3, 100, 0, 0),
        (3500, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (3505, "insert", "", " ", 3, 0, 4, 5, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "reverted_to_original"
    assert rows[1]["episode_final"] == "teh"
    assert rows[1]["episode_final_trusted"] == "1"
    assert rows[10]["substitution_outcome"] == "kept"


def test_interrupted_revert_survives_an_edit_elsewhere(tmp_path):
    # Delete the corrected word, fix a typo earlier in the text, come back
    # and retype the original. The elsewhere edits must not settle the empty
    # region as "left nothing" - it shifts with the edits and stays alive.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "xy ", 0, 0, 3, 0, 0, 0),
        (500, "insert", "", "teh", 3, 0, 6, 500, 0, 0),
        (1400, "replace", "teh", "the", 3, 3, 6, 900, 0, 0),
        (2000, "delete", "", "", 5, 1, 5, 600, 0, 0),
        (2100, "delete", "", "", 4, 1, 4, 100, 0, 0),
        (2200, "delete", "", "", 3, 1, 3, 100, 0, 0),
        (3000, "delete", "", "", 1, 1, 2, 800, 0, 0),     # fix xy -> xz
        (3200, "insert", "", "z", 1, 0, 3, 200, 0, 0),
        (4000, "insert", "", "t", 3, 0, 4, 800, 0, 0),    # back: retype teh
        (4100, "insert", "", "e", 4, 0, 5, 100, 0, 0),
        (4200, "insert", "", "h", 5, 0, 6, 100, 0, 0),
    ])
    rows = classified(session)
    assert rows[2]["substitution_outcome"] == "reverted_to_original"
    assert rows[2]["episode_final"] == "teh"
    assert rows[2]["episode_final_trusted"] == "1"


def test_delimiter_from_the_pair_itself_stays_trusted(tmp_path):
    # `alot -> a lot` reverted to exactly `a lot`: the space is in the pair,
    # so a bare contains-a-delimiter rule would falsely suppress it.
    rows = [
        (0, "insert", "", "alot", 0, 0, 4, 0, 0, 0),
        (900, "replace", "alot", "a lot", 0, 4, 5, 900, 0, 0),
    ]
    t = 2000
    for n in range(5):
        rows.append((t, "delete", "", "", 4 - n, 1, 4 - n, 100, 0, 0))
        t += 100
    for offset, char in enumerate("a lot"):
        rows.append((t, "insert", "", char, offset, 0, offset + 1, 100, 0, 0))
        t += 100
    session = write_keystrokes_csv(tmp_path, rows)
    labelled = classified(session)
    assert labelled[1]["substitution_outcome"] == "replaced_with_other"
    assert labelled[1]["episode_final"] == "a lot"
    assert labelled[1]["episode_final_trusted"] == "1"


def test_kept_and_edited_after_have_no_episode_final(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),   # kept
        (1000, "insert", "", " ", 3, 0, 4, 100, 0, 0),
        (1100, "insert", "", "teh", 4, 0, 7, 100, 0, 0),
        (1900, "replace", "teh", "they", 4, 3, 8, 800, 0, 0),  # edited_after
        (3000, "delete", "y", "", 7, 1, 7, 1100, 0, 0),
    ])
    rows = classified(session)
    assert rows[1]["substitution_outcome"] == "kept"
    assert rows[1]["episode_final"] == ""
    assert rows[1]["episode_final_trusted"] == ""
    assert rows[4]["substitution_outcome"] == "edited_after"
    assert rows[4]["episode_final"] == ""
    assert rows[4]["episode_final_trusted"] == ""


def test_region_settled_at_divergence_drops_its_final_string(tmp_path, capsys):
    # Collapse and retype, then a row whose range_start is beyond the replayed
    # text: partial finalize. The outcome survives; the region string would
    # quote a buffer known to be out of sync, so it is dropped.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 1200, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "tea", 0, 0, 3, 100, 0, 0),
        (2500, "insert", "", "x", 9, 0, 10, 100, 0, 0),      # diverges
    ])
    rows = classified(session)
    assert "diverged" in capsys.readouterr().err
    assert rows[1]["substitution_outcome"] == "replaced_with_other"
    assert rows[1]["episode_final"] == ""
    assert rows[1]["episode_final_trusted"] == ""


def test_inconsistent_edit_script_leaves_outcomes_empty(tmp_path, capsys):
    # range_start beyond the replayed text: replay diverged, outcomes must not
    # be guessed. Source and effect are unaffected.
    session = write_keystrokes_csv(tmp_path, [
        (900, "replace", "teh", "the", 5, 3, 3, 900, 0, 0),
    ])
    rows = classified(session)
    assert rows[0]["substitution_source"] == "autocorrect_engine"
    assert rows[0]["substitution_outcome"] == ""
    assert "diverged" in capsys.readouterr().err


def test_summary_counts_each_axis(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "cat", 0, 0, 3, 0, 0, 0),
        (500, "replace", "cat", "dog", 0, 3, 3, 500, 3, 0),
        (600, "insert", "", "teh", 3, 0, 6, 100, 0, 0),
        (900, "replace", "teh", "the", 3, 3, 6, 300, 0, 0),
        (920, "insert", "", " ", 6, 0, 7, 20, 0, 0),
    ])
    summary, _, _ = sm.summarize(session)
    assert summary["keystroke_rows"] == 5
    assert summary["substitution_rows"] == 2
    assert summary["source_manual_overtype"] == 1
    assert summary["source_autocorrect_engine"] == 1
    assert summary["effect_spelling"] == 2
    assert summary["outcome_kept"] == 2
    assert summary["grey_zone_rows"] == 0


def test_ac_on_session_with_zero_autocorrect_rows_warns(tmp_path, capsys):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
    ], name="Alex,1,left,ac_on")
    sm.main([str(session), "--out-dir", str(tmp_path / "out")])
    assert "tagged autocorrect-on" in capsys.readouterr().out


def test_ac_off_session_with_autocorrect_rows_warns(tmp_path, capsys):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ], name="Alex,1,left,ac_off")
    sm.main([str(session), "--out-dir", str(tmp_path / "out")])
    assert "tagged autocorrect-off" in capsys.readouterr().out


def test_each_session_gets_its_own_summary_file(tmp_path):
    # A new trial must never overwrite an earlier session's outputs, so all
    # artifacts sit in a folder named after that session.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ])
    out_dir = tmp_path / "out"
    sm.main([str(session), "--out-dir", str(out_dir)])
    session_dir = out_dir / "Alex,1,left,ac_on"
    summary_file = session_dir / "Alex,1,left,ac_on_summary.md"
    assert (session_dir / "Alex,1,left,ac_on_processed.csv").is_file()
    assert summary_file.is_file()
    text = summary_file.read_text(encoding="utf-8")
    assert "# Alex,1,left,ac_on — substitution summary" in text
    assert "- autocorrect: 1" in text
    assert "  - spelling: 1" in text
    assert "  - outcome: kept: 1" in text
    assert "## calibration" in text


def test_episode_section_pairs_the_three_axes(tmp_path):
    # Per-axis tallies cannot be re-paired: 2 effects + 2 outcomes alone
    # cannot say which effect was reverted. The episodes section can.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "i", 0, 0, 1, 0, 0, 0),
        (500, "replace", "i", "I", 0, 1, 1, 500, 0, 0),        # caps, kept
        (600, "insert", "", " teh", 1, 0, 5, 100, 0, 0),
        (1500, "replace", "teh", "the", 2, 3, 5, 900, 0, 0),   # spelling, reverted
        (2100, "delete", "e", "", 4, 1, 4, 600, 0, 0),
        (2200, "delete", "h", "", 3, 1, 3, 100, 0, 0),
        (2300, "delete", "t", "", 2, 1, 2, 100, 0, 0),
    ])
    out_dir = tmp_path / "out"
    joint = tmp_path / "joint.csv"
    sm.main([str(session), "--out-dir", str(out_dir), "--joint-out", str(joint)])
    text = (out_dir / "Alex,1,left,ac_on" / "Alex,1,left,ac_on_summary.md").read_text(encoding="utf-8")
    assert "## episodes" in text
    assert "- autocorrect · capitalization · kept: 1" in text
    assert "- autocorrect · spelling · deleted_entirely: 1" in text
    with joint.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert {
        "session_dir": "Alex,1,left,ac_on", "source": "autocorrect_engine",
        "effect": "spelling", "outcome": "deleted_entirely", "count": "1",
    } in rows
    assert len(rows) == 2


def test_episode_lines_quote_observed_strings(tmp_path):
    # kept quotes the raw pair; reverted quotes the replayed end state;
    # an untrusted region prints nothing - the count stands alone.
    rows = [
        (0, "insert", "", "i", 0, 0, 1, 0, 0, 0),
        (500, "replace", "i", "I", 0, 1, 1, 500, 0, 0),         # kept
        (600, "insert", "", " teh", 1, 0, 5, 100, 0, 0),
        (1500, "replace", "teh", "the", 2, 3, 5, 900, 0, 0),    # reverted -> tea
        (2100, "delete", "e", "", 4, 1, 4, 600, 0, 0),
        (2200, "delete", "h", "", 3, 1, 3, 100, 0, 0),
        (2300, "delete", "t", "", 2, 1, 2, 100, 0, 0),
        (2400, "insert", "", "t", 2, 0, 3, 100, 0, 0),
        (2500, "insert", "", "e", 3, 0, 4, 100, 0, 0),
        (2600, "insert", "", "a", 4, 0, 5, 100, 0, 0),
    ]
    session = write_keystrokes_csv(tmp_path, rows)
    out_dir = tmp_path / "out"
    sm.main([str(session), "--out-dir", str(out_dir)])
    text = (out_dir / "Alex,1,left,ac_on" / "Alex,1,left,ac_on_summary.md").read_text(encoding="utf-8")
    assert "- autocorrect · capitalization · kept: 1" in text
    assert "    i → I" in text
    assert "- autocorrect · spelling · replaced_with_other: 1" in text
    assert "    teh → tea" in text


def test_untrusted_region_prints_count_only(tmp_path):
    # A foreign delimiter typed *inside* the region is absorbed (only appends
    # at hi settle), so the region still carries it - untrusted, and the
    # joint line appears with no string under it.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (2100, "delete", "e", "", 2, 1, 2, 1200, 0, 0),
        (2200, "delete", "h", "", 1, 1, 1, 100, 0, 0),
        (2300, "delete", "t", "", 0, 1, 0, 100, 0, 0),
        (2400, "insert", "", "t", 0, 0, 1, 100, 0, 0),
        (2500, "insert", "", "e", 1, 0, 2, 100, 0, 0),
        (2600, "insert", "", "a", 2, 0, 3, 100, 0, 0),
        (2700, "insert", "", ".", 1, 0, 4, 100, 0, 0),   # inside the region
    ])
    out_dir = tmp_path / "out"
    sm.main([str(session), "--out-dir", str(out_dir)])
    text = (out_dir / "Alex,1,left,ac_on" / "Alex,1,left,ac_on_summary.md").read_text(encoding="utf-8")
    assert "- autocorrect · spelling · replaced_with_other: 1" in text
    assert "t.ea" not in text


def test_repeated_pairs_dedupe_with_a_multiplier(tmp_path):
    rows = []
    position = 0
    for n in range(3):
        t = n * 2000
        rows.append((t, "insert", "", "i", position, 0, position + 1, 100, 0, 0))
        rows.append((t + 500, "replace", "i", "I", position, 1, position + 1, 500, 0, 0))
        rows.append((t + 600, "insert", "", " ", position + 1, 0, position + 2, 100, 0, 0))
        position += 2
    session = write_keystrokes_csv(tmp_path, rows)
    out_dir = tmp_path / "out"
    sm.main([str(session), "--out-dir", str(out_dir)])
    text = (out_dir / "Alex,1,left,ac_on" / "Alex,1,left,ac_on_summary.md").read_text(encoding="utf-8")
    assert "- autocorrect · capitalization · kept: 3" in text
    assert "    i → I  (×3)" in text


def test_summary_definitions_live_in_one_glossary_block(tmp_path):
    # A definition printed inline next to a count reads as observed data (the
    # hardcoded "coler -> cooler" illustration was taken for a session finding
    # in review). Data lines carry counts only; all definitions live in one
    # <details> glossary at the end.
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ])
    out_dir = tmp_path / "out"
    sm.main([str(session), "--out-dir", str(out_dir)])
    text = (out_dir / "Alex,1,left,ac_on" / "Alex,1,left,ac_on_summary.md").read_text(encoding="utf-8")
    assert text.count("<details><summary>label definitions</summary>") == 1
    body = text.split("<details>")[0]
    assert " — *" not in body            # no definition on any data line
    assert "coler" not in body           # the illustration that caused the bug
    glossary = text.split("<details>")[1]
    for definition in list(sm.SOURCE_DEFS) + list(sm.EFFECT_DEFS) + list(sm.OUTCOME_DEFS):
        assert definition in glossary


def test_session_dir_accepted_as_well_as_file(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "a", 0, 0, 1, 0, 0, 0),
    ])
    from_dir, _, _ = sm.summarize(session)
    from_file, _, _ = sm.summarize(session / "keystrokes.csv")
    assert from_dir == from_file


def test_labeled_output_keeps_original_columns_and_adds_labels(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ])
    out = tmp_path / "summary.csv"
    labeled = tmp_path / "labeled.csv"
    sm.main([
        str(session), "--out-dir", str(tmp_path / "out"),
        "--out", str(out), "--labeled-out", str(labeled),
    ])
    with labeled.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    for column in HEADER + sm.LABEL_COLUMNS:
        assert column in rows[0]
    assert rows[1]["substitution_kind"] == "autocorrect"


# --- per-session gap calibration -------------------------------------------

def sub_pair(t, old, new, gap, iki=100):
    """A substitution row followed by its trailing delimiter at `gap` ms."""
    return [
        (t, "replace", old, new, 0, len(old), len(new), iki, 0, 0),
        (t + gap, "insert", "", " ", len(new), 0, len(new) + 1, gap, 0, 0),
    ]


def calibration_of(session):
    _, calibration = sm.classify_rows(session / "keystrokes.csv")
    return calibration


def test_two_sided_anchors_calibrate_the_threshold(tmp_path):
    rows = []
    rows += sub_pair(1000, "teh", "the", 4.0)        # low anchor (spelling, iki 100)
    rows += sub_pair(2000, "wrnt", "went", 5.0)      # low anchor
    rows += sub_pair(3000, "i", "I", 12.0)           # high anchor (capitalization)
    rows += sub_pair(4000, "its", "it's", 14.0)      # high anchor (contraction)
    rows += sub_pair(5000, "tomo", "tomorrow", 13.0) # completion: above threshold
    rows += sub_pair(6000, "rea", "reading", 4.5)    # completion: below threshold
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["mode"] == "anchored"
    assert calibration["grey_lo"] == 5.0 and calibration["grey_hi"] == 12.0
    assert abs(calibration["threshold"] - (5.0 * 12.0) ** 0.5) < 1e-9
    labelled = classified(session)
    subs = [r for r in labelled if r["substitution_source"]]
    assert subs[4]["substitution_source"] == "suggestion_bar"
    assert subs[4]["substitution_source_confidence"] == "inferred"  # 13 > grey_hi 12
    assert subs[5]["substitution_source"] == "autocorrect_engine"


def test_bar_tap_spelling_fix_is_not_a_low_anchor(tmp_path):
    # Same string shape as an autocorrect, but the 600 ms preceding interval
    # means the thumb had time to reach the bar - excluded from anchors.
    rows = []
    rows += sub_pair(1000, "teh", "the", 13.0, iki=600)
    rows += sub_pair(2000, "i", "I", 12.0)
    rows += sub_pair(3000, "its", "it's", 14.0)
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["low_anchors"] == 0
    assert calibration["mode"] == "anchored_high"


def test_single_cluster_session_does_not_split_itself(tmp_path):
    # All-low session (careful typist, no bar taps): a naive band-splitter
    # would cut the one cluster in half. Anchored-low keeps everything low.
    rows = []
    rows += sub_pair(1000, "teh", "the", 5.0)
    rows += sub_pair(2000, "wrnt", "went", 5.5)
    rows += sub_pair(3000, "tomo", "tomorrow", 6.0)   # completion inside cluster
    rows += sub_pair(4000, "rea", "reading", 13.0)    # genuine bar tap still splits out
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["mode"] == "anchored_low"
    assert calibration["threshold"] == 5.5 * sm.MIN_SEPARATION_RATIO
    labelled = classified(session)
    subs = [r for r in labelled if r["substitution_source"]]
    assert subs[2]["substitution_source"] == "autocorrect_engine"
    assert subs[3]["substitution_source"] == "suggestion_bar"


def test_conflicting_anchors_fall_back_flagged(tmp_path):
    rows = []
    rows += sub_pair(1000, "teh", "the", 12.0)   # low anchors sitting high
    rows += sub_pair(2000, "wrnt", "went", 13.0)
    rows += sub_pair(3000, "i", "I", 5.0)        # high anchors sitting low
    rows += sub_pair(4000, "its", "it's", 6.0)
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["mode"] == "global_conflict"
    assert calibration["threshold"] == sm.DELIMITER_GAP_SPLIT_MS


def test_otsu_splits_anchorless_bimodal_session(tmp_path):
    gaps = [4.0, 4.5, 5.0, 5.5, 6.0, 12.0, 13.0, 14.0, 15.0]
    rows = []
    for n, gap in enumerate(gaps):
        rows += sub_pair(1000 * (n + 1), "tomo", "tomorrow", gap)  # all completions
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["mode"] == "otsu"
    assert calibration["grey_lo"] == 6.0 and calibration["grey_hi"] == 12.0


def test_otsu_rejects_unimodal_session(tmp_path):
    gaps = [4.0, 4.3, 4.6, 4.9, 5.2, 5.5, 5.8, 6.1]
    rows = []
    for n, gap in enumerate(gaps):
        rows += sub_pair(1000 * (n + 1), "tomo", "tomorrow", gap)
    session = write_keystrokes_csv(tmp_path, rows)
    calibration = calibration_of(session)
    assert calibration["mode"] == "global"


def test_summary_records_calibration(tmp_path):
    session = write_keystrokes_csv(tmp_path, [
        (0, "insert", "", "teh", 0, 0, 3, 0, 0, 0),
        (900, "replace", "teh", "the", 0, 3, 3, 900, 0, 0),
        (920, "insert", "", " ", 3, 0, 4, 20, 0, 0),
    ])
    summary, _, _ = sm.summarize(session)
    assert summary["gap_calibration"] == "global"
    assert summary["gap_threshold_ms"] == "9.000"
    assert summary["gap_low_anchors"] == 0
