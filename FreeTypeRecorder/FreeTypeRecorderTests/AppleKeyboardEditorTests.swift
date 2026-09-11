import XCTest
import SwiftUI
import UIKit

@MainActor
final class AppleKeyboardEditorTests: XCTestCase {
    func testEditorUsesNativeKeyboardWithAutocorrectAndPredictions() async throws {
        let host = UIHostingController(rootView: LoggingTextView(text: .constant(""), isEditable: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let rendered = expectation(description: "SwiftUI editor mounted")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 2)
        host.view.layoutIfNeeded()
        func findEditor(_ view: UIView) -> UITextView? {
            if let editor = view as? UITextView { return editor }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(host.view))
        XCTAssertNil(editor.inputView, "UIKit must supply the native keyboard")
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.autocorrectionType, .yes)
        XCTAssertEqual(editor.spellCheckingType, .yes)
        XCTAssertEqual(editor.autocapitalizationType, .sentences)
        XCTAssertNotEqual(editor.inlinePredictionType, .no)
    }
}
