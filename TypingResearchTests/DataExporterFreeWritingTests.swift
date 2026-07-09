import XCTest
@testable import TypingResearch

/// Covers: DataExporter.exportFreeWritingCSV / exportFreeWritingText
/// (Tester focus areas #2 "edge case 1: no keystrokes" and #7 "CSV/TXT contents").
final class DataExporterFreeWritingTests: XCTestCase {

    private func makeParticipant(first: String = "Ada", last: String = "Lovelace") -> Participant {
        Participant(
            firstName: first,
            lastName: last,
            deviceModel: "iPhone",
            systemVersion: "17.0",
            screenWidthPt: 390,
            screenHeightPt: 844,
            appVersion: "1.0"
        )
    }

    private func makeEvent(
        textBefore: String,
        textAfter: String,
        replacementString: String,
        rangeStart: Int,
        rangeLength: Int,
        eventType: InputEventType,
        timestamp: Date
    ) -> InputEventData {
        InputEventData(
            trialId: UUID(),
            sessionId: UUID(),
            studyId: UUID(),
            timestamp: timestamp,
            eventType: eventType,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            expectedIndex: rangeStart,
            keyLabel: "", tapLocalX: 0, tapLocalY: 0, keyWidth: 0, keyHeight: 0,
            keyRow: "", keyCol: nil,
            expectedChar: "",
            actualChar: eventType == .insert ? replacementString : "",
            correctedChar: "",
            isCorrect: false,
            previousKeyLabel: "",
            textBefore: textBefore,
            textAfter: textAfter,
            interKeyIntervalMs: 42.5,
            sessionMode: "free_writing",
            studySessionIndex: 0,
            trialIndex: 0
        )
    }

    // MARK: - Edge case 1: zero keystrokes typed

    func testExportFreeWritingCSV_noEvents_producesHeaderOnlyCSV() throws {
        let exporter = DataExporter()
        let session = Session(participantId: UUID())
        let participant = makeParticipant()

        let url = try XCTUnwrap(exporter.exportFreeWritingCSV(
            session: session, prompt: "Write about anything.", finalText: "",
            events: [], participant: participant
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 1, "header-only CSV must have exactly one line")
        XCTAssertEqual(
            String(lines[0]),
            "participant_first,participant_last,session_id,mode,prompt,event_type,char,range_start,range_length,text_length_before,timestamp_ms,inter_key_interval_ms"
        )
    }

    func testExportFreeWritingText_noKeystrokes_writesPromptOnly() throws {
        let exporter = DataExporter()
        let participant = makeParticipant()

        let url = try XCTUnwrap(exporter.exportFreeWritingText(
            prompt: "Write about anything.", finalText: "", participant: participant
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "Write about anything.\n\n")
    }

    // MARK: - Happy path: rows line up with events

    func testExportFreeWritingCSV_rowsMatchEventsAndSchema() throws {
        let exporter = DataExporter()
        let session = Session(participantId: UUID())
        let participant = makeParticipant()
        let start = session.startedAt

        let e1 = makeEvent(textBefore: "", textAfter: "h", replacementString: "h",
                            rangeStart: 0, rangeLength: 0, eventType: .insert,
                            timestamp: start.addingTimeInterval(1.0))
        let e2 = makeEvent(textBefore: "h", textAfter: "hi", replacementString: "i",
                            rangeStart: 1, rangeLength: 0, eventType: .insert,
                            timestamp: start.addingTimeInterval(1.5))

        let url = try XCTUnwrap(exporter.exportFreeWritingCSV(
            session: session, prompt: "A prompt", finalText: "hi",
            events: [e1, e2], participant: participant
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3, "header + 2 event rows")

        let row1 = lines[1].components(separatedBy: ",")
        XCTAssertEqual(row1[0], "Ada")
        XCTAssertEqual(row1[1], "Lovelace")
        XCTAssertEqual(row1[3], "free_writing")
        XCTAssertEqual(row1[4], "A prompt")
        XCTAssertEqual(row1[5], "insert")
        XCTAssertEqual(row1[6], "h")          // char = replacementString
        XCTAssertEqual(row1[7], "0")          // range_start
        XCTAssertEqual(row1[8], "0")          // range_length
        XCTAssertEqual(row1[9], "0")          // text_length_before = "".count

        let row2 = lines[2].components(separatedBy: ",")
        XCTAssertEqual(row2[6], "i")
        XCTAssertEqual(row2[9], "1")          // text_length_before = "h".count
    }

    func testExportFreeWritingCSV_escapesCommasQuotesAndNewlinesInPrompt() throws {
        let exporter = DataExporter()
        let session = Session(participantId: UUID())
        let participant = makeParticipant()
        let trickyPrompt = "Describe \"home\", and why it, matters.\nSecond line."

        let e1 = makeEvent(textBefore: "", textAfter: "x", replacementString: "x",
                            rangeStart: 0, rangeLength: 0, eventType: .insert,
                            timestamp: session.startedAt)

        let url = try XCTUnwrap(exporter.exportFreeWritingCSV(
            session: session, prompt: trickyPrompt, finalText: "x",
            events: [e1], participant: participant
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        // The escaped prompt field must retain the embedded quote (doubled) and
        // stay inside one quoted CSV field, i.e. round-trippable.
        XCTAssertTrue(content.contains("\"Describe \"\"home\"\", and why it, matters.\nSecond line.\""))
    }

    func testExportFreeWritingText_containsPromptThenFinalText() throws {
        let exporter = DataExporter()
        let participant = makeParticipant()

        let url = try XCTUnwrap(exporter.exportFreeWritingText(
            prompt: "Prompt line.", finalText: "This is what I wrote.", participant: participant
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "Prompt line.\n\nThis is what I wrote.")
    }

    func testFilenamesUseFreeWritingSuffixesAndParticipantName() throws {
        let exporter = DataExporter()
        let session = Session(participantId: UUID())
        let participant = makeParticipant(first: "Grace", last: "Hopper")

        let csvURL = try XCTUnwrap(exporter.exportFreeWritingCSV(
            session: session, prompt: "p", finalText: "", events: [], participant: participant
        ))
        let txtURL = try XCTUnwrap(exporter.exportFreeWritingText(
            prompt: "p", finalText: "", participant: participant
        ))
        defer {
            try? FileManager.default.removeItem(at: csvURL)
            try? FileManager.default.removeItem(at: txtURL)
        }

        XCTAssertEqual(csvURL.lastPathComponent, "free_writing_Grace_Hopper.csv")
        XCTAssertEqual(txtURL.lastPathComponent, "free_writing_text_Grace_Hopper.txt")
    }

    // MARK: - Failure case: nil participant still produces a valid export

    func testExportFreeWritingCSV_nilParticipant_usesUnknownFallbackAndDoesNotCrash() throws {
        let exporter = DataExporter()
        let session = Session(participantId: UUID())

        let url = try XCTUnwrap(exporter.exportFreeWritingCSV(
            session: session, prompt: "p", finalText: "", events: [], participant: nil
        ))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "free_writing_unknown_unknown.csv")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("participant_first,participant_last"))
    }
}
