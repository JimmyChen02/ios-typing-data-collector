import XCTest

final class NativeTouchProbeTests: XCTestCase {
    func testNativeKeyboardEventDelivery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["start"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["control"].tap()
        let summary = app.staticTexts["summary"]
        XCTAssertTrue(summary.label.contains("App touches: 1"), summary.label)

        // Coordinate taps on real system key elements. Do not use typeText,
        // which can bypass the touch path this experiment is measuring.
        for key in ["q", "w", "e"] {
            let keyElement = app.keyboards.keys.matching(NSPredicate(format: "label ==[c] %@", key)).firstMatch
            XCTAssertTrue(keyElement.waitForExistence(timeout: 5), app.keyboards.debugDescription)
            XCTAssertTrue(app.frame.contains(keyElement.frame), "Keyboard key is offscreen; disconnect Simulator hardware keyboard")
            keyElement.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).tap()
        }
        let editor = app.textViews["editor"]
        XCTAssertEqual((editor.value as? String)?.lowercased(), "qwe")
        XCTAssertTrue(summary.label.contains("Text changes: 3"), summary.label)
        let csv = try XCTUnwrap(summary.value as? String)
        XCTAssertTrue(csv.contains("touch_down"), "Control touch must reach the observer")
        XCTAssertTrue(csv.contains("text_change"), "Apple keyboard must enter text normally")
        let report = XCTAttachment(string: "XCUITest-generated taps; not participant data.\n" + summary.label + "\n\n" + csv)
        report.name = "native-keyboard-event-delivery"
        report.lifetime = .keepAlways
        add(report)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("NATIVE_KEYBOARD_PROBE_RESULT\n" + summary.label + "\n" + csv)
        // Observation experiment: a passing test means the measurement worked,
        // not that native keyboard touches were exposed on this OS.
    }
}
