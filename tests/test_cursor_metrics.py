import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import cursor_metrics as cm


HEADER = [
    "t_ms", "sel_start", "sel_length", "prev_sel_start", "prev_sel_length",
    "delta_chars", "caret_x", "caret_y", "caret_h", "touch_x", "touch_y",
    "touch_phase", "tap_count", "touch_age_ms", "ms_since_last_text_change",
    "text_length",
]


def write_cursor_csv(tmp_path):
    session = tmp_path / "Alex-1"
    session.mkdir()
    path = session / "cursor.csv"
    rows = [
        (0, 0, 0, 0, 0, 0, "", "", "", "", "", "", "", "", "", 4),
        (10, 4, 0, 0, 0, 4, "", "", "", "", "", "", "", "", 10, 4),
        (200, 0, 4, 4, 0, -4, 10, 20, 18, 12, 20, "began", 2, 8, 1000, 4),
        (300, 1, 0, 0, 4, 1, 12, 20, 18, 12, 20, "began", 1, 5, 1100, 4),
        (350, 2, 0, 1, 0, 1, 13, 20, 18, 13, 20, "moved", 1, 20, 1150, 4),
        (500, 0, 0, 2, 0, -2, "", "", "", "", "", "ended", 1, 500, 1300, 4),
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(HEADER)
        writer.writerows(rows)
    return path


def test_summarize_classifies_all_cursor_causes(tmp_path):
    path = write_cursor_csv(tmp_path)
    summary, rows = cm.summarize(path)
    assert summary == {
        "cursor_rows": 6,
        "selection_rows": 1,
        "double_tap_selection_rows": 1,
        "tap_reposition_rows": 1,
        "drag_rows": 1,
        "keyboard_gesture_rows": 1,
        "typing_rows": 1,
        "other_rows": 1,
        "session_dir": "Alex-1",
    }
    assert [row["cause"] for row in rows] == [
        "other", "typing", "double_tap_selection", "tap_reposition", "drag",
        "keyboard_gesture",
    ]


def test_main_accepts_cursor_csv_and_writes_outputs(tmp_path):
    path = write_cursor_csv(tmp_path)
    summary_path = tmp_path / "cursor_summary.csv"
    events_path = tmp_path / "cursor_events.csv"
    assert cm.main([
        str(path), "--out", str(summary_path), "--events-out", str(events_path)
    ]) == 0
    summary_rows = list(csv.DictReader(summary_path.open(encoding="utf-8")))
    event_rows = list(csv.DictReader(events_path.open(encoding="utf-8")))
    assert summary_rows[0]["double_tap_selection_rows"] == "1"
    assert event_rows[2]["cause"] == "double_tap_selection"


def test_missing_cursor_columns_are_rejected(tmp_path):
    path = tmp_path / "cursor.csv"
    path.write_text("t_ms,sel_length\n0,0\n", encoding="utf-8")
    try:
        cm.summarize(path)
    except ValueError as error:
        assert "missing columns" in str(error)
    else:
        raise AssertionError("expected invalid cursor schema to fail")
