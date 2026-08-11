import SwiftUI

struct TrialView: View {
    var sessionManager: SessionManager
    var onTrialComplete: () -> Void

    @State private var typedText: String = ""
    @State private var caretUTF16: Int = 0
    @State private var keyboardSize = KeyboardSizeModel()
    @Environment(\.colorScheme) private var colorScheme
    private let showsTapDiagnostics = false

    // D2c — posture camera-preview overlay toggle.
    @State private var showCameraOverlay: Bool = false

    private let textWindowBeforeCursor = 140
    private let textWindowAfterCursor = 260

    private var keyboardHeight: CGFloat {
        keyboardSize.contentHeight
    }

    private var kbBgColor: Color {
        colorScheme == .dark
            ? Color(red: 0.176, green: 0.176, blue: 0.184)
            : Color(red: 0.82, green: 0.835, blue: 0.86)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar

            Spacer().frame(height: 24)

            targetTextView
                .padding(.horizontal, 16)

            if showsTapDiagnostics {
                tapCoordinateBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Spacer()

            // Classic iOS-style keyboard only — Gaussian hit routing removed for now.
            InAppResearchKeyboardView(text: typedText, caretUTF16: $caretUTF16) { edits in
                handleKeyboardEdits(edits)
            }
            .frame(height: keyboardHeight)
        }
        .padding(.top, 16)
        .background(alignment: .bottom) {
            kbBgColor
                .frame(height: keyboardSize.totalDockedHeight)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            if sessionManager.isPostureTrainingRun {
                VStack(alignment: .trailing, spacing: 10) {
                    if showCameraOverlay {
                        CameraPreviewOverlay(sessionManager: sessionManager)
                            .transition(.opacity)
                    }
                    PostureCameraToggleButton(isPresented: $showCameraOverlay)
                }
                .padding(.trailing, 12)
                .padding(.bottom, keyboardHeight + 64)
            }
        }
        .onAppear {
            SystemKeyboardMetrics.ensureMeasured()
            keyboardSize.refresh()
            sessionManager.measuredKeyboardHeight = keyboardSize.totalDockedHeight
            sessionManager.safeAreaBottom = keyboardSize.bottomInset
            sessionManager.startPostureCapture()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            keyboardSize.refresh()
            sessionManager.measuredKeyboardHeight = keyboardSize.totalDockedHeight
            sessionManager.safeAreaBottom = keyboardSize.bottomInset
        }
        .onReceive(
            NotificationCenter.default.publisher(for: SystemKeyboardMetrics.didUpdateNotification)
        ) { _ in
            keyboardSize.refresh()
            sessionManager.measuredKeyboardHeight = keyboardSize.totalDockedHeight
            sessionManager.safeAreaBottom = keyboardSize.bottomInset
        }
        .onDisappear {
            sessionManager.stopPostureCapture()
        }
    }

    // MARK: - Keyboard edit logging

    private func handleKeyboardEdits(_ edits: [InAppKeyboardEdit]) {
        for edit in edits {
            let metadata = metadata(for: edit)
            switch edit.kind {
            case .insert:
                for character in edit.emittedText {
                    recordInsert(String(character), tapInfo: edit.tapInfo, metadata: metadata)
                }
            case .delete:
                for _ in edit.originalText {
                    recordDelete(tapInfo: edit.tapInfo, metadata: metadata)
                }
            case .replace:
                for _ in edit.originalText {
                    recordDelete(tapInfo: edit.tapInfo, metadata: metadata)
                }
                for character in edit.emittedText {
                    recordInsert(String(character), tapInfo: edit.tapInfo, metadata: metadata)
                }
            }
        }
    }

    private func metadata(for edit: InAppKeyboardEdit) -> KeyboardEventMetadata {
        let kind: String
        switch edit.kind {
        case .insert: kind = "insert"
        case .delete: kind = "delete"
        case .replace: kind = "replace"
        }
        let gestureJSON = edit.gesture.flatMap { gesture -> String? in
            guard let data = try? JSONEncoder().encode(gesture) else { return nil }
            return String(data: data, encoding: .utf8)
        } ?? ""
        return KeyboardEventMetadata(
            source: edit.source.rawValue,
            kind: kind,
            originalText: edit.originalText,
            emittedText: edit.emittedText,
            touchGestureJSON: gestureJSON,
            suggestionsOffered: edit.suggestionsOffered.joined(separator: "|"),
            selectedSuggestion: edit.selectedSuggestion ?? ""
        )
    }

    private func recordInsert(
        _ text: String,
        tapInfo: TapInfo,
        metadata: KeyboardEventMetadata
    ) {
        let textBefore = typedText
        let textAfter = textBefore + text
        let rawEvent = sessionManager.captureRawKeyboardEvent(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: text,
            rangeStart: textBefore.count,
            rangeLength: 0,
            eventType: .insert,
            tapInfo: tapInfo,
            editSource: metadata.source,
            editKind: metadata.kind,
            originalText: metadata.originalText,
            emittedText: metadata.emittedText,
            touchGestureJSON: metadata.touchGestureJSON,
            suggestionsOffered: metadata.suggestionsOffered,
            selectedSuggestion: metadata.selectedSuggestion
        )
        sessionManager.captureEvent(rawEvent)
        typedText = textAfter
        caretUTF16 = (textAfter as NSString).length
    }

    private func recordDelete(tapInfo: TapInfo, metadata: KeyboardEventMetadata) {
        guard let deletedCharacter = typedText.last else { return }
        let textBefore = typedText
        let textAfter = String(textBefore.dropLast())
        let rawEvent = sessionManager.captureRawKeyboardEvent(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: "",
            rangeStart: textAfter.count,
            rangeLength: String(deletedCharacter).count,
            eventType: .delete,
            tapInfo: tapInfo,
            editSource: metadata.source,
            editKind: metadata.kind,
            originalText: metadata.originalText,
            emittedText: metadata.emittedText,
            touchGestureJSON: metadata.touchGestureJSON,
            suggestionsOffered: metadata.suggestionsOffered,
            selectedSuggestion: metadata.selectedSuggestion
        )
        sessionManager.captureEvent(rawEvent)
        typedText = textAfter
        caretUTF16 = (textAfter as NSString).length
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.formattedRemaining)
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(sessionManager.remainingSeconds < 30 ? .red : .primary)
                    .monospacedDigit()
                let sessionNum = sessionManager.completedStudySessions + 1
                Text("Session \(sessionNum) of \(sessionManager.totalStudySessions) · Classic")
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
                let lowerBound = max(0, cursorIndex - textWindowBeforeCursor)
                let upperBound = min(targetChars.count, cursorIndex + textWindowAfterCursor)
                let visibleRange = lowerBound..<upperBound
                let scrollTarget = min(cursorIndex, max(0, targetChars.count - 1))

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(visibleRange), id: \.self) { index in
                                let char = targetChars[index]
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
                        if cursorIndex < 24 || cursorIndex % 3 == 0 {
                            proxy.scrollTo(scrollTarget, anchor: .center)
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
            Text("—")
                .frame(width: 40, alignment: .leading)
            Spacer()
            coordCell(label: "local x", value: 0)
            coordCell(label: "local y", value: 0)
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

    private struct KeyboardEventMetadata {
        let source: String
        let kind: String
        let originalText: String
        let emittedText: String
        let touchGestureJSON: String
        let suggestionsOffered: String
        let selectedSuggestion: String
    }
}
