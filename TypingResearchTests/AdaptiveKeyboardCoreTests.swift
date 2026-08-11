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
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let parentEventID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let gestureID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let editID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let offerID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let correctionID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let keyFrame = CodableRect(CGRect(x: 20, y: 10, width: 32, height: 44))
        let target = TouchTarget(identifier: "key.t", key: "t", frame: keyFrame)
        let model = ModelProvenance(
            identifier: "symspell-en-30k",
            version: "c239062",
            artifact: "symspell_en_30k.tsv",
            sourceCommit: "c239062"
        )
        let candidates = [
            DecoderCandidate(
                text: "the",
                score: 2.4,
                languageScore: 5.55,
                stableID: "candidate-the",
                rank: 1
            ),
            DecoderCandidate(
                text: "teh",
                score: 1.5,
                isLiteral: true,
                stableID: "candidate-teh",
                rank: 2
            )
        ]
        let event = KeyboardResearchEvent(
            id: eventID,
            timestamp: timestamp,
            sessionID: sessionID,
            kind: .suggestionAccepted,
            layout: .letters,
            key: "t",
            emittedText: "the",
            rawContext: "the",
            contextHash: ContextPrivacy.hash("the"),
            touchX: 31,
            touchY: 25,
            preciseTouchX: 31.25,
            preciseTouchY: 24.75,
            touchRadius: 6,
            touchRadiusTolerance: 1.5,
            touchForce: 0.7,
            touchMaximumForce: 1,
            touchTimestamp: 1234.5,
            touchType: 0,
            keyFrame: keyFrame,
            candidates: candidates,
            selectedCandidate: "the",
            latencyMilliseconds: 1.2,
            metadata: ["source": "keyboard"],
            sequenceNumber: 42,
            parentEventID: parentEventID,
            gestureID: gestureID,
            editID: editID,
            predictionOfferID: offerID,
            correctionID: correctionID,
            touchGesture: TouchGesture(
                id: gestureID,
                samples: [
                    TouchSample(
                        phase: .began,
                        wallTimestamp: timestamp,
                        monotonicTimestamp: 1234.5,
                        absolutePosition: CodablePoint(x: 31, y: 25),
                        preciseAbsolutePosition: CodablePoint(x: 31.25, y: 24.75),
                        localPosition: CodablePoint(x: 11, y: 15),
                        normalizedPosition: CodablePoint(x: 0.34, y: 0.41),
                        radius: 6,
                        radiusTolerance: 1.5,
                        force: 0.7,
                        maximumForce: 1,
                        touchType: 0,
                        target: target
                    ),
                    TouchSample(
                        phase: .ended,
                        wallTimestamp: timestamp.addingTimeInterval(0.08),
                        monotonicTimestamp: 1234.58,
                        absolutePosition: CodablePoint(x: 33, y: 26),
                        localPosition: CodablePoint(x: 13, y: 16),
                        normalizedPosition: CodablePoint(x: 0.41, y: 0.45),
                        target: target
                    )
                ],
                initialTarget: target,
                finalTarget: target,
                selectedFrame: keyFrame,
                startedAt: timestamp,
                endedAt: timestamp.addingTimeInterval(0.08),
                durationMilliseconds: 80,
                didSlide: true
            ),
            editOperation: EditOperation(
                id: editID,
                type: .replace,
                source: .candidate,
                trigger: .candidateSelection,
                contextBefore: "teh",
                contextAfter: "the",
                originalText: "teh",
                replacementText: "the",
                deletedText: "teh",
                gestureID: gestureID,
                parentEventID: parentEventID,
                predictionOfferID: offerID,
                correctionID: correctionID
            ),
            predictionOffer: PredictionOffer(
                id: offerID,
                candidates: candidates,
                literalCandidateID: "candidate-teh",
                model: model,
                offeredAt: timestamp
            ),
            predictionOutcome: PredictionOutcome(
                offerID: offerID,
                kind: .accepted,
                selectedCandidateID: "candidate-the",
                correctionID: correctionID,
                occurredAt: timestamp.addingTimeInterval(0.2)
            ),
            latency: KeyboardLatency(
                touchDurationMilliseconds: 80,
                interEventMilliseconds: 120,
                proxyMutationMilliseconds: 2,
                decoderMilliseconds: 1.2,
                actionTotalMilliseconds: 4.5,
                offerToSelectionMilliseconds: 200
            ),
            environment: KeyboardEnvironmentSnapshot(
                orientation: .portrait,
                oneHandedMode: .right,
                shiftState: .lowercase,
                candidateBarVisible: true,
                settings: KeyboardSettingsSnapshot(
                    autoCapitalizationEnabled: true,
                    autocorrectionEnabled: true,
                    predictiveEnabled: true,
                    characterPreviewEnabled: false,
                    capsLockEnabled: true,
                    smartPunctuationEnabled: true
                ),
                deviceModel: "iPhone17,1",
                screenScale: 3,
                operatingSystemVersion: "19.0",
                appVersion: "1.0",
                fieldTraits: TextFieldTraitsSnapshot(
                    keyboardType: 0,
                    returnKeyType: 9,
                    autocapitalizationType: 1,
                    autocorrectionType: 0,
                    spellCheckingType: 0,
                    enablesReturnKeyAutomatically: true,
                    isSecureTextEntry: false
                ),
                hasContextBefore: true,
                hasContextAfter: false,
                isRecording: true
            ),
            layoutSnapshotID: snapshotID,
            layoutSnapshot: KeyboardLayoutSnapshot(
                id: snapshotID,
                layout: .letters,
                keyboardBounds: CodableRect(CGRect(x: 0, y: 0, width: 390, height: 260)),
                screenBounds: CodableRect(CGRect(x: 0, y: 0, width: 390, height: 844)),
                keyGeometries: [
                    KeyboardKeyGeometry(identifier: "key.t", label: "T", frame: keyFrame)
                ],
                candidateBarFrame: CodableRect(CGRect(x: 0, y: 0, width: 390, height: 44)),
                createdAt: timestamp
            ),
            modelProvenance: model
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(KeyboardResearchEvent.self, from: data)

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.schemaVersion, 6)
        XCTAssertEqual(decoded.touchGesture?.samples.last?.normalizedPosition, CodablePoint(x: 0.41, y: 0.45))
        XCTAssertEqual(decoded.editOperation?.predictionOfferID, offerID)
        XCTAssertEqual(decoded.predictionOffer?.candidates.map(\.stableID), ["candidate-the", "candidate-teh"])
        XCTAssertEqual(decoded.predictionOffer?.candidates.map(\.rank), [1, 2])
        XCTAssertEqual(decoded.sequenceNumber, 42)
    }

    func testSchemaV5EventDecodesWithoutV6OptionalFields() throws {
        let json = """
        {
          "id": "10000000-0000-0000-0000-000000000001",
          "schemaVersion": 5,
          "timestamp": 800000000,
          "sessionID": "10000000-0000-0000-0000-000000000002",
          "kind": "suggestionAccepted",
          "layout": "letters",
          "key": "t",
          "emittedText": "the",
          "rawContext": "I typed the",
          "contextHash": "1b5d7d3d75a6d1e0",
          "touchX": 31,
          "touchY": 25,
          "touchRadius": 6,
          "touchTimestamp": 1234.5,
          "touchType": 0,
          "keyFrame": {"x": 20, "y": 10, "width": 32, "height": 44},
          "candidates": [
            {"text": "the", "score": 2.4, "languageScore": 5.55, "isLiteral": false},
            {"text": "teh", "score": 1.5, "languageScore": 0, "isLiteral": true}
          ],
          "selectedCandidate": "the",
          "latencyMilliseconds": 1.2,
          "metadata": {"source": "keyboard"}
        }
        """

        let decoded = try JSONDecoder().decode(
            KeyboardResearchEvent.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertEqual(decoded.candidates?.map(\.text), ["the", "teh"])
        XCTAssertTrue(decoded.candidates?.allSatisfy { $0.stableID == nil && $0.rank == nil } == true)
        XCTAssertNil(decoded.sequenceNumber)
        XCTAssertNil(decoded.parentEventID)
        XCTAssertNil(decoded.gestureID)
        XCTAssertNil(decoded.editID)
        XCTAssertNil(decoded.predictionOfferID)
        XCTAssertNil(decoded.correctionID)
        XCTAssertNil(decoded.touchGesture)
        XCTAssertNil(decoded.editOperation)
        XCTAssertNil(decoded.predictionOffer)
        XCTAssertNil(decoded.predictionOutcome)
        XCTAssertNil(decoded.latency)
        XCTAssertNil(decoded.environment)
        XCTAssertNil(decoded.layoutSnapshotID)
        XCTAssertNil(decoded.layoutSnapshot)
        XCTAssertNil(decoded.modelProvenance)
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

    func testSymSpellModelIsBundledWithPinnedProvenance() {
        XCTAssertTrue(LocalLanguageDecoder.modelIsLoaded)
        XCTAssertEqual(
            LocalLanguageDecoder.loadedUnigramCount,
            LocalLanguageDecoder.expectedUnigramCount
        )
        XCTAssertEqual(
            LocalLanguageDecoder.modelSourceCommit,
            "c239062ae02961df18ab7da1671d01b4388204e0"
        )
    }

    func testLanguageDecoderUsesSymSpellFrequencyData() {
        let completion = LocalLanguageDecoder()
            .candidates(for: "th", previousWord: nil)
            .first(where: { $0.text == "the" })
        XCTAssertGreaterThan(
            completion?.languageScore ?? -1,
            10,
            "Candidates: \(LocalLanguageDecoder().candidates(for: "th", previousWord: nil))"
        )

        let misspelling = LocalLanguageDecoder().candidates(for: "wierd", previousWord: nil)
        XCTAssertTrue(misspelling.contains(where: { $0.text == "weird" && !$0.isLiteral }))
    }

    func testSymSpellUnigramFallbackDoesNotFabricateContextRules() {
        let decoder = LocalLanguageDecoder()
        XCTAssertEqual(
            decoder.candidates(for: "", previousWord: "how"),
            decoder.candidates(for: "", previousWord: "thank")
        )
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
        XCTAssertEqual(correction?.text, "the", "Candidates: \(candidates)")
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
            "the",
            "Candidates: \(candidates)"
        )
    }

    func testAutomaticCorrectionNeverAppliesPrefixCompletions() {
        let candidates = [
            DecoderCandidate(text: "hel", score: 1.0, languageScore: 0, isLiteral: true),
            DecoderCandidate(text: "hello", score: 3.5, languageScore: 4.0),
            DecoderCandidate(text: "help", score: 3.0, languageScore: 3.5)
        ]
        XCTAssertNil(
            CorrectionFeedbackPolicy.automaticCorrection(from: candidates, literal: "hel"),
            "Prefix completions must stay tap-to-accept, never apply on space"
        )
    }

    func testAutomaticCorrectionSkipsKnownDictionaryWords() {
        let candidates = [
            DecoderCandidate(text: "hell", score: 2.5, languageScore: 3.0, isLiteral: true),
            DecoderCandidate(text: "hello", score: 4.0, languageScore: 4.5)
        ]
        XCTAssertNil(
            CorrectionFeedbackPolicy.automaticCorrection(from: candidates, literal: "hell"),
            "Known words should not be force-replaced on space"
        )
    }
}
