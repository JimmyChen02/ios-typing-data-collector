import XCTest

final class CursorSampleTests: XCTestCase {
    private func sample(
        selStart: Int = 12,
        prevSelStart: Int = 18,
        caretX: Double? = 97.5,
        touchX: Double? = 101.2,
        phase: String? = "began",
        tapCount: Int? = 1
    ) -> CursorSample {
        CursorSample(
            selStart: selStart, selLength: 0,
            prevSelStart: prevSelStart, prevSelLength: 0,
            caretX: caretX, caretY: 8.0, caretH: 20.5,
            touchX: touchX, touchY: 15.9, touchPhase: phase, tapCount: tapCount,
            touchAgeMs: 11.4,
            msSinceLastTextChange: nil, textLength: 18
        )
    }

    private func header() -> [String] {
        CursorSample.csvHeader.split(separator: ",").map(String.init)
    }

    private func fields(_ row: String) -> [String] {
        row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    func test_rowFieldCountMatchesHeader() {
        XCTAssertEqual(fields(sample().csvRow(tMs: 8420.5)).count, header().count)
    }

    func test_headerIsASingleLine() {
        XCTAssertFalse(CursorSample.csvHeader.contains("\n"))
    }

    func test_deltaCharsIsNegativeWhenCaretMovesBackward() {
        XCTAssertEqual(sample(selStart: 12, prevSelStart: 18).deltaChars, -6)
    }

    func test_deltaCharsIsPositiveWhenCaretAdvances() {
        XCTAssertEqual(sample(selStart: 13, prevSelStart: 12).deltaChars, 1)
    }

    func test_deltaCharsColumnCarriesTheSignedJump() {
        let row = fields(sample(selStart: 12, prevSelStart: 18).csvRow(tMs: 0))
        XCTAssertEqual(row[header().firstIndex(of: "delta_chars")!], "-6")
    }

    func test_missingGeometryBecomesEmptyFieldsNotZero() {
        let row = fields(sample(
            caretX: nil, touchX: nil, phase: nil, tapCount: nil
        ).csvRow(tMs: 0))
        let h = header()
        XCTAssertEqual(row[h.firstIndex(of: "caret_x")!], "")
        XCTAssertEqual(row[h.firstIndex(of: "touch_x")!], "")
        XCTAssertEqual(row[h.firstIndex(of: "touch_phase")!], "")
        XCTAssertEqual(row[h.firstIndex(of: "tap_count")!], "")
    }

    func test_msSinceLastTextChangeIsWrittenWhenPresent() {
        let s = CursorSample(
            selStart: 5, selLength: 0, prevSelStart: 4, prevSelLength: 0,
            caretX: nil, caretY: nil, caretH: nil,
            touchX: nil, touchY: nil, touchPhase: nil, tapCount: nil,
            touchAgeMs: nil,
            msSinceLastTextChange: 12.5, textLength: 5
        )
        let row = fields(s.csvRow(tMs: 0))
        XCTAssertEqual(row[header().firstIndex(of: "ms_since_last_text_change")!], "12.500")
    }

    func test_msSinceLastTextChangeIsEmptyWhenNoEditHasHappened() {
        let row = fields(sample().csvRow(tMs: 0))
        XCTAssertEqual(row[header().firstIndex(of: "ms_since_last_text_change")!], "",
                       "absent must be empty, not 0 - 0 would mean an edit just happened")
    }

    func test_selectionLengthIsPreservedForSelections() {
        let s = CursorSample(
            selStart: 10, selLength: 4, prevSelStart: 18, prevSelLength: 0,
            caretX: nil, caretY: nil, caretH: nil,
            touchX: nil, touchY: nil, touchPhase: nil, tapCount: nil,
            touchAgeMs: nil,
            msSinceLastTextChange: nil, textLength: 18
        )
        let row = fields(s.csvRow(tMs: 0))
        let h = header()
        XCTAssertEqual(row[h.firstIndex(of: "sel_length")!], "4")
        XCTAssertEqual(row[h.firstIndex(of: "delta_chars")!], "-8")
    }

    func test_doubleTapCountIsWritten() {
        let s = CursorSample(
            selStart: 10, selLength: 4, prevSelStart: 10, prevSelLength: 0,
            caretX: nil, caretY: nil, caretH: nil,
            touchX: 20, touchY: 30, touchPhase: "began", tapCount: 2,
            touchAgeMs: 8, msSinceLastTextChange: nil, textLength: 18
        )
        let row = fields(s.csvRow(tMs: 0))
        XCTAssertEqual(row[header().firstIndex(of: "tap_count")!], "2")
    }
}
