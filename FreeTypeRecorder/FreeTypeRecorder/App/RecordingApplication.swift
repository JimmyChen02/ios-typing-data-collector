import UIKit

final class RecordingApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        NativeKeyboardTouchCapture.shared.observe(event)
        // Always forward the original event, including when recording is off.
        super.sendEvent(event)
    }
}
