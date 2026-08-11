import UIKit

/// Holds the most recent touch seen anywhere in the app's own window, so a
/// caret move can be attributed to the tap that caused it.
///
/// Points are in **window** coordinates, matching what TouchOverlayWindow
/// reports; LoggingTextView converts them into text-view coordinates when it
/// builds a CursorSample, so a single conversion point keeps the CSV in one
/// coordinate space.
///
/// This only ever sees in-app touches — the system keyboard renders in its own
/// window, which apps cannot observe. That blind spot is useful signal rather
/// than a gap: a caret move with no recent touch here and no accompanying text
/// change is a keyboard-driven move, i.e. the space-bar trackpad gesture.
@MainActor
final class LastTouchTracker {
    static let shared = LastTouchTracker()

    struct Touch {
        let point: CGPoint
        let phase: String
        let date: Date
    }

    private(set) var latest: Touch?

    private init() {}

    /// Records a touch. Phases other than began/moved/ended are ignored —
    /// a cancelled touch caused no caret move, so it must not displace the
    /// real touch that did.
    func record(point: CGPoint, phase: UITouch.Phase) {
        let name: String
        switch phase {
        case .began: name = "began"
        case .moved: name = "moved"
        case .ended: name = "ended"
        default: return
        }
        latest = Touch(point: point, phase: name, date: Date())
    }

    func reset() {
        latest = nil
    }
}
