import csv
import sys
from collections import Counter
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import prefix_error_metrics as pem


HEADER = [
    "t_ms", "event_type", "replaced_text", "replacement_text",
    "range_start", "range_length", "resulting_text_length",
    "inter_key_interval_ms",
]


def test_replay_retains_unlogged_prediction_as_unknown():
    rows = [
        dict(zip(HEADER, [0, "insert", "", "t", 0, 0, 1, 0])),
        dict(zip(HEADER, [1, "insert", "", "h", 1, 0, 2, 1])),
        dict(zip(HEADER, [2, "insert", "", "e", 2, 0, 4, 1])),
    ]
    snapshots, final = pem.replay_rows(rows)
    assert pem._stable_text(snapshots[-1]) == "the"
    assert final.count(pem.UNKNOWN_UNIT) == 1


def test_uncommitted_trailing_word_is_censored():
    text, dropped = pem.committed_reference_text("I went to the sto")
    assert text == "I went to the"
    assert dropped == "sto"
    assert pem.committed_words("I went to the sto") == ["i", "went", "to", "the"]


def test_committed_word_is_kept_after_space_or_punctuation():
    assert pem.committed_words("I went home ") == ["i", "went", "home"]
    assert pem.committed_words("I went home.") == ["i", "went", "home"]


def test_conservative_spell_checker_accepts_only_strong_local_evidence():
    checker = pem.ConservativeSpellChecker(
        {"the", "ten", "tea", "store", "storm"},
        Counter({"the": 12, "ten": 1}),
    )
    replacement, status, _, _ = checker.decide("teh")
    assert replacement == "the"
    assert status == "accepted_corpus"

    replacement, status, _, _ = checker.decide("storw")
    assert replacement == "storw"
    assert status == "suggested"


def test_spell_checker_preserves_names_acronyms_and_grammar_without_evidence():
    checker = pem.ConservativeSpellChecker({"train", "buyer"}, Counter())
    assert checker.decide("Tran")[1] == "preserved"
    assert checker.decide("CSV")[1] in {"unchanged", "preserved"}
    assert checker.decide("buyed")[1] in {"suggested", "preserved"}


def test_spell_checker_preserves_valid_inflections():
    checker = pem.ConservativeSpellChecker(
        {"movie", "place", "buy", "create", "start", "love"},
        Counter({"movie": 10, "place": 10, "buy": 10, "create": 10}),
    )
    assert checker.decide("movies")[:2] == ("movies", "preserved")
    assert checker.decide("places")[:2] == ("places", "preserved")
    assert checker.decide("buying")[:2] == ("buying", "preserved")
    assert checker.decide("creating")[:2] == ("creating", "preserved")
    assert checker.decide("started")[:2] == ("started", "preserved")
    assert checker.decide("loved")[:2] == ("loved", "preserved")


def test_word_error_example_scores_one_substitution():
    result = pem._score_snapshot(
        "I went to teh ",
        ["i", "went", "to", "the", "store"],
        "raw",
    )
    assert result["raw_reference_prefix"] == "i went to the"
    assert result["raw_wer_substitutions"] == 1
    assert result["raw_wer"] == 0.25


def test_future_words_are_not_counted_as_deletions():
    result = pem._score_snapshot(
        "I went ",
        ["i", "went", "to", "the", "store"],
        "raw",
    )
    assert result["raw_reference_prefix"] == "i went"
    assert result["raw_wer_errors"] == 0
    assert result["raw_wer"] == 0


def test_active_cer_scores_unfinished_word_without_future_deletions():
    correct = pem._score_active_snapshot(
        "I went to th",
        "I went to the store",
        "raw_active",
    )
    assert correct["raw_active_reference_prefix"] == "i went to th"
    assert correct["raw_active_cer"] == 0
    assert correct["raw_active_wer"] == 0

    mistyped = pem._score_active_snapshot(
        "I went to tg",
        "I went to the store",
        "raw_active",
    )
    assert mistyped["raw_active_cer_substitutions"] == 1
    assert mistyped["raw_active_cer_errors"] == 1
    assert mistyped["raw_active_wer_substitutions"] == 1
    assert mistyped["raw_active_wer"] == 0.25


def test_active_cer_retains_punctuation_and_can_censor_unfinished_final_suffix():
    punctuation = pem._score_active_snapshot("Hi,", "Hi.", "raw_active")
    assert punctuation["raw_active_cer_substitutions"] == 1

    censored = pem._score_active_snapshot(
        "I went gla",
        "I went",
        "raw_active",
        censor_suffix_beyond_reference=True,
    )
    assert censored["raw_active_current_text"] == "i went"
    assert censored["raw_active_cer"] == 0

    trailing_space = pem._score_active_snapshot("I went ", "I went", "raw_active")
    assert trailing_space["raw_active_cer"] == 0


def test_session_identity_is_inferred_from_export_folder_name():
    assert pem._infer_session_identity("Jimmy C,10,left") == (10, "left")
    assert pem._infer_session_identity("Jimmy C,1,both_222910") == (1, "both")


def test_explicit_correction_map_is_unconditional(tmp_path):
    path = tmp_path / "corrections.csv"
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["original", "replacement"])
        writer.writerow(["storw", "store"])
    mapping = pem._load_explicit_corrections(str(path))
    checker = pem.ConservativeSpellChecker({"store"}, Counter(), explicit=mapping)
    assert checker.decide("storw")[:2] == ("store", "accepted_explicit")


def test_markdown_summary_reports_weighted_active_metrics(tmp_path):
    summaries = [
        {
            "session": "one",
            "hand": "left",
            "event_rows": 2,
            "active_scored_timestamps": 2,
            "active_divergent_timestamps": 1,
            "introduced_error_events": 1,
            "introduced_error_units": 1,
            "corrected_error_events": 1,
            "corrected_error_units": 1,
            "mean_raw_active_cer": 0.5,
            "mean_raw_active_wer": 0.25,
        },
        {
            "session": "two",
            "hand": "right",
            "event_rows": 6,
            "active_scored_timestamps": 6,
            "active_divergent_timestamps": 0,
            "introduced_error_events": 0,
            "introduced_error_units": 0,
            "corrected_error_events": 0,
            "corrected_error_units": 0,
            "mean_raw_active_cer": 0,
            "mean_raw_active_wer": 0,
        },
    ]
    path = tmp_path / "metrics_summary.md"
    pem._write_markdown_summary(path, summaries, [{"status": "suggested"}])
    report = path.read_text(encoding="utf-8")
    assert "Event-weighted active CER: **12.5000%**" in report
    assert "Event-weighted active WER: **6.2500%**" in report
    assert "| one | left | 2 | 1 | 1 | 50.0000% | 25.0000% |" in report
