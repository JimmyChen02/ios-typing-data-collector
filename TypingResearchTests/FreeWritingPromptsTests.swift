import XCTest
@testable import TypingResearch

/// Covers: FreeWritingPrompts (Utilities.swift) — prompt selection.
final class FreeWritingPromptsTests: XCTestCase {

    func testAllContainsEightNonEmptyUniquePrompts() {
        XCTAssertEqual(FreeWritingPrompts.all.count, 8)
        XCTAssertEqual(Set(FreeWritingPrompts.all).count, 8, "prompts should be unique")
        for prompt in FreeWritingPrompts.all {
            XCTAssertFalse(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Happy path: random() always returns a member of `all`.
    func testRandomAlwaysReturnsAKnownPrompt() {
        for _ in 0..<200 {
            let prompt = FreeWritingPrompts.random()
            XCTAssertTrue(FreeWritingPrompts.all.contains(prompt))
        }
    }

    /// Statistical sanity check: over many draws we should see more than one
    /// distinct prompt (guards against random() degenerating to a constant).
    func testRandomEventuallyVariesAcrossManyDraws() {
        var seen = Set<String>()
        for _ in 0..<500 {
            seen.insert(FreeWritingPrompts.random())
        }
        XCTAssertGreaterThan(seen.count, 1, "expected variety across 500 draws")
    }
}
