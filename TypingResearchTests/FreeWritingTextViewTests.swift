import XCTest
import SwiftUI
import UIKit
@testable import TypingResearch

/// Covers FreeWritingTextView.Coordinator's event classification and
/// textAfter computation — spec DECISIONS + edge cases 4/5 (autocorrect
/// multi-char replacement / paste, emoji / multi-scalar input).
final class FreeWritingTextViewTests: XCTestCase {

    private struct CapturedEvent {
        let textBefore: String
        let textAfter: String
        let replacementString: String
        let rangeStart: Int
        let rangeLength: Int
        let eventType: InputEventType
    }

    /// Builds a real UITextView + Coordinator pair so we exercise the actual
    /// UIKit delegate method, not a re-implementation of its logic.
    private func makeCoordinator(initialText: String) -> (FreeWritingTextView.Coordinator, UITextView, () -> [CapturedEvent]) {
        var captured: [CapturedEvent] = []
        let binding = Binding<String>(get: { initialText }, set: { _ in })
        let view = FreeWritingTextView(text: binding) { textBefore, textAfter, replacementString, rangeStart, rangeLength, eventType in
            captured.append(CapturedEvent(
                textBefore: textBefore, textAfter: textAfter, replacementString: replacementString,
                rangeStart: rangeStart, rangeLength: rangeLength, eventType: eventType
            ))
        }
        let coordinator = view.makeCoordinator()
        let textView = UITextView()
        textView.text = initialText
        return (coordinator, textView, { captured })
    }

    // MARK: - Happy path: simple insert

    func testSingleCharacterInsert_isClassifiedAsInsertWithCorrectTextAfter() {
        let (coordinator, textView, events) = makeCoordinator(initialText: "hi")
        let shouldChange = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "!"
        )

        XCTAssertTrue(shouldChange, "must return true so UIKit applies the change natively")
        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .insert)
        XCTAssertEqual(e.textBefore, "hi")
        XCTAssertEqual(e.textAfter, "hi!")
        XCTAssertEqual(e.replacementString, "!")
        XCTAssertEqual(e.rangeStart, 2)
        XCTAssertEqual(e.rangeLength, 0)
    }

    // MARK: - Delete

    func testDelete_isClassifiedAsDelete() {
        let (coordinator, textView, events) = makeCoordinator(initialText: "hi!")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 2, length: 1), replacementText: ""
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .delete)
        XCTAssertEqual(e.textAfter, "hi")
    }

    // MARK: - Edge case 4: single-char replace vs. multi-char paste/autocorrect

    func testSingleCharacterOverSelection_isClassifiedAsReplace() {
        let (coordinator, textView, events) = makeCoordinator(initialText: "cat")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementText: "b"
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .replace)
        XCTAssertEqual(e.textAfter, "bat")
    }

    func testAutocorrectStyleMultiCharReplacement_isClassifiedAsPasteWithCorrectTextAfter() {
        // Simulates autocorrect swapping "teh" -> "the" as one replacement.
        let (coordinator, textView, events) = makeCoordinator(initialText: "teh")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 3), replacementText: "the"
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .paste)
        XCTAssertEqual(e.replacementString, "the")
        XCTAssertEqual(e.textAfter, "the")
    }

    func testMultiCharPasteInMiddleOfText_producesCorrectTextAfter() {
        let (coordinator, textView, events) = makeCoordinator(initialText: "start end")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 6, length: 0), replacementText: "middle "
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .paste)
        XCTAssertEqual(e.textAfter, "start middle end")
    }

    // MARK: - Edge case 5: emoji / multi-scalar input (UTF-16 offsets)

    func testEmojiInsert_computesTextAfterUsingUTF16Offsets() {
        // "hi" + insert an emoji at the end. Emoji are multi-UTF16-unit but a
        // single Swift Character, so this should still classify as .insert
        // and produce a correct textAfter via NSString (not Swift indexing).
        let (coordinator, textView, events) = makeCoordinator(initialText: "hi")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "😀"
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .insert)
        XCTAssertEqual(e.textAfter, "hi😀")
    }

    func testDeleteAfterEmoji_usesUTF16RangeCorrectly() {
        // "hi😀" — the emoji occupies 2 UTF-16 units at the end (positions 2-3).
        let (coordinator, textView, events) = makeCoordinator(initialText: "hi😀")
        _ = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 2, length: 2), replacementText: ""
        )

        XCTAssertEqual(events().count, 1)
        let e = events()[0]
        XCTAssertEqual(e.eventType, .delete)
        XCTAssertEqual(e.textAfter, "hi")
    }

    // MARK: - Failure case: no-op edit (empty replacement, zero-length range)

    func testNoOpEdit_doesNotFireOnEventAndStillReturnsTrue() {
        let (coordinator, textView, events) = makeCoordinator(initialText: "hi")
        let shouldChange = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 1, length: 0), replacementText: ""
        )

        XCTAssertTrue(shouldChange)
        XCTAssertTrue(events().isEmpty, "an empty replacement over a zero-length range carries no event")
    }
}
