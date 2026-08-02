import XCTest

/// Deterministic RNG for shuffle tests. Reused across test files.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class PromptBankTests: XCTestCase {
    func test_bankHasAtLeastTenDistinctPrompts() {
        XCTAssertGreaterThanOrEqual(PromptBank.prompts.count, 10)
        XCTAssertEqual(Set(PromptBank.prompts).count, PromptBank.prompts.count)
    }

    func test_shuffledOrderIsAPermutation() {
        var rng = SeededGenerator(seed: 42)
        let order = PromptBank.shuffledOrder(using: &rng)
        XCTAssertEqual(Set(order), Set(PromptBank.prompts))
        XCTAssertEqual(order.count, PromptBank.prompts.count)
    }

    func test_shuffledOrderIsDeterministicForSameSeed() {
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        XCTAssertEqual(PromptBank.shuffledOrder(using: &a),
                       PromptBank.shuffledOrder(using: &b))
    }
}
