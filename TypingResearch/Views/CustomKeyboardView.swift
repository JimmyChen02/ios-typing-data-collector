import SwiftUI
import UIKit

// MARK: - CustomKeyboardView

struct CustomKeyboardView: View {
    var overlayMode: Bool = false
    @Binding var showNumeric: Bool
    var onKeyTap: (String, TapInfo) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var kbBg: Color {
        if overlayMode { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.816, green: 0.827, blue: 0.851)
    }

    private let alphaRow0 = ["q","w","e","r","t","y","u","i","o","p"]
    private let alphaRow1 = ["a","s","d","f","g","h","j","k","l"]
    private let alphaRow2 = ["z","x","c","v","b","n","m"]

    private let numRow0  = ["1","2","3","4","5","6","7","8","9","0"]
    private let numRow1  = ["-","/",":",";","(",")","\u{0024}","&","@","\""]
    private let numRow2p = [".",",","?","!","'"]   // punctuation between specials

    private let sidePad:   CGFloat = 5
    private let keyGap:    CGFloat = 6
    private let rowGap:    CGFloat = 11
    private let bottomPad: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let kw: CGFloat = (geo.size.width - 2*sidePad - 9*keyGap) / 10
            let sp: CGFloat = (geo.size.width - 2*sidePad - 7*kw - 8*keyGap) / 2
            // Derive key height so 4 rows fill the available area; clamp to Apple-like proportions.
            let topInset: CGFloat = 8
            let fixedOverhead: CGFloat = 3*rowGap + bottomPad + 38 + topInset  // 38 = globe/mic row
            let rawKeyH = (geo.size.height - fixedOverhead) / 4
            let keyH = min(max(rawKeyH, 38), kw * 1.45)  // floor 38pt, cap so keys never get absurdly tall
            let usedH = 4*keyH + fixedOverhead
            let topPad = max(topInset, geo.size.height - usedH)

            ZStack(alignment: .bottom) {
                // Key rows — aligned to top
                VStack(spacing: rowGap) {
                    if showNumeric {
                        numericRows(geo: geo, kw: kw, sp: sp, keyH: keyH)
                    } else {
                        alphaRows(geo: geo, kw: kw, sp: sp, keyH: keyH)
                    }
                }
                .padding(.horizontal, sidePad)
                .padding(.top, topPad)
                .padding(.bottom, bottomPad)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // Globe & mic anchored to the bottom of the full keyboard frame
                globeMicBar(colorScheme: colorScheme, sidePad: sidePad)
                    .frame(width: geo.size.width)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(kbBg)
        }
    }

    private func globeMicBar(colorScheme: ColorScheme, sidePad: CGFloat) -> some View {
        let iconColor = colorScheme == .dark
            ? Color(white: 0.55)
            : Color(white: 0.45)

        return HStack {
            Image(systemName: "globe")
                .font(.system(size: 23, weight: .light))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 30)

            Spacer()

            Image(systemName: "mic")
                .font(.system(size: 23, weight: .light))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 30)
        }
        .padding(.horizontal, sidePad + 2)
    }

    // MARK: - Alpha layout

    private func alphaRows(geo: GeometryProxy, kw: CGFloat, sp: CGFloat, keyH: CGFloat) -> some View {
        Group {
            // Row 0 — 10 letter keys
            HStack(spacing: keyGap) {
                ForEach(alphaRow0, id: \.self) { k in
                    keyCap(label: k, action: k, width: kw, height: keyH, isSpecial: false)
                }
            }
            // Row 1 — 9 centered letter keys
            HStack(spacing: keyGap) {
                Spacer().frame(width: sp + keyGap)
                ForEach(alphaRow1, id: \.self) { k in
                    keyCap(label: k, action: k, width: kw, height: keyH, isSpecial: false)
                }
                Spacer().frame(width: sp + keyGap)
            }
            // Row 2 — ⇧ + 7 letters + ⌫
            HStack(spacing: keyGap) {
                keyCap(label: "⇧", action: "", width: sp, height: keyH, isSpecial: true)
                ForEach(alphaRow2, id: \.self) { k in
                    keyCap(label: k, action: k, width: kw, height: keyH, isSpecial: false)
                }
                keyCap(label: "⌫", action: "delete", width: sp, height: keyH, isSpecial: true)
            }
            // Row 3 — 123 + space + return
            HStack(spacing: keyGap) {
                keyCap(label: "123", action: "switch_numeric", width: sp, height: keyH, isSpecial: true)
                keyCap(label: "space", action: "space",
                       width: geo.size.width - 2*sidePad - 2*sp - 2*keyGap,
                       height: keyH, isSpecial: false)
                keyCap(label: "return", action: "return", width: sp, height: keyH, isSpecial: true)
            }
        }
    }

    // MARK: - Numeric / punctuation layout

    private func numericRows(geo: GeometryProxy, kw: CGFloat, sp: CGFloat, keyH: CGFloat) -> some View {
        let puncW: CGFloat = (geo.size.width - 2*sidePad - 2*sp - 6*keyGap) / 5
        return Group {
            // Row 0 — digits
            HStack(spacing: keyGap) {
                ForEach(numRow0, id: \.self) { k in
                    keyCap(label: k, action: k, width: kw, height: keyH, isSpecial: false)
                }
            }
            // Row 1 — symbols (10 keys, same widths as digits)
            HStack(spacing: keyGap) {
                ForEach(numRow1, id: \.self) { k in
                    keyCap(label: k, action: k, width: kw, height: keyH, isSpecial: false)
                }
            }
            // Row 2 — [#+=] + 5 punctuation + ⌫
            HStack(spacing: keyGap) {
                keyCap(label: "#+=", action: "", width: sp, height: keyH, isSpecial: true)
                ForEach(numRow2p, id: \.self) { k in
                    keyCap(label: k, action: k, width: puncW, height: keyH, isSpecial: false)
                }
                keyCap(label: "⌫", action: "delete", width: sp, height: keyH, isSpecial: true)
            }
            // Row 3 — ABC + space + return
            HStack(spacing: keyGap) {
                keyCap(label: "ABC", action: "switch_alpha", width: sp, height: keyH, isSpecial: true)
                keyCap(label: "space", action: "space",
                       width: geo.size.width - 2*sidePad - 2*sp - 2*keyGap,
                       height: keyH, isSpecial: false)
                keyCap(label: "return", action: "return", width: sp, height: keyH, isSpecial: true)
            }
        }
    }

    // MARK: - Key factory

    private func keyCap(label: String, action: String, width: CGFloat, height: CGFloat,
                        isSpecial: Bool) -> some View {
        KeyCap(
            label: label,
            action: action,
            width: width,
            height: height,
            isSpecial: isSpecial,
            colorScheme: colorScheme,
            overlayMode: overlayMode
        ) { act, info in
            switch act {
            case "switch_numeric": showNumeric = true
            case "switch_alpha":   showNumeric = false
            case "": break
            default: onKeyTap(act, info)
            }
        }
    }
}

// MARK: - KeyCalloutView

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

// MARK: - KeyCap

private struct KeyCap: View {
    let label: String
    let action: String
    let width: CGFloat
    let height: CGFloat
    let isSpecial: Bool
    let colorScheme: ColorScheme
    let overlayMode: Bool
    let onTap: (String, TapInfo) -> Void

    @State private var isPressed: Bool = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var keyBg: Color {
        let pressed = isPressed && !isSpecial
        if overlayMode {
            if isSpecial {
                return colorScheme == .dark
                    ? Color(white: 0.21, opacity: 0.72)
                    : Color(red: 0.69, green: 0.71, blue: 0.73, opacity: 0.72)
            } else {
                return colorScheme == .dark
                    ? Color(white: pressed ? 0.22 : 0.31, opacity: 0.72)
                    : Color(white: pressed ? 0.82 : 1.0,  opacity: 0.72)
            }
        }
        if isSpecial {
            return colorScheme == .dark
                ? Color(white: 0.21)
                : Color(red: 0.69, green: 0.71, blue: 0.73)
        }
        return colorScheme == .dark
            ? Color(white: pressed ? 0.22 : 0.31)
            : (pressed ? Color(white: 0.82) : .white)
    }

    private var labelColor: Color { colorScheme == .dark ? .white : .black }

    private var labelFont: Font {
        switch label {
        case "space", "123", "ABC", "#+=":
            return .system(size: 16, weight: .regular)
        case "⇧":
            return .system(size: 19, weight: .regular)
        case "return":
            return .system(size: 13, weight: .regular)
        case "⌫":
            return .system(size: 21, weight: .regular)
        default:
            return .system(size: 22, weight: .regular)
        }
    }

    private var keyShape: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(keyBg)
            .shadow(color: Color(white: 0, opacity: overlayMode ? 0.20 : 0.40),
                    radius: 0, x: 0, y: 1)
    }

    private var keyGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                if !isPressed { isPressed = true }
            }
            .onEnded { value in
                isPressed = false
                guard !action.isEmpty else { return }
                let info = TapInfo(
                    keyLabel:  action,
                    tapLocalX: Double(value.location.x),
                    tapLocalY: Double(value.location.y),
                    keyWidth:  Double(width),
                    keyHeight: Double(height)
                )
                onTap(action, info)
            }
    }

    var body: some View {
        Group {
            if label == "return" {
                Image(systemName: "return")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(labelColor)
            } else {
                Text(label)
                    .font(labelFont)
                    .foregroundColor(labelColor)
            }
        }
        .frame(width: width, height: height)
            .background(keyShape)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if isPressed && label.count == 1 && !isSpecial {
                    KeyCalloutView(label: label, keyWidth: width,
                                   keyHeight: height, colorScheme: colorScheme)
                        .offset(y: -KeyCalloutView.totalHeight)
                        .allowsHitTesting(false)
                        .zIndex(100)
                }
            }
            .onAppear { haptic.prepare() }
            .onChange(of: isPressed) { pressed in
                if pressed { haptic.impactOccurred() }
            }
            .gesture(keyGesture)
    }
}
