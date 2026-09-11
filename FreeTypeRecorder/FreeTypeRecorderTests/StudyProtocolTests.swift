import XCTest

@MainActor
final class StudyProtocolTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    func test_initialState_quotasAndProgress() {
        let p = StudyProtocol(defaults: freshDefaults())
        XCTAssertEqual(p.completedCount, 0)
        XCTAssertEqual(p.nextSessionNumber, 1)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(StudyProtocol.totalSessions, 16)
        XCTAssertEqual(p.remaining(for: .left), 3)
        XCTAssertEqual(p.remaining(for: .right), 3)
        XCTAssertEqual(p.remaining(for: .both), 10)
        XCTAssertEqual(p.availableConditions, [.left, .right, .both])
    }

    func test_startNewParticipant_shufflesFullPromptOrder() {
        let p = StudyProtocol(defaults: freshDefaults())
        p.startNewParticipant()
        XCTAssertEqual(Set(p.promptOrder), Set(PromptBank.prompts))
        XCTAssertEqual(p.promptOrder.count, PromptBank.prompts.count)
    }

    func test_recordCompletion_decrementsQuotaAndNumbers() {
        let p = StudyProtocol(defaults: freshDefaults())
        p.startNewParticipant()
        p.recordCompletion(hand: .left)
        p.recordCompletion(hand: .left)
        p.recordCompletion(hand: .left)
        XCTAssertEqual(p.remaining(for: .left), 0)
        XCTAssertFalse(p.availableConditions.contains(.left))
        XCTAssertEqual(p.completed.map(\.number), [1, 2, 3])
    }

    func test_overQuota_isNoOp() {
        let p = StudyProtocol(defaults: freshDefaults())
        p.startNewParticipant()
        for _ in 0..<5 { p.recordCompletion(hand: .left) } // only 3 allowed
        XCTAssertEqual(p.completedCount(for: .left), 3)
        for _ in 0..<12 { p.recordCompletion(hand: .both) }
        XCTAssertEqual(p.completedCount(for: .both), 10)
        XCTAssertEqual(p.availableConditions, [.right])
    }

    func test_fullRun_sixteenDistinctNumbersAndPromptsThenComplete() {
        let p = StudyProtocol(defaults: freshDefaults())
        p.startNewParticipant()
        let sequence: [HoldingHand] =
            [.both, .left, .right, .both, .left, .right, .both, .left, .right, .both]
            + Array(repeating: .both, count: 6)
        for hand in sequence { p.recordCompletion(hand: hand) }
        XCTAssertEqual(p.completedCount, 16)
        XCTAssertTrue(p.isComplete)
        XCTAssertTrue(p.availableConditions.isEmpty)
        XCTAssertEqual(Set(p.completed.map(\.number)), Set(1...16))
        XCTAssertEqual(Set(p.completed.map(\.prompt)).count, 16) // no repeats
        p.recordCompletion(hand: .both)
        XCTAssertEqual(p.completedCount, 16)
    }

    func test_statePersistsAcrossInstances() {
        let defaults = freshDefaults()
        let a = StudyProtocol(defaults: defaults)
        a.startNewParticipant()
        a.recordCompletion(hand: .both)
        a.recordCompletion(hand: .left)
        let b = StudyProtocol(defaults: defaults)
        XCTAssertEqual(b.completedCount, 2)
        XCTAssertEqual(b.remaining(for: .both), 9)
        XCTAssertEqual(b.remaining(for: .left), 2)
    }

    func testExistingTenSessionStudyKeepsProgressAndGainsSixBothHandSessions() throws {
        let defaults = freshDefaults()
        let oldOrder = Array(PromptBank.prompts.prefix(12).reversed())
        let oldHands: [HoldingHand] = [.both, .left, .right, .both, .left, .right, .both, .left, .right, .both]
        let oldCompleted = oldHands.enumerated().map { index, hand in
            StudyProtocol.CompletedSession(number: index + 1, hand: hand.rawValue, prompt: oldOrder[index])
        }
        defaults.set(try JSONEncoder().encode(oldOrder), forKey: "FreeTypeRecorder.promptOrder")
        defaults.set(try JSONEncoder().encode(oldCompleted), forKey: "FreeTypeRecorder.completedSessions")

        let updated = StudyProtocol(defaults: defaults)
        XCTAssertEqual(updated.completed, oldCompleted)
        XCTAssertEqual(Array(updated.promptOrder.prefix(12)), oldOrder)
        XCTAssertEqual(updated.promptOrder.count, 16)
        XCTAssertEqual(Set(updated.promptOrder).count, 16)
        XCTAssertEqual(updated.nextSessionNumber, 11)
        XCTAssertFalse(updated.isComplete)
        XCTAssertEqual(updated.remaining(for: .left), 0)
        XCTAssertEqual(updated.remaining(for: .right), 0)
        XCTAssertEqual(updated.remaining(for: .both), 6)
        XCTAssertEqual(updated.availableConditions, [.both])
        XCTAssertEqual(StudyProtocol(defaults: defaults).promptOrder, updated.promptOrder)

        for _ in 0..<6 { updated.recordCompletion(hand: .both) }
        let reloaded = StudyProtocol(defaults: defaults)
        XCTAssertTrue(reloaded.isComplete)
        XCTAssertEqual(reloaded.completedCount, 16)
        XCTAssertEqual(Array(reloaded.completed.prefix(10)), oldCompleted)
        XCTAssertEqual(Set(reloaded.completed.map(\.prompt)).count, 16)
    }
}
