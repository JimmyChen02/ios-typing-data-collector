import SwiftUI
import UIKit

// MARK: - GaussianKeyboardView
//
// Visually matches CustomKeyboardView but replaces per-key gestures with a
// single UIViewRepresentable touch overlay. Letter-key hits are routed through
// the GaussianKeyModel (Mahalanobis argmax + anchor protection). Special keys
// (⌫, space, return, ⇧, 123) fall back to strict frame hit-testing.
//
// Using UIView.touchesBegan instead of DragGesture eliminates the gesture
// recognizer cascade delay and avoids blocking subsequent touch delivery
// with in-flight SwiftUI re-renders.

// MARK: - Touch Overlay (UIViewRepresentable)

private struct KeyboardTouchOverlay: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onRelease: () -> Void

    func makeUIView(context: Context) -> TouchOverlayView {
        let v = TouchOverlayView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        v.onTap = onTap
        v.onRelease = onRelease
        return v
    }

    func updateUIView(_ uiView: TouchOverlayView, context: Context) {
        uiView.onTap = onTap
        uiView.onRelease = onRelease
    }
}

private class TouchOverlayView: UIView {
    var onTap: ((CGPoint) -> Void)?
    var onRelease: (() -> Void)?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        haptic.prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        haptic.prepare()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Dispatch every touch: fast two-thumb typing overlaps touches, and
        // any touch that begins while another is still down must still count.
        for touch in touches {
            onTap?(touch.location(in: self))
        }
        // Haptic fires after dispatch so it never delays key delivery.
        haptic.impactOccurred()
        haptic.prepare()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, with: event)
    }

    // Clear the pressed-key visual only when no finger remains on the
    // keyboard, so an overlapping second press keeps its highlight.
    private func endTouches(_ touches: Set<UITouch>, with event: UIEvent?) {
        let stillActive = (event?.allTouches ?? touches).contains {
            $0.phase != .ended && $0.phase != .cancelled
        }
        if !stillActive {
            onRelease?()
        }
    }
}

// MARK: - Key Callout

private struct KeyCalloutView: View {
    let label: String
    let keyWidth: CGFloat
    let keyHeight: CGFloat
    let colorScheme: ColorScheme

    private static let bubbleH: CGFloat = 54
    private static let stemH:   CGFloat = 16
    private static let overlap: CGFloat = 4
    static  let totalHeight:    CGFloat = bubbleH + stemH - overlap

    private var bubbleW: CGFloat { max(44, keyWidth) }
    private var stemW:   CGFloat { min(keyWidth, 28) }
    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.31) : .white
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5)
                .fill(bgColor)
                .frame(width: stemW, height: Self.stemH)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(bgColor)
                    .shadow(color: Color(white: 0, opacity: 0.18), radius: 8, x: 0, y: 4)
                Text(label)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(colorScheme == .dark ? .white : .black)
            }
            .frame(width: bubbleW, height: Self.bubbleH)
            .offset(y: -(Self.stemH - Self.overlap))
        }
        .frame(width: max(bubbleW, stemW), height: Self.totalHeight)
    }
}

// MARK: - GaussianKeyboardView

struct GaussianKeyboardView: View {
    var overlayMode: Bool = false
    @Binding var showNumeric: Bool
    var model: GaussianKeyModel
    var onKeyTap: (String, TapInfo) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var pressedKey: String? = nil
    @State private var pressedRect: CGRect? = nil

    static let fittableKeys: [String] = [
        "q","w","e","r","t","y","u","i","o","p",
        "a","s","d","f","g","h","j","k","l",
        "z","x","c","v","b","n","m"
    ]

    private let alphaRow0 = ["q","w","e","r","t","y","u","i","o","p"]
    private let alphaRow1 = ["a","s","d","f","g","h","j","k","l"]
    private let alphaRow2 = ["z","x","c","v","b","n","m"]

    private let numRow0  = ["1","2","3","4","5","6","7","8","9","0"]
    private let numRow1  = ["-","/",":",";","(",")","\u{0024}","&","@","\""]
    private let numRow2p = [".",",","?","!","'"]

    private let sidePad:   CGFloat = 5
    private let keyGap:    CGFloat = 6
    private let rowGap:    CGFloat = 11
    private let bottomPad: CGFloat = 3

    private var kbBg: Color {
        if overlayMode { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.816, green: 0.827, blue: 0.851)
    }

    // Actions whose keycaps never show a pressed background (matches the
    // isSpecial styling in KeyboardVisualLayer).
    private static let nonHighlightKeys: Set<String> = ["delete", "return", "123", "ABC", "#+="]

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(size: geo.size)
            ZStack {
                // Static keycaps live in an Equatable child view so per-tap
                // pressedKey changes don't re-render the whole keyboard.
                KeyboardVisualLayer(layout: layout,
                                    overlayMode: overlayMode,
                                    colorScheme: colorScheme)
                    .equatable()

                KeyboardTouchOverlay { [layout] point in
                    dispatchTap(at: point, layout: layout)
                } onRelease: {
                    pressedKey = nil
                    pressedRect = nil
                }

                // Pressed-key highlight drawn as a lightweight overlay on top
                // of the static layer (replaces the per-keycap bg change).
                if let pk = pressedKey, let pr = pressedRect,
                   !Self.nonHighlightKeys.contains(pk) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(colorScheme == .dark
                                  ? Color(white: 0.22)
                                  : Color(white: 0.82))
                        Text(pk)
                            .font(keyFont(for: pk))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                    }
                    .frame(width: pr.width, height: pr.height)
                    .position(x: pr.midX, y: pr.midY)
                    .allowsHitTesting(false)
                }

                // Callout bubble rendered above everything, no hit-testing
                if let pk = pressedKey, pk.count == 1, let pr = pressedRect {
                    KeyCalloutView(label: pk, keyWidth: pr.width,
                                   keyHeight: pr.height, colorScheme: colorScheme)
                        .position(x: pr.midX,
                                  y: pr.minY - KeyCalloutView.totalHeight / 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(kbBg)
        }
    }

    // MARK: - Dispatch

    private func dispatchTap(at point: CGPoint, layout: KeyboardLayout) {
        for (action, rect) in layout.specialFrames {
            if rect.contains(point) {
                switch action {
                case "switch_numeric":
                    pressedKey = "123"; pressedRect = rect; showNumeric = true
                case "switch_alpha":
                    pressedKey = "ABC"; pressedRect = rect; showNumeric = false
                case "": return
                default:
                    emit(action: action, at: point, rect: rect)
                }
                return
            }
        }

        if let sp = layout.spaceFrame, sp.contains(point) {
            emit(action: "space", at: point, rect: sp)
            return
        }

        let letterFrames = layout.letterFrames
        if letterFrames.isEmpty { return }

        let frameList = letterFrames.map { (key: $0.key, rect: $0.value) }
        if let winner = model.winner(at: point, frames: frameList),
           let rect = letterFrames[winner] {
            emit(action: winner, at: point, rect: rect)
        }
    }

    private func emit(action: String, at point: CGPoint, rect: CGRect) {
        pressedKey = action
        pressedRect = rect
        let lx = min(max(point.x - rect.minX, 0), rect.width)
        let ly = min(max(point.y - rect.minY, 0), rect.height)
        let info = TapInfo(
            keyLabel:  action,
            tapLocalX: Double(lx),
            tapLocalY: Double(ly),
            keyWidth:  Double(rect.width),
            keyHeight: Double(rect.height)
        )
        onKeyTap(action, info)
    }

    // MARK: - Layout

    private func computeLayout(size: CGSize) -> KeyboardLayout {
        let kw: CGFloat = (size.width - 2 * sidePad - 9 * keyGap) / 10
        let sp: CGFloat = (size.width - 2 * sidePad - 7 * kw - 8 * keyGap) / 2
        // Derive key height so 4 rows fill the available area; clamp to Apple-like proportions.
        let topInset: CGFloat = 8
        let fixedOverhead: CGFloat = 3 * rowGap + bottomPad + 38 + topInset  // 38 = globe/mic row
        let rawKeyH = (size.height - fixedOverhead) / 4
        let keyH = min(max(rawKeyH, 38), kw * 1.45)  // floor 38pt, cap so keys never get absurdly tall
        let usedH = 4 * keyH + fixedOverhead
        let topPad = max(topInset, size.height - usedH)

        var layout = KeyboardLayout()

        let row0 = showNumeric ? numRow0 : alphaRow0
        let row1 = showNumeric ? numRow1 : alphaRow1
        let row2Inner = showNumeric ? numRow2p : alphaRow2
        let row2LeftLabel  = showNumeric ? "#+=" : "\u{21E7}"
        let switchLabel    = showNumeric ? "ABC" : "123"
        let switchAction   = showNumeric ? "switch_alpha" : "switch_numeric"
        let row2LeftAction = showNumeric ? "" : ""

        let y0 = topPad
        var x = sidePad
        for k in row0 {
            layout.letterFrames[k] = CGRect(x: x, y: y0, width: kw, height: keyH)
            x += kw + keyGap
        }

        let y1 = y0 + keyH + rowGap
        if showNumeric {
            x = sidePad
            for k in row1 {
                layout.letterFrames[k] = CGRect(x: x, y: y1, width: kw, height: keyH)
                x += kw + keyGap
            }
        } else {
            let row1W = CGFloat(row1.count) * kw + CGFloat(row1.count - 1) * keyGap
            x = (size.width - row1W) / 2
            for k in row1 {
                layout.letterFrames[k] = CGRect(x: x, y: y1, width: kw, height: keyH)
                x += kw + keyGap
            }
        }

        let y2 = y1 + keyH + rowGap
        x = sidePad
        layout.specialList.append(SpecialKey(
            id: "row2Left", label: row2LeftLabel, action: row2LeftAction,
            rect: CGRect(x: x, y: y2, width: sp, height: keyH)
        ))
        x += sp + keyGap
        if showNumeric {
            let puncW: CGFloat = (size.width - 2 * sidePad - 2 * sp - 6 * keyGap) / 5
            for k in row2Inner {
                layout.letterFrames[k] = CGRect(x: x, y: y2, width: puncW, height: keyH)
                x += puncW + keyGap
            }
        } else {
            for k in row2Inner {
                layout.letterFrames[k] = CGRect(x: x, y: y2, width: kw, height: keyH)
                x += kw + keyGap
            }
        }
        layout.specialList.append(SpecialKey(
            id: "delete", label: "\u{232B}", action: "delete",
            rect: CGRect(x: size.width - sidePad - sp, y: y2, width: sp, height: keyH)
        ))

        let y3 = y2 + keyH + rowGap
        layout.specialList.append(SpecialKey(
            id: "switch", label: switchLabel, action: switchAction,
            rect: CGRect(x: sidePad, y: y3, width: sp, height: keyH)
        ))
        let spaceX = sidePad + sp + keyGap
        let spaceW = size.width - 2 * sidePad - 2 * sp - 2 * keyGap
        layout.spaceFrame = CGRect(x: spaceX, y: y3, width: spaceW, height: keyH)
        layout.specialList.append(SpecialKey(
            id: "return", label: "return", action: "return",
            rect: CGRect(x: size.width - sidePad - sp, y: y3, width: sp, height: keyH)
        ))

        for s in layout.specialList { layout.specialFrames[s.action] = s.rect }
        return layout
    }
}

// MARK: - Visual Layer
//
// Static keycaps only — no pressed state. Equatable so SwiftUI skips its
// body when the layout hasn't changed, which means a keystroke (pressedKey
// change in the parent) re-renders only the small highlight/callout overlay
// instead of all ~30 shadowed keycaps twice per tap.

private struct KeyboardVisualLayer: View, Equatable {
    let layout: KeyboardLayout
    let overlayMode: Bool
    let colorScheme: ColorScheme

    static func == (lhs: KeyboardVisualLayer, rhs: KeyboardVisualLayer) -> Bool {
        lhs.overlayMode == rhs.overlayMode
            && lhs.colorScheme == rhs.colorScheme
            && lhs.layout == rhs.layout
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.specialList) { s in
                keyCap(label: s.label, rect: s.rect, isSpecial: true)
            }
            if let sp = layout.spaceFrame {
                keyCap(label: "space", rect: sp, isSpecial: false)
            }
            ForEach(Array(layout.letterFrames.keys.sorted()), id: \.self) { key in
                if let rect = layout.letterFrames[key] {
                    keyCap(label: key, rect: rect, isSpecial: false)
                }
            }
        }
    }

    private func keyCap(label: String, rect: CGRect, isSpecial: Bool) -> some View {
        let bg: Color = {
            if isSpecial {
                return colorScheme == .dark
                    ? Color(white: 0.21)
                    : Color(red: 0.69, green: 0.71, blue: 0.73)
            }
            return colorScheme == .dark ? Color(white: 0.31) : .white
        }()
        let labelColor: Color = colorScheme == .dark ? .white : .black

        return Group {
            if label == "return" {
                Image(systemName: "return")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(labelColor)
            } else {
                Text(label)
                    .font(keyFont(for: label))
                    .foregroundColor(labelColor)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(bg)
                .shadow(color: Color(white: 0, opacity: overlayMode ? 0.20 : 0.40),
                        radius: 0, x: 0, y: 1)
        )
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}

fileprivate func keyFont(for label: String) -> Font {
    switch label {
    case "space", "123", "ABC", "#+=":
        return .system(size: 16, weight: .regular)
    case "\u{21E7}":  // ⇧
        return .system(size: 19, weight: .regular)
    case "\u{232B}":  // ⌫
        return .system(size: 21, weight: .regular)
    default:
        return .system(size: 22, weight: .regular)
    }
}

// MARK: - Layout Model

private struct KeyboardLayout: Equatable {
    var letterFrames: [String: CGRect] = [:]
    var spaceFrame: CGRect? = nil
    var specialList: [SpecialKey] = []
    var specialFrames: [String: CGRect] = [:]
}

private struct SpecialKey: Identifiable, Equatable {
    let id: String
    let label: String
    let action: String
    let rect: CGRect
}

// MARK: - Ellipse Overlay

private struct EllipseOverlay: View {
    let rect: CGRect
    let gaussian: Gaussian2D
    let color: Color

    var body: some View {
        let e = GaussianKeyModel.ellipse(for: gaussian, keyFrame: rect)
        return ZStack {
            Ellipse()
                .stroke(color.opacity(0.30), lineWidth: 0.8)
                .frame(width: e.semiA * 4, height: e.semiB * 4)
                .rotationEffect(.radians(e.angle))
                .position(x: e.center.x, y: e.center.y)
            Ellipse()
                .stroke(color.opacity(0.75), lineWidth: 1.2)
                .frame(width: e.semiA * 2, height: e.semiB * 2)
                .rotationEffect(.radians(e.angle))
                .position(x: e.center.x, y: e.center.y)
        }
        .allowsHitTesting(false)
    }
}
