import SwiftUI
import UIKit

/// Geometry that matches the docked English iOS keyboard on the current iPhone.
///
/// Key sizes are driven by **screen width** (same approach iOS uses), not by
/// stretching rows to fill an arbitrary height. Outer chrome height prefers a
/// live measurement of the system keyboard when available.
enum SystemKeyboardMetrics {
    private static let defaultsKey = "SystemKeyboardMetrics.measuredContentHeight.v2"
    static let didUpdateNotification = Notification.Name("SystemKeyboardMetrics.didUpdate")

    private static var didScheduleProbe = false
    private static var probeField: UITextField?
    private static var probeObserver: NSObjectProtocol?

    struct LayoutSpec: Equatable {
        var isLandscape: Bool
        var deviceClassScale: CGFloat
        var candidateBarHeight: CGFloat
        var sideInset: CGFloat
        var keyGap: CGFloat
        var rowGap: CGFloat
        var topPad: CGFloat
        var bottomPad: CGFloat
        /// Letter-key width for a 10-key top row.
        var letterKeyWidth: CGFloat
        /// Uniform row height for the four key rows.
        var rowHeight: CGFloat
        /// Key rows + QuickType bar (no home-indicator strip).
        var contentHeight: CGFloat
        /// Letter glyph point size.
        var letterFontSize: CGFloat
    }

    /// 0...1 scale from short screen side (320pt SE → 428pt Pro Max).
    static func deviceClassScale(
        screenBounds: CGRect = UIScreen.main.bounds
    ) -> CGFloat {
        let shortSide = min(screenBounds.width, screenBounds.height)
        return clamp((shortSide - 320) / 108, min: 0, max: 1)
    }

    static func isLandscape(
        screenBounds: CGRect = UIScreen.main.bounds,
        windowScene: UIWindowScene? = nil
    ) -> Bool {
        if let orientation = windowScene?.interfaceOrientation, orientation != .unknown {
            return orientation.isLandscape
        }
        return screenBounds.width > screenBounds.height
    }

    static func bottomSafeAreaInset() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.safeAreaInsets.bottom
            ?? scene?.windows.first?.safeAreaInsets.bottom
            ?? 0
    }

    /// Width-driven iOS-like key geometry for the given keyboard width.
    static func layoutSpec(
        keyboardWidth: CGFloat? = nil,
        screenBounds: CGRect = UIScreen.main.bounds,
        windowScene: UIWindowScene? = nil
    ) -> LayoutSpec {
        let landscape = isLandscape(screenBounds: screenBounds, windowScene: windowScene)
        let t = deviceClassScale(screenBounds: screenBounds)
        let width = keyboardWidth
            ?? (landscape
                ? max(screenBounds.width, screenBounds.height)
                : min(screenBounds.width, screenBounds.height))

        // Horizontal metrics tuned to stock English iPhone keyboards.
        // Gaps stay near 6pt; side inset grows slightly on larger phones.
        let side: CGFloat = landscape ? (2.5 + t * 0.8) : (3.0 + t * 3.0)      // ~3...6
        let gap: CGFloat = landscape ? (4.5 + t * 1.0) : (6.0 + t * 0.75)      // ~6...6.75
        let rowGap: CGFloat = landscape ? (6.5 + t * 1.2) : (10.5 + t * 1.5)   // ~10.5...12
        let topPad: CGFloat = landscape ? 4 : 6
        let bottomPad: CGFloat = landscape ? 3 : 8
        let candidate: CGFloat = landscape ? (32 + t * 3) : (38 + t * 4)        // ~38...42

        let letterWidth = (width - side * 2 - gap * 9) / 10
        // iOS letter keys are a bit taller than wide (~1.28–1.35×).
        let naturalHeight = letterWidth * (landscape ? 1.18 : 1.32)
        let rowHeight = clamp(
            naturalHeight,
            min: landscape ? 30 : 38,
            max: landscape ? 40 : 46
        )
        let letterFont = clamp(letterWidth * 0.70, min: landscape ? 17 : 20, max: landscape ? 20 : 23)

        let content = candidate
            + topPad
            + rowHeight * 4
            + rowGap * 3
            + bottomPad

        // If we have a live system measurement, keep key sizes (width-driven)
        // and only absorb leftover height into bottom pad so keys don't stretch.
        var adjustedBottom = bottomPad
        var adjustedContent = content
        if let measured = measuredContentHeight(), measured > 180 {
            let delta = measured - content
            if abs(delta) > 0.5 {
                adjustedBottom = max(4, bottomPad + delta)
                adjustedContent = measured
            }
        }

        return LayoutSpec(
            isLandscape: landscape,
            deviceClassScale: t,
            candidateBarHeight: candidate,
            sideInset: side,
            keyGap: gap,
            rowGap: rowGap,
            topPad: topPad,
            bottomPad: adjustedBottom,
            letterKeyWidth: letterWidth,
            rowHeight: rowHeight,
            contentHeight: adjustedContent,
            letterFontSize: letterFont
        )
    }

    static func contentHeight(
        includesCandidateBar: Bool = true,
        screenBounds: CGRect = UIScreen.main.bounds,
        windowScene: UIWindowScene? = nil
    ) -> CGFloat {
        let spec = layoutSpec(screenBounds: screenBounds, windowScene: windowScene)
        if includesCandidateBar { return spec.contentHeight }
        return spec.contentHeight - spec.candidateBarHeight
    }

    static func totalDockedHeight(
        includesCandidateBar: Bool = true,
        screenBounds: CGRect = UIScreen.main.bounds,
        windowScene: UIWindowScene? = nil
    ) -> CGFloat {
        contentHeight(
            includesCandidateBar: includesCandidateBar,
            screenBounds: screenBounds,
            windowScene: windowScene
        ) + bottomSafeAreaInset()
    }

    static func candidateBarHeight(
        screenBounds: CGRect = UIScreen.main.bounds,
        windowScene: UIWindowScene? = nil
    ) -> CGFloat {
        layoutSpec(screenBounds: screenBounds, windowScene: windowScene).candidateBarHeight
    }

    /// Record a live system-keyboard frame (includes home indicator).
    static func recordSystemKeyboardFrame(_ frame: CGRect) {
        guard frame.height > 160 else { return }
        let safe = bottomSafeAreaInset()
        let content = max(180, frame.height - safe)
        let previous = measuredContentHeight()
        UserDefaults.standard.set(Double(content), forKey: defaultsKey)
        if previous.map({ abs($0 - content) > 0.5 }) ?? true {
            NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        }
    }

    /// Briefly show the system keyboard once to capture this device's exact height.
    /// Safe to call repeatedly; only the first successful probe runs.
    static func ensureMeasured() {
        if measuredContentHeight() != nil { return }
        guard !didScheduleProbe else { return }
        didScheduleProbe = true

        DispatchQueue.main.async {
            guard let window = keyWindow() else {
                didScheduleProbe = false
                return
            }

            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            field.autocorrectionType = .yes
            field.spellCheckingType = .yes
            field.autocapitalizationType = .sentences
            field.keyboardType = .default
            field.alpha = 0.01
            field.isUserInteractionEnabled = false
            window.addSubview(field)
            probeField = field

            probeObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard
                    let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                    frame.height > 160
                else { return }
                recordSystemKeyboardFrame(frame)
                teardownProbe()
            }

            field.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                teardownProbe()
            }
        }
    }

    // MARK: - Private

    private static func measuredContentHeight() -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: defaultsKey)
        return value > 180 ? CGFloat(value) : nil
    }

    private static func teardownProbe() {
        if let observer = probeObserver {
            NotificationCenter.default.removeObserver(observer)
            probeObserver = nil
        }
        probeField?.resignFirstResponder()
        probeField?.removeFromSuperview()
        probeField = nil
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }
}

@MainActor
@Observable
final class KeyboardSizeModel {
    var contentHeight: CGFloat
    var bottomInset: CGFloat
    var deviceClassScale: CGFloat
    var layoutSpec: SystemKeyboardMetrics.LayoutSpec

    var totalDockedHeight: CGFloat { contentHeight + bottomInset }

    init() {
        let bounds = UIScreen.main.bounds
        let spec = SystemKeyboardMetrics.layoutSpec(screenBounds: bounds)
        layoutSpec = spec
        contentHeight = spec.contentHeight
        bottomInset = SystemKeyboardMetrics.bottomSafeAreaInset()
        deviceClassScale = spec.deviceClassScale
        SystemKeyboardMetrics.ensureMeasured()
    }

    func refresh() {
        let bounds = UIScreen.main.bounds
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let spec = SystemKeyboardMetrics.layoutSpec(
            screenBounds: bounds,
            windowScene: scene
        )
        layoutSpec = spec
        contentHeight = spec.contentHeight
        bottomInset = SystemKeyboardMetrics.bottomSafeAreaInset()
        deviceClassScale = spec.deviceClassScale
    }
}
