import XCTest

@MainActor
final class CursorLoggerTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
    }

    private func sample(selStart: Int, prevSelStart: Int) -> CursorSample {
        CursorSample(
            selStart: selStart, selLength: 0,
            prevSelStart: prevSelStart, prevSelLength: 0,
            caretX: 10, caretY: 8, caretH: 20,
            touchX: nil, touchY: nil, touchPhase: nil, touchAgeMs: nil,
            msSinceLastTextChange: nil, textLength: 18
        )
    }

    private func lines(of url: URL) throws -> [Substring] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
    }

    func test_writesHeaderThenOneRowPerSample() throws {
        let url = tempURL()
        CursorLogger.shared.start()
        CursorLogger.shared.log(sample(selStart: 12, prevSelStart: 18))
        CursorLogger.shared.log(sample(selStart: 13, prevSelStart: 12))
        XCTAssertNotNil(CursorLogger.shared.stop(writingTo: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try lines(of: url)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(String(rows[0]), CursorSample.csvHeader)
    }

    func test_noSamplesWritesNoFile() {
        let url = tempURL()
        CursorLogger.shared.start()
        XCTAssertNil(CursorLogger.shared.stop(writingTo: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_startClearsThePreviousSession() throws {
        let first = tempURL()
        CursorLogger.shared.start()
        CursorLogger.shared.log(sample(selStart: 1, prevSelStart: 0))
        _ = CursorLogger.shared.stop(writingTo: first)
        try? FileManager.default.removeItem(at: first)

        let second = tempURL()
        CursorLogger.shared.start()
        CursorLogger.shared.log(sample(selStart: 5, prevSelStart: 4))
        XCTAssertNotNil(CursorLogger.shared.stop(writingTo: second))
        defer { try? FileManager.default.removeItem(at: second) }

        XCTAssertEqual(try lines(of: second).count, 2,
                       "second session must not carry the first session's rows")
    }

    func test_timestampsAreNonDecreasing() throws {
        let url = tempURL()
        CursorLogger.shared.start()
        CursorLogger.shared.log(sample(selStart: 12, prevSelStart: 18))
        CursorLogger.shared.log(sample(selStart: 13, prevSelStart: 12))
        _ = CursorLogger.shared.stop(writingTo: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try lines(of: url)
        let t0 = Double(rows[1].split(separator: ",", omittingEmptySubsequences: false)[0])!
        let t1 = Double(rows[2].split(separator: ",", omittingEmptySubsequences: false)[0])!
        XCTAssertLessThanOrEqual(t0, t1)
    }
}
