import SwiftUI
import SwiftData

// Free Writing Mode's full flow: start -> typing -> complete. Presented as a
// .fullScreenCover from ParticipantSetupView, which has already called
// sessionManager.startFreeWriting(participant:) before this view appears
// (Session/Trial + prompt are already set up).
struct FreeWritingView: View {
    var sessionManager: SessionManager

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case start
        case typing
        case complete
    }

    @State private var phase: Phase = .start
    @State private var typedText: String = ""
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        Group {
            switch phase {
            case .start:
                startScreen
            case .typing:
                typingScreen
            case .complete:
                completeScreen
            }
        }
        // The 3-minute timer expiry sets isFreeWritingComplete from inside
        // SessionManager (timeExpired() -> finalizeFreeWriting()); watch it
        // here to advance typing -> complete even if the user never taps
        // "End Early".
        .onChange(of: sessionManager.isFreeWritingComplete) { _, isComplete in
            if isComplete {
                phase = .complete
            }
        }
    }

    // MARK: - Start Screen

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Free Writing Mode")
                .font(.title2)
                .fontWeight(.bold)

            Text(sessionManager.freeWritingPrompt)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("You'll have 3 minutes. Just write whatever comes to mind.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: { sessionManager.reshuffleFreeWritingPrompt() }) {
                Label("Shuffle Prompt", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)

            Button(action: startWriting) {
                Text("Start Writing")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)

            Button(role: .cancel, action: cancel) {
                Text("Cancel")
                    .foregroundColor(.red)
            }

            Spacer()
        }
    }

    private func startWriting() {
        typedText = sessionManager.liveTypedText
        phase = .typing
    }

    private func cancel() {
        dismiss()
        sessionManager.resetFreeWriting()
    }

    // MARK: - Typing Screen

    private var typingScreen: some View {
        VStack(spacing: 0) {
            topBar

            Text(sessionManager.freeWritingPrompt)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            FreeWritingTextView(text: $typedText) { textBefore, textAfter, replacementString, rangeStart, rangeLength, eventType in
                sessionManager.captureFreeWritingEvent(
                    textBefore: textBefore,
                    textAfter: textAfter,
                    replacementString: replacementString,
                    rangeStart: rangeStart,
                    rangeLength: rangeLength,
                    eventType: eventType
                )
            }
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.formattedRemaining)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(sessionManager.remainingSeconds < 30 ? .red : .primary)
                    .monospacedDigit()
                Text("Free Writing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: endEarly) {
                Text("End Early")
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
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text("live speed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func endEarly() {
        sessionManager.finalizeFreeWriting(finalText: typedText)
    }

    // MARK: - Complete Screen

    private var completeScreen: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Time's Up")
                .font(.title2)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                summaryRow(label: "Word count", value: "\(wordCount)")
                summaryRow(label: "WPM", value: String(format: "%.0f", sessionManager.currentTrial?.wpm ?? 0))
                summaryRow(label: "Duration", value: durationString)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
            .padding(.horizontal, 32)

            Button(action: exportFreeWriting) {
                Label("Export (CSV + Text)", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)

            Button(action: done) {
                Text("Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: item.urls)
        }
    }

    private var wordCount: Int {
        typedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private var durationString: String {
        guard let trial = sessionManager.currentTrial, trial.durationMs > 0 else {
            return "0:00"
        }
        let totalSec = Int(trial.durationMs / 1000)
        return String(format: "%d:%02d", totalSec / 60, totalSec % 60)
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func exportFreeWriting() {
        guard let session = sessionManager.currentSession else { return }
        let exporter = DataExporter()
        var urls: [URL] = []
        if let csvURL = exporter.exportFreeWritingCSV(
            session: session,
            prompt: sessionManager.freeWritingPrompt,
            finalText: typedText,
            events: sessionManager.freeWritingEvents,
            participant: sessionManager.participant
        ) {
            urls.append(csvURL)
        }
        if let txtURL = exporter.exportFreeWritingText(
            prompt: sessionManager.freeWritingPrompt,
            finalText: typedText,
            participant: sessionManager.participant
        ) {
            urls.append(txtURL)
        }
        if !urls.isEmpty {
            shareItem = ShareItem(urls: urls)
        }
    }

    private func done() {
        dismiss()
        sessionManager.resetFreeWriting()
    }
}
