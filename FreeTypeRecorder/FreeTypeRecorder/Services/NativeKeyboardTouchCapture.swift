import UIKit

/// Observes app-delivered touches in the native keyboard window without
/// intercepting, replaying, or changing the keyboard's text-input behavior.
@MainActor
final class NativeKeyboardTouchCapture {
    static let shared = NativeKeyboardTouchCapture()
    private weak var editor: UITextView?
    private var keyboardFrame = CGRect.zero
    private var notifications: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.updateFrame(note) }
            })
        }
        for name in [UIResponder.keyboardWillHideNotification, UIApplication.willResignActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardFrame = .zero }
            })
        }
    }

    deinit {
        notifications.forEach(NotificationCenter.default.removeObserver)
    }

    func bind(_ editor: UITextView) {
        if self.editor !== editor { keyboardFrame = .zero }
        self.editor = editor
    }

    func unbind(_ editor: UITextView) {
        guard self.editor === editor else { return }
        self.editor = nil
        keyboardFrame = .zero
    }

    private func updateFrame(_ notification: Notification) {
        guard let editor, editor.isFirstResponder, let window = editor.window,
              let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        // Since iOS 16.1 keyboard notifications identify their screen when
        // available. Do not mix a keyboard on another screen into this session.
        if let screen = notification.object as? UIScreen, screen !== window.screen { return }
        keyboardFrame = value.cgRectValue.intersection(window.screen.bounds)
    }

    func observe(_ event: UIEvent) {
        guard KeystrokeLogger.shared.isCollectingNativeTaps,
              UIApplication.shared.applicationState == .active,
              let editor, editor.isFirstResponder, editor.isEditable,
              editor.inputView == nil, let editorWindow = editor.window,
              !keyboardFrame.isEmpty, !keyboardFrame.isNull else { return }

        for touch in event.allTouches ?? [] where touch.phase == .began {
            guard let window = touch.window, window.screen === editorWindow.screen,
                  // App-window taps can move the caret or dismiss the keyboard;
                  // they are already recorded by TouchOverlayWindow.
                  window !== editorWindow else { continue }
            let point = window.convert(touch.location(in: window), to: window.screen.coordinateSpace)
            let sample = NativeKeyboardTapSample(
                screenX: Double(point.x), screenY: Double(point.y),
                keyboardScreenX: Double(keyboardFrame.minX), keyboardScreenY: Double(keyboardFrame.minY),
                keyboardWidth: Double(keyboardFrame.width), keyboardHeight: Double(keyboardFrame.height),
                uptime: touch.timestamp, touchWindow: NSStringFromClass(type(of: window)))
            KeystrokeLogger.shared.logNativeTap(sample)
        }
    }
}
