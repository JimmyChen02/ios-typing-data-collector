import XCTest

final class CursorSampleTests: XCTestCase {
    private func sample(
        selStart: Int = 12,
        prevSelStart: Int = 18,
        caretX: Double? = 97.5,
        touchX: Double? = 101.2,
        phase: String? = "began"
    ) -> CursorSample {
        CursorSample(
            selStart: selStart, selLength: 0,
            prevSelStart: prevSelStart, prevSelLength: 0,
            caretX: caretX, caretY: 8.0, caretH: 20.5,
            touchX: touchX, touchY: 15.9, touchPhase: phase, touchAgeMs: 11.4,
            afterTextChange: false, programmatic: false, textLength: 18
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
        let row = fields(sample(caretX: nil, touchX: nil, phase: nil).csvRow(tMs: 0))
        let h = header()
        XCTAssertEqual(row[h.firstIndex(of: "caret_x")!], "")
        XCTAssertEqual(row[h.firstIndex(of: "touch_x")!], "")
        XCTAssertEqual(row[h.firstIndex(of: "touch_phase")!], "")
    }

    func test_flagsAreWrittenAsZeroOrOne() {
        let s = CursorSample(
            selStart: 5, selLength: 0, prevSelStart: 4, prevSelLength: 0,
            caretX: nil, caretY: nil, caretH: nil,
            touchX: nil, touchY: nil, touchPhase: nil, touchAgeMs: nil,
            afterTextChange: true, programmatic: false, textLength: 5
        )
        let row = fields(s.csvRow(tMs: 0))
        let h = header()
        XCTAssertEqual(row[h.firstIndex(of: "after_text_change")!], "1")
        XCTAssertEqual(row[h.firstIndex(of: "programmatic")!], "0")
    }

    func test_selectionLengthIsPreservedForSelections() {
        let s = CursorSample(
            selStart: 10, selLength: 4, prevSelStart: 18, prevSelLength: 0,
            caretX: nil, caretY: nil, caretH: nil,
            touchX: nil, touchY: nil, touchPhase: nil, touchAgeMs: nil,
            afterTextChange: false, programmatic: false, textLength: 18
        )
        let row = fields(s.csvRow(tMs: 0))
        let h = header()
        XCTAssertEqual(row[h.firstIndex(of: "sel_length")!], "4")
        XCTAssertEqual(row[h.firstIndex(of: "delta_chars")!], "-8")
    }
}
