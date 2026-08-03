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
        XCTAssertEqual(p.remaining(for: .left), 3)
        XCTAssertEqual(p.remaining(for: .right), 3)
        XCTAssertEqual(p.remaining(for: .both), 4)
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
    }

    func test_fullRun_tenDistinctNumbersAndPromptsThenComplete() {
        let p = StudyProtocol(defaults: freshDefaults())
        p.startNewParticipant()
        let sequence: [HoldingHand] =
            [.both, .left, .right, .both, .left, .right, .both, .left, .right, .both]
        for hand in sequence { p.recordCompletion(hand: hand) }
        XCTAssertEqual(p.completedCount, 10)
        XCTAssertTrue(p.isComplete)
        XCTAssertTrue(p.availableConditions.isEmpty)
        XCTAssertEqual(Set(p.completed.map(\.number)), Set(1...10))
        XCTAssertEqual(Set(p.completed.map(\.prompt)).count, 10) // no repeats
    }

    func test_statePersistsAcrossInstances() {
        let defaults = freshDefaults()
        let a = StudyProtocol(defaults: defaults)
        a.startNewParticipant()
        a.recordCompletion(hand: .both)
        a.recordCompletion(hand: .left)
        let b = StudyProtocol(defaults: defaults)
        XCTAssertEqual(b.completedCount, 2)
        XCTAssertEqual(b.remaining(for: .both), 3)
        XCTAssertEqual(b.remaining(for: .left), 2)
    }
}
