import UIKit

/// Peeks at every touch passing through this window — `super.sendEvent` runs
/// first, so normal hit-testing and responder-chain delivery are untouched —
/// and draws a precise dot at each touch-down location. This is what makes
/// tap locations visible in the ReplayKit screen recording, since iOS does
/// not render touch points on-screen by default.
///
/// Note: this only sees touches within the app's own window. The system
/// keyboard renders in its own separate window (UIRemoteKeyboardWindow),
/// which apps cannot intercept touches on — this is an intentional iOS
/// restriction, not a gap in this implementation. The screen recording
/// still visually shows the real keyboard being used; there's just no dot
/// drawn on top of it specifically. A custom in-app keyboard would be the
/// only way around that, at the cost of no longer testing the real system
/// keyboard's feel.
///
/// The live holding-hand prediction is burned into the segmented/silhouette
/// video instead of here — see SegmentedFaceCaptureWriter.
final class TouchOverlayWindow: UIWindow {

    private let dotView = TouchDotOverlayView()

    override func layoutSubviews() {
        super.layoutSubviews()
        if dotView.superview !== self {
            dotView.frame = bounds
            dotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(dotView)
        }
        // SwiftUI's hosting view can re-order subviews on layout; keep the
        // dot layer on top so it's always visible in the recording.
        bringSubviewToFront(dotView)
    }

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)

        guard RippleController.shared.isRecording, let touches = event.allTouches else { return }
        for touch in touches where touch.phase == .began {
            dotView.addDot(at: touch.location(in: self))
        }
    }
}
