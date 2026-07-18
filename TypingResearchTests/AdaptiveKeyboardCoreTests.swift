import XCTest
@testable import TypingResearch

final class AdaptiveKeyboardCoreTests: XCTestCase {
    func testContextHashDoesNotExposeRawContext() {
        let hash = ContextPrivacy.hash("private sentence")
        XCTAssertNotNil(hash)
        XCTAssertNotEqual(hash, "private sentence")
        XCTAssertEqual(hash?.count, 64)
    }

    func testResearchEventSchemaRoundTrip() throws {
        let event = KeyboardResearchEvent(
            sessionID: UUID(),
            kind: .touch,
            layout: .letters,
            key: "t",
            emittedText: "t",
            rawContext: "hello t",
            contextHash: ContextPrivacy.hash("hello t"),
            touchX: 12,
            touchY: 40,
            latencyMilliseconds: 1.2
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(KeyboardResearchEvent.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, AdaptiveKeyboardConstants.schemaVersion)
        XCTAssertEqual(decoded.kind, .touch)
        XCTAssertEqual(decoded.key, "t")
        XCTAssertEqual(decoded.emittedText, "t")
        XCTAssertEqual(decoded.touchX, 12)
    }

    func testRecordingDefaultsToOn() {
        let suite = "AdaptiveKeyboardCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SharedKeyboardPreferences(defaults: defaults)

        XCTAssertTrue(preferences.isRecording)
        preferences.recordingPaused = true
        XCTAssertFalse(preferences.isRecording)
    }

    func testCodableRectRoundTrip() throws {
        let rect = CodableRect(CGRect(x: 1, y: 2, width: 30, height: 40))
        let data = try JSONEncoder().encode(rect)
        let decoded = try JSONDecoder().decode(CodableRect.self, from: data)
        XCTAssertEqual(decoded.cgRect, CGRect(x: 1, y: 2, width: 30, height: 40))
    }
}
