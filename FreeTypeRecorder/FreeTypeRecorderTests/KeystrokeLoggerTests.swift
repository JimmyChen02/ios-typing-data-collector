import XCTest

@MainActor
final class KeystrokeLoggerTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
    }

    /// Runs one logging session and returns the CSV it produced.
    private func writeCSV(_ body: () -> Void) throws -> String {
        let url = tempURL()
        KeystrokeLogger.shared.start()
        body()
        XCTAssertNotNil(KeystrokeLogger.shared.stop(writingTo: url))
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fields(ofRow row: Substring) -> [String] {
        row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    func test_headerContainsReplacedText() throws {
        let csv = try writeCSV {
            KeystrokeLogger.shared.logEvent(
                type: .insert, replacedText: "", replacementText: "a",
                rangeStart: 0, rangeLength: 0, resultingTextLength: 1
            )
        }
        let header = csv.split(separator: "\n")[0]
        XCTAssertTrue(header.contains("replaced_text"), "header missing replaced_text: \(header)")
    }

    func test_headerAndRowHaveMatchingFieldCounts() throws {
        let csv = try writeCSV {
            KeystrokeLogger.shared.logEvent(
                type: .insert, replacedText: "", replacementText: "a",
                rangeStart: 0, rangeLength: 0, resultingTextLength: 1
            )
        }
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(fields(ofRow: lines[1]).count, fields(ofRow: lines[0]).count)
    }

    func test_deleteRecordsTheRemovedCharacter() throws {
        let csv = try writeCSV {
            KeystrokeLogger.shared.logEvent(
                type: .delete, replacedText: "n", replacementText: "",
                rangeStart: 13, rangeLength: 1, resultingTextLength: 17
            )
        }
        let lines = csv.split(separator: "\n")
        let header = fields(ofRow: lines[0])
        let row = fields(ofRow: lines[1])
        XCTAssertEqual(row[header.firstIndex(of: "replaced_text")!], "n")
        XCTAssertEqual(row[header.firstIndex(of: "replacement_text")!], "")
    }

    func test_replaceRecordsBothSidesOfTheSubstitution() throws {
        let csv = try writeCSV {
            KeystrokeLogger.shared.logEvent(
                type: .replace, replacedText: "brwn", replacementText: "brown",
                rangeStart: 10, rangeLength: 4, resultingTextLength: 19
            )
        }
        let lines = csv.split(separator: "\n")
        let header = fields(ofRow: lines[0])
        let row = fields(ofRow: lines[1])
        XCTAssertEqual(row[header.firstIndex(of: "replaced_text")!], "brwn")
        XCTAssertEqual(row[header.firstIndex(of: "replacement_text")!], "brown")
    }

    func test_commaInReplacedTextIsQuoted() throws {
        let csv = try writeCSV {
            KeystrokeLogger.shared.logEvent(
                type: .replace, replacedText: "a,b", replacementText: "c",
                rangeStart: 0, rangeLength: 3, resultingTextLength: 1
            )
        }
        XCTAssertTrue(csv.contains("\"a,b\""), "comma-bearing field must be quoted: \(csv)")
    }

    func test_noEventsWritesNoFile() {
        let url = tempURL()
        KeystrokeLogger.shared.start()
        XCTAssertNil(KeystrokeLogger.shared.stop(writingTo: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
