import Foundation

/// A measured touch in the native keyboard's onscreen rectangle. Apple's
/// individual key geometry and intended key are not exposed by this observer.
struct NativeKeyboardTapSample {
    let screenX: Double
    let screenY: Double
    let keyboardScreenX: Double
    let keyboardScreenY: Double
    let keyboardWidth: Double
    let keyboardHeight: Double
    let uptime: TimeInterval
    let touchWindow: String

    var x: Double { screenX - keyboardScreenX }
    var y: Double { screenY - keyboardScreenY }

    var isValid: Bool {
        [screenX, screenY, keyboardScreenX, keyboardScreenY,
         keyboardWidth, keyboardHeight, uptime].allSatisfy { $0.isFinite }
            && keyboardWidth > 0 && keyboardHeight > 0
            && x >= 0 && x < keyboardWidth && y >= 0 && y < keyboardHeight
    }
}
