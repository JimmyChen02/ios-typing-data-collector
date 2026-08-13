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

            freeTypingView
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
            .frame(height: keyboardSize.totalDockedHeight)
        }
        .padding(.top, 16)
        .ignoresSafeArea(edges: .bottom)
        .background(alignment: .bottom) {
            kbBgColor
                .frame(height: keyboardSize.totalDockedHeight)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if showCameraOverlay {
                    CameraPreviewOverlay(sessionManager: sessionManager)
                        .transition(.opacity)
                }
                HStack(spacing: 8) {
                    Label("Camera on", systemImage: "camera.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                    if sessionManager.studyRole == .researcher {
                        PostureCameraToggleButton(isPresented: $showCameraOverlay)
                    }
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, keyboardSize.totalDockedHeight + 64)
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
            applyEditAtCaret(edit, metadata: metadata(for: edit))
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

    private func applyEditAtCaret(_ edit: InAppKeyboardEdit, metadata: KeyboardEventMetadata) {
        let ns = typedText as NSString
        let caret = max(0, min(caretUTF16, ns.length))
        let textBefore = typedText
        let textAfter: String
        let rangeStart: Int
        let rangeLength: Int
        let eventType: InputEventType
        let replacement: String

        switch edit.kind {
        case .insert:
            rangeStart = caret
            rangeLength = 0
            replacement = edit.emittedText
            textAfter = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: edit.emittedText)
            caretUTF16 = caret + (edit.emittedText as NSString).length
            eventType = .insert
        case .delete:
            let delLen = (edit.originalText as NSString).length
            guard caret >= delLen, delLen > 0 else { return }
            let loc = caret - delLen
            rangeStart = loc
            rangeLength = delLen
            replacement = ""
            textAfter = ns.replacingCharacters(in: NSRange(location: loc, length: delLen), with: "")
            caretUTF16 = loc
            eventType = .delete
        case .replace:
            let origLen = (edit.originalText as NSString).length
            let loc = max(0, caret - min(origLen, caret))
            rangeStart = loc
            rangeLength = caret - loc
            replacement = edit.emittedText
            textAfter = ns.replacingCharacters(
                in: NSRange(location: loc, length: caret - loc),
                with: edit.emittedText
            )
            caretUTF16 = loc + (edit.emittedText as NSString).length
            eventType = .replace
        }

        let rawEvent = sessionManager.captureRawKeyboardEvent(
            textBefore: textBefore,
            textAfter: textAfter,
            replacementString: replacement,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            eventType: eventType,
            tapInfo: edit.tapInfo,
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
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.formattedRemaining)
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(sessionManager.remainingSeconds < 30 ? .red : .primary)
                    .monospacedDigit()
                let modeLabel = sessionManager.currentSessionMode == .gaussian ? "Adaptive" : "Classic"
                Text("\(sessionManager.currentStudyPhase.rawValue) · Session \(sessionManager.currentPhaseSessionNumber) of \(sessionManager.currentPhaseTotalSessions) · \(modeLabel)")
                    .font(.caption).foregroundColor(.secondary)
                Text("Posture: \(sessionManager.currentAssignedPosture.displayName)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Topic: \(sessionManager.currentSessionTopic.rawValue)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

    // MARK: - Free Typing View

    private var freeTypingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free typing")
                .font(.caption)
                .foregroundColor(.secondary)
            AnnotatedTypingCanvas(
                text: $typedText,
                caretUTF16: $caretUTF16,
                revertible: nil,
                placeholder: "Start typing freely about the selected topic..."
            ) { _ in }
            .frame(minHeight: 180, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
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
