import Foundation
import Observation

// Shared on/off switch for the tap-ripple overlay. Kept separate from
// SessionRecorder so TouchOverlayWindow (a plain UIWindow, constructed before
// any SwiftUI view exists) can read it without depending on the view layer.
// Ripples are only drawn while a notepad recording session is active — not
// while browsing the session list — so the overlay never visually collides
// with taps that aren't part of a recorded session.
@MainActor
@Observable
final class RippleController {
    static let shared = RippleController()

    var isRecording: Bool = false

    private init() {}
}
