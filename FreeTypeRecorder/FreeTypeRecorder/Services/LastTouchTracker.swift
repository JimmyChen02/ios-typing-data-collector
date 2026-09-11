import UIKit

/// Holds the most recent touch seen anywhere in the app's own window, so a
/// caret move can be attributed to the tap that caused it.
///
/// Points are in **window** coordinates, matching what TouchOverlayWindow
/// reports; LoggingTextView converts them into text-view coordinates when it
/// builds a CursorSample, so a single conversion point keeps the CSV in one
/// coordinate space.
///
/// This tracker intentionally contains only app-window touches. Native keyboard
/// touches are collected separately by NativeKeyboardTouchCapture, so they do
/// not change the coordinate space or attribution used by cursor.csv.
@MainActor
final class LastTouchTracker {
    static let shared = LastTouchTracker()

    struct Touch {
        let point: CGPoint
        let phase: String
        let tapCount: Int
        let date: Date
    }

    private(set) var latest: Touch?

    private init() {}

    /// Records a touch. Phases other than began/moved/ended are ignored —
    /// a cancelled touch caused no caret move, so it must not displace the
    /// real touch that did.
    func record(point: CGPoint, phase: UITouch.Phase, tapCount: Int = 1) {
        let name: String
        switch phase {
        case .began: name = "began"
        case .moved: name = "moved"
        case .ended: name = "ended"
        default: return
        }
        latest = Touch(point: point, phase: name, tapCount: tapCount, date: Date())
    }

    func reset() {
        latest = nil
    }
}
