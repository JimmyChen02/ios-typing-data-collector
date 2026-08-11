import XCTest
import UIKit

@MainActor
final class LastTouchTrackerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LastTouchTracker.shared.reset()
    }

    func test_recordsABeganTouch() {
        LastTouchTracker.shared.record(point: CGPoint(x: 10, y: 20), phase: .began)
        XCTAssertEqual(LastTouchTracker.shared.latest?.phase, "began")
        XCTAssertEqual(LastTouchTracker.shared.latest?.point, CGPoint(x: 10, y: 20))
    }

    func test_ignoresCancelledTouches() {
        LastTouchTracker.shared.record(point: CGPoint(x: 1, y: 1), phase: .cancelled)
        XCTAssertNil(LastTouchTracker.shared.latest)
    }

    func test_cancelledTouchDoesNotClobberAGoodOne() {
        LastTouchTracker.shared.record(point: CGPoint(x: 3, y: 3), phase: .began)
        LastTouchTracker.shared.record(point: CGPoint(x: 9, y: 9), phase: .cancelled)
        XCTAssertEqual(LastTouchTracker.shared.latest?.point, CGPoint(x: 3, y: 3))
    }

    func test_laterTouchReplacesEarlier() {
        LastTouchTracker.shared.record(point: CGPoint(x: 1, y: 1), phase: .began)
        LastTouchTracker.shared.record(point: CGPoint(x: 2, y: 2), phase: .moved)
        XCTAssertEqual(LastTouchTracker.shared.latest?.phase, "moved")
        XCTAssertEqual(LastTouchTracker.shared.latest?.point, CGPoint(x: 2, y: 2))
    }

    func test_resetClearsLatest() {
        LastTouchTracker.shared.record(point: .zero, phase: .began)
        LastTouchTracker.shared.reset()
        XCTAssertNil(LastTouchTracker.shared.latest)
    }
}
