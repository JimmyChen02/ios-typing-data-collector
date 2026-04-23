import SwiftUI

struct TrialView: View {
    var sessionManager: SessionManager
    var onTrialComplete: () -> Void

    @State private var typedText: String = ""
    @State private var lastTapInfo: TapInfo = .none
    @State private var showNumericKeyboard: Bool = false
    @State private var gaussianModel: GaussianKeyModel = GaussianKeyModel()
    @Environment(\.colorScheme) private var colorScheme

    // Mirror CustomKeyboardView layout constants so the buffer strip maps taps correctly
    private let kbSidePad: CGFloat = 5
    private let kbKeyGap:  CGFloat = 6
    private let kbBufH:    CGFloat = 8
    private let alphaTop = ["q","w","e","r","t","y","u","i","o","p"]
    private let numTop   = ["1","2","3","4","5","6","7","8","9","0"]

    private var keyboardHeight: CGFloat {
        max(180, sessionManager.measuredKeyboardHeight - sessionManager.safeAreaBottom)
    }

    private var kbBgColor: Color {
        colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.816, green: 0.827, blue: 0.851)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar

            Spacer().frame(height: 24)

            targetTextView
                .padding(.horizontal, 16)

            tapCoordinateBar
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()

            // Buffer strip: same keyboard background color, forwards taps to nearest top-row key
            bufferStrip

            Group {
                if sessionManager.sessionMode == .gaussian {
                    GaussianKeyboardView(
                        overlayMode: false,
                        showNumeric: $showNumericKeyboard,
                        model: gaussianModel
                    ) { key, tapInfo in
                        handleKeyTap(key: key, tapInfo: tapInfo)
                    }
                } else {
                    CustomKeyboardView(overlayMode: false, showNumeric: $showNumericKeyboard) { key, tapInfo in
                        handleKeyTap(key: key, tapInfo: tapInfo)
                    }
                }
            }
            .frame(height: keyboardHeight)
        }
        .padding(.top, 16)
        .background(alignment: .bottom) {
            kbBgColor
                .frame(height: keyboardHeight + kbBufH + sessionManager.safeAreaBottom)
                .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            if sessionManager.sessionMode == .gaussian {
                gaussianModel = GaussianModelStore.shared.loadModel(
                    keys: GaussianKeyboardView.fittableKeys
                )
            }
        }
    }

    // MARK: - Key Tap Handler

    private func handleKeyTap(key: String, tapInfo: TapInfo) {
        let textBefore = typedText
        let textAfter: String
        let replacementString: String
        let eventType: InputEventType
        let rangeStart: Int
        let rangeLength: Int

        switch key {
        case "delete":
            guard !textBefore.isEmpty else { return }
            textAfter = String(textBefore.dropLast())
            replacementString = ""
            eventType = .delete
            rangeStart = textAfter.count
            rangeLength = 1
        case "space", "return":
            textAfter = textBefore + " "
            replacementString = " "
            eventType = .insert
            rangeStart = textBefore.count
            rangeLength = 0
            if showNumericKeyboard { showNumericKeyboard = false }
        default:
            textAfter = textBefore + key
            replacementString = key
            eventType = .insert
            rangeStart = textBefore.count
            rangeLength = 0
        }

        let eventData = sessionManager.buildKeyboardEventData(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: replacementString,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            eventType: eventType,
            tapInfo: tapInfo
        )
        sessionManager.logEvent(eventData)
        typedText = textAfter
        lastTapInfo = tapInfo
    }

    // MARK: - Buffer Strip

    private var bufferStrip: some View {
        GeometryReader { geo in
            let globalFrame = geo.frame(in: .global)
            bufferStripContent(width: geo.size.width, globalFrame: globalFrame)
        }
        .frame(height: kbBufH)
    }

    private func bufferStripContent(width: CGFloat, globalFrame: CGRect) -> some View {
        let kw   = (width - 2*kbSidePad - 9*kbKeyGap) / 10
        let step = kw + kbKeyGap
        // Approximate key height from keyboard frame (5 rows share available height)
        let keyH = max(34, (keyboardHeight - 3 * 11) / 5)
        return kbBgColor
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded { value in
                        let row    = showNumericKeyboard ? numTop : alphaTop
                        let x      = value.location.x - kbSidePad
                        let idx    = max(0, min(Int(x / step), row.count - 1))
                        let localX = min(max(x - CGFloat(idx) * step, 0), kw)
                        let tapInfo = TapInfo(
                            keyLabel:  row[idx],
                            tapLocalX: Double(localX),
                            tapLocalY: Double(value.location.y),
                            keyWidth:  Double(kw),
                            keyHeight: Double(keyH)
                        )
                        handleKeyTap(key: row[idx], tapInfo: tapInfo)
                    }
            )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.formattedRemaining)
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(sessionManager.remainingSeconds < 30 ? .red : .primary)
                    .monospacedDigit()
                let modeLabel = sessionManager.sessionMode == .gaussian ? "Adaptive" : "Classic"
                let sessionNum = sessionManager.completedStudySessions + 1
                Text("Session \(sessionNum) of \(sessionManager.totalStudySessions) · \(modeLabel)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                if sessionManager.isTrialActive {
                    sessionManager.submitTrial(finalText: typedText)
                }
                sessionManager.finalizeSession()
            } label: {
                Text("End Session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.18))
                    )
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f WPM", sessionManager.liveWPM))
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(.secondary).monospacedDigit()
                Text("live speed")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(height: 4)
                let progress = sessionManager.sessionDurationSeconds > 0
                    ? CGFloat(sessionManager.remainingSeconds) / CGFloat(sessionManager.sessionDurationSeconds)
                    : 0
                Rectangle()
                    .fill(sessionManager.remainingSeconds < 30 ? Color.red : Color.orange)
                    .frame(width: geo.size.width * progress, height: 4)
                    .animation(.linear(duration: 1), value: sessionManager.remainingSeconds)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Target Text View

    private var targetTextView: some View {
        Group {
            if let trial = sessionManager.currentTrial {
                let targetChars = Array(trial.targetText)
                let typedChars  = Array(typedText)
                let cursorIndex = typedChars.count

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(targetChars.enumerated()), id: \.offset) { index, char in
                                let isWrongSpace = char == " " && index < cursorIndex && typedChars[index] != char
                                Text(isWrongSpace ? "·" : String(char))
                                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                                    .foregroundColor(charColor(index: index, typedCount: cursorIndex, targetChar: char, typedChars: typedChars))
                                    .underline(index == cursorIndex)
                                    .background(index == cursorIndex ? Color.orange.opacity(0.25) : Color.clear)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .onChange(of: typedText) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(cursorIndex, anchor: .center)
                        }
                    }
                }
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
            }
        }
    }

    private func charColor(index: Int, typedCount: Int, targetChar: Character, typedChars: [Character]) -> Color {
        if index < typedCount {
            return typedChars[index] == targetChar ? .green : .red
        }
        if index == typedCount { return .primary }
        return .primary.opacity(0.35)
    }

    // MARK: - Tap Coordinate Bar

    private var tapCoordinateBar: some View {
        HStack(spacing: 0) {
            Text(lastTapInfo.keyLabel.isEmpty ? "—" : "[\(lastTapInfo.keyLabel)]")
                .frame(width: 40, alignment: .leading)
            Spacer()
            coordCell(label: "local x", value: lastTapInfo.tapLocalX)
            coordCell(label: "local y", value: lastTapInfo.tapLocalY)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }

    private func coordCell(label: String, value: Double, decimals: Int = 1) -> some View {
        VStack(spacing: 1) {
            Text(String(format: decimals == 3 ? "%.3f" : "%.1f", value))
                .fontWeight(.medium).foregroundColor(.primary)
            Text(label).font(.system(size: 9, design: .monospaced))
        }
        .frame(minWidth: 52)
    }
}