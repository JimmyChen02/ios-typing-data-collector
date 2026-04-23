import SwiftUI
import UIKit

// MARK: - GaussianKeyboardView
//
// Visually matches CustomKeyboardView but replaces per-key gestures with a
// single unified drag gesture. Letter-key hits are routed through the
// GaussianKeyModel (Mahalanobis argmax + anchor protection). Special keys
// (⌫, space, return, ⇧, 123) fall back to strict frame hit-testing.
//
// The fitted Gaussian boundaries are drawn as translucent 1σ ellipses behind
// the letter keys so the user can see which region currently maps to each
// key.

struct GaussianKeyboardView: View {
    var overlayMode: Bool = false
    @Binding var showNumeric: Bool
    var model: GaussianKeyModel
    var onKeyTap: (String, TapInfo) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var didDispatchCurrentTouch = false

    // Keys the Gaussian model fits. Matches the alpha layout — special
    // keys (space, delete, shift, …) are routed via strict frame tests,
    // so they don't need per-key Gaussians.
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
    private let keyH:      CGFloat = 42

    private var kbBg: Color {
        if overlayMode { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.816, green: 0.827, blue: 0.851)
    }

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(size: geo.size)
            ZStack {
                // Static visual layer
                keyboardVisual(layout: layout)

                // Unified gesture catcher on top — forwards the tap to the
                // Gaussian classifier (letters) or strict hit-test (specials).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(unifiedGesture(layout: layout))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(kbBg)
        }
    }

    // MARK: - Gesture

    private func unifiedGesture(layout: KeyboardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !didDispatchCurrentTouch else { return }
                didDispatchCurrentTouch = true
                dispatchTap(at: value.location, layout: layout)
            }
            .onEnded { value in
                if !didDispatchCurrentTouch {
                    dispatchTap(at: value.location, layout: layout)
                }
                didDispatchCurrentTouch = false
            }
    }

    private func dispatchTap(at point: CGPoint, layout: KeyboardLayout) {
        // Specials first (⇧ and the label-only #+= have action "" — ignored)
        for (action, rect) in layout.specialFrames {
            if rect.contains(point) {
                switch action {
                case "switch_numeric": showNumeric = true
                case "switch_alpha":   showNumeric = false
                case "": return
                default:
                    emit(action: action, at: point, rect: rect)
                }
                return
            }
        }

        // Space is a special frame too — strict frame test (no Gaussian)
        if let sp = layout.spaceFrame, sp.contains(point) {
            emit(action: "space", at: point, rect: sp)
            return
        }

        // Letters: Gaussian classifier on the alpha/numeric letter frames
        let letterFrames = layout.letterFrames
        if letterFrames.isEmpty { return }

        let frameList = letterFrames.map { (key: $0.key, rect: $0.value) }
        if let winner = model.winner(at: point, frames: frameList),
           let rect = letterFrames[winner] {
            emit(action: winner, at: point, rect: rect)
        }
    }

    private func emit(action: String, at point: CGPoint, rect: CGRect) {
        // Clamp local coords into the rect — taps can land just outside
        // the visible key if the Gaussian tail stretches across gaps.
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

    // MARK: - Visual Layer

    @ViewBuilder
    private func keyboardVisual(layout: KeyboardLayout) -> some View {
        ZStack(alignment: .topLeading) {
            // Special keys (⇧, ⌫, 123/#+=/ABC, return)
            ForEach(layout.specialList) { s in
                keyCap(label: s.label, rect: s.rect, isSpecial: true)
            }

            // Space
            if let sp = layout.spaceFrame {
                keyCap(label: "space", rect: sp, isSpecial: false)
            }

            // Letter keys
            ForEach(Array(layout.letterFrames.keys.sorted()), id: \.self) { key in
                if let rect = layout.letterFrames[key] {
                    keyCap(label: displayLabel(for: key), rect: rect,
                           isSpecial: false)
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
                    .font(fontFor(label: label))
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
        .allowsHitTesting(false)   // the ZStack gesture catcher handles all input
    }

    private func fontFor(label: String) -> Font {
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

    private func displayLabel(for key: String) -> String { key }

    private func tintColor(for key: String) -> Color {
        let allKeys = ["q","w","e","r","t","y","u","i","o","p",
                       "a","s","d","f","g","h","j","k","l",
                       "z","x","c","v","b","n","m"]
        let idx = Double(allKeys.firstIndex(of: key) ?? 0)
        let hue = (idx * 0.618033988749895).truncatingRemainder(dividingBy: 1.0)
        return Color(hue: hue, saturation: 0.72, brightness: 0.88)
    }

    // MARK: - Layout

    private func computeLayout(size: CGSize) -> KeyboardLayout {
        let kw: CGFloat = (size.width - 2 * sidePad - 9 * keyGap) / 10
        let sp: CGFloat = (size.width - 2 * sidePad - 7 * kw - 8 * keyGap) / 2
        let usedH: CGFloat = 4 * keyH + 3 * rowGap + bottomPad + 38
        let topPad: CGFloat = max(8, size.height - usedH)

        var layout = KeyboardLayout()

        let row0 = showNumeric ? numRow0 : alphaRow0
        let row1 = showNumeric ? numRow1 : alphaRow1
        let row2Inner = showNumeric ? numRow2p : alphaRow2
        let row2LeftLabel = showNumeric ? "#+=" : "\u{21E7}"   // ⇧
        let switchLabel   = showNumeric ? "ABC" : "123"
        let switchAction  = showNumeric ? "switch_alpha" : "switch_numeric"
        let row2LeftAction = showNumeric ? "" : ""            // both modeless

        // Row 0
        let y0 = topPad
        var x = sidePad
        for k in row0 {
            layout.letterFrames[k] = CGRect(x: x, y: y0, width: kw, height: keyH)
            x += kw + keyGap
        }

        // Row 1
        let y1 = y0 + keyH + rowGap
        if showNumeric {
            x = sidePad
            for k in row1 {
                layout.letterFrames[k] = CGRect(x: x, y: y1, width: kw, height: keyH)
                x += kw + keyGap
            }
        } else {
            // 9 centered keys
            let row1W = CGFloat(row1.count) * kw + CGFloat(row1.count - 1) * keyGap
            x = (size.width - row1W) / 2
            for k in row1 {
                layout.letterFrames[k] = CGRect(x: x, y: y1, width: kw, height: keyH)
                x += kw + keyGap
            }
        }

        // Row 2: ⇧/#+= + letters/punct + ⌫
        let y2 = y1 + keyH + rowGap
        x = sidePad
        layout.specialList.append(SpecialKey(
            id: "row2Left",
            label: row2LeftLabel,
            action: row2LeftAction,
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
            id: "delete",
            label: "\u{232B}",
            action: "delete",
            rect: CGRect(x: size.width - sidePad - sp, y: y2, width: sp, height: keyH)
        ))

        // Row 3: switch + space + return
        let y3 = y2 + keyH + rowGap
        layout.specialList.append(SpecialKey(
            id: "switch",
            label: switchLabel,
            action: switchAction,
            rect: CGRect(x: sidePad, y: y3, width: sp, height: keyH)
        ))
        let spaceX = sidePad + sp + keyGap
        let spaceW = size.width - 2 * sidePad - 2 * sp - 2 * keyGap
        layout.spaceFrame = CGRect(x: spaceX, y: y3, width: spaceW, height: keyH)
        layout.specialList.append(SpecialKey(
            id: "return",
            label: "return",
            action: "return",
            rect: CGRect(x: size.width - sidePad - sp, y: y3, width: sp, height: keyH)
        ))

        for s in layout.specialList { layout.specialFrames[s.action] = s.rect }
        return layout
    }
}

// MARK: - Layout Model

private struct KeyboardLayout {
    var letterFrames: [String: CGRect] = [:]
    var spaceFrame: CGRect? = nil
    var specialList: [SpecialKey] = []
    var specialFrames: [String: CGRect] = [:]   // keyed by action
}

private struct SpecialKey: Identifiable {
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
            // 2σ translucent
            Ellipse()
                .stroke(color.opacity(0.30), lineWidth: 0.8)
                .frame(width: e.semiA * 4, height: e.semiB * 4)
                .rotationEffect(.radians(e.angle))
                .position(x: e.center.x, y: e.center.y)
            // 1σ
            Ellipse()
                .stroke(color.opacity(0.75), lineWidth: 1.2)
                .frame(width: e.semiA * 2, height: e.semiB * 2)
                .rotationEffect(.radians(e.angle))
                .position(x: e.center.x, y: e.center.y)
        }
        .allowsHitTesting(false)
    }
}
