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
            kind: .suggestionAccepted,
            layout: .letters,
            key: "t",
            emittedText: "the",
            rawContext: "the",
            contextHash: ContextPrivacy.hash("the"),
            candidates: [
                DecoderCandidate(text: "the", score: 2.4),
                DecoderCandidate(text: "teh", score: 1.5, isLiteral: true)
            ],
            selectedCandidate: "the",
            latencyMilliseconds: 1.2
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(KeyboardResearchEvent.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, AdaptiveKeyboardConstants.schemaVersion)
        XCTAssertEqual(decoded.kind, .suggestionAccepted)
        XCTAssertEqual(decoded.selectedCandidate, "the")
        XCTAssertEqual(decoded.candidates?.count, 2)
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

    func testKeyboardBehaviorDefaultsMatchIOS() {
        let suite = "AdaptiveKeyboardCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SharedKeyboardPreferences(defaults: defaults)

        XCTAssertTrue(preferences.autoCapitalizationEnabled)
        XCTAssertTrue(preferences.autocorrectionEnabled)
        XCTAssertTrue(preferences.predictiveEnabled)
        XCTAssertTrue(preferences.characterPreviewEnabled)
        XCTAssertTrue(preferences.capsLockEnabled)
        XCTAssertTrue(preferences.smartPunctuationEnabled)
        XCTAssertEqual(preferences.oneHandedMode, .off)

        preferences.predictiveEnabled = false
        preferences.oneHandedMode = .right
        XCTAssertFalse(preferences.predictiveEnabled)
        XCTAssertEqual(preferences.oneHandedMode, .right)
    }

    func testRecentEmojiMostRecentFirstWithoutDuplicates() {
        let suite = "AdaptiveKeyboardCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SharedKeyboardPreferences(defaults: defaults)

        preferences.noteEmojiUse("😀")
        preferences.noteEmojiUse("🎉")
        preferences.noteEmojiUse("😀")

        XCTAssertEqual(preferences.recentEmoji, ["😀", "🎉"])
    }

    func testKeyAlternatesFollowShiftState() {
        XCTAssertEqual(KeyAlternates.alternates(for: "e").first, "è")
        XCTAssertEqual(KeyAlternates.alternates(for: "E").first, "È")
        XCTAssertTrue(KeyAlternates.hasAlternates(for: "$"))
        XCTAssertFalse(KeyAlternates.hasAlternates(for: "q"))
    }

    func testSmartPunctuationQuotesAndDash() {
        XCTAssertEqual(SmartPunctuation.substitution(for: "\"", contextBefore: "he said "), "“")
        XCTAssertEqual(SmartPunctuation.substitution(for: "\"", contextBefore: "he said “hi"), "”")
        XCTAssertEqual(SmartPunctuation.substitution(for: "'", contextBefore: "don"), "’")
        XCTAssertTrue(SmartPunctuation.completesEmDash("-", contextBefore: "wait-"))
        XCTAssertFalse(SmartPunctuation.completesEmDash("-", contextBefore: "wait"))
    }

    func testCodableRectRoundTrip() throws {
        let rect = CodableRect(CGRect(x: 1, y: 2, width: 30, height: 40))
        let data = try JSONEncoder().encode(rect)
        let decoded = try JSONDecoder().decode(CodableRect.self, from: data)
        XCTAssertEqual(decoded.cgRect, CGRect(x: 1, y: 2, width: 30, height: 40))
    }

    func testLanguageDecoderIncludesLiteralAndCompletion() {
        let candidates = LocalLanguageDecoder().candidates(for: "th", previousWord: nil)
        XCTAssertTrue(candidates.contains(where: { $0.text == "th" && $0.isLiteral }))
        XCTAssertTrue(candidates.contains(where: { $0.text.hasPrefix("th") && $0.text != "th" }))
        XCTAssertLessThanOrEqual(candidates.count, 3)
    }

    func testAutomaticCorrectionRequiresSameLengthAndMargin() {
        let candidates = [
            DecoderCandidate(text: "teh", score: 1.5, isLiteral: true),
            DecoderCandidate(text: "the", score: 2.4),
            DecoderCandidate(text: "there", score: 3)
        ]
        XCTAssertEqual(
            CorrectionFeedbackPolicy.automaticCorrection(
                from: candidates,
                literal: "teh"
            )?.text,
            "the"
        )
    }

    func testAutomaticCorrectionRejectsWeakOrDifferentLength() {
        let weak = [
            DecoderCandidate(text: "teh", score: 2.0, isLiteral: true),
            DecoderCandidate(text: "the", score: 2.2)
        ]
        XCTAssertNil(
            CorrectionFeedbackPolicy.automaticCorrection(from: weak, literal: "teh")
        )

        let differentLength = [
            DecoderCandidate(text: "th", score: 1.5, isLiteral: true),
            DecoderCandidate(text: "the", score: 3.0)
        ]
        XCTAssertNil(
            CorrectionFeedbackPolicy.automaticCorrection(from: differentLength, literal: "th")
        )
    }

    func testDecoderCorrectsCommonTypoTeh() {
        let candidates = LocalLanguageDecoder().candidates(for: "teh", previousWord: nil)
        let correction = CorrectionFeedbackPolicy.automaticCorrection(
            from: candidates,
            literal: "teh"
        )
        XCTAssertEqual(correction?.text, "the")
    }

    func testAutomaticCorrectionHandlesMissingAndExtraCharacter() {
        let missing = LocalLanguageDecoder().candidates(for: "helo", previousWord: nil)
        XCTAssertEqual(
            CorrectionFeedbackPolicy.automaticCorrection(from: missing, literal: "helo")?.text,
            "hello"
        )

        let extra = LocalLanguageDecoder().candidates(for: "helllo", previousWord: nil)
        XCTAssertEqual(
            CorrectionFeedbackPolicy.automaticCorrection(from: extra, literal: "helllo")?.text,
            "hello"
        )
    }

    func testAutomaticCorrectionHandlesAdjacentTransposition() {
        let candidates = LocalLanguageDecoder().candidates(for: "hte", previousWord: nil)
        XCTAssertEqual(
            CorrectionFeedbackPolicy.automaticCorrection(from: candidates, literal: "hte")?.text,
            "the"
        )
    }
}
