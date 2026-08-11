import SwiftUI

struct NotepadView: View {
    let hand: HoldingHand
    let sessionNumber: Int
    let prompt: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var recorder = SessionRecorder()
    @State private var broadcast = BroadcastCoordinator.shared
    @State private var showError = false
    @State private var errorMessage = ""

    // Set true once we observe our broadcast recording during the session
    // (its in-progress file appears), so on Stop we know to wait for its
    // finished file. Reset per session.
    @State private var broadcastWasUsed = false
    // Non-nil while waiting for the participant to stop their broadcast
    // after tapping Stop; holds the session dir to finalize once the
    // broadcast file lands.
    @State private var pendingDirectory: URL?
    // Set when, during the finishing wait, the broadcast has actually
    // stopped — starts a bounded timeout so we never hang forever if the
    // video file never lands.
    @State private var pendingBroadcastEndedAt: Date?
    @State private var pollTimer: Timer?
    // Guards the async gap between calling recorder.start and it flipping
    // isRecording, so the 0.5s poll can't auto-start the session twice.
    @State private var isStartingSession = false
    // Ensures the study protocol counts this session exactly once, no matter
    // which finalize path (broadcast stop or disappear) fires.
    @State private var didFinalize = false
    // Guards the abort path (broadcast stopped before the full minute) from
    // re-entry, since the 0.5s poll would otherwise fire it repeatedly.
    @State private var isAborting = false
    // Drives the "session too short, please redo" alert after an abort.
    @State private var showAbort = false
    // Shown once, right when recording begins: reminds the participant of
    // their posture and which hand to use this session.
    @State private var showStartReminder = false

    // How long to wait for the finished video after the broadcast stops
    // before saving the session without it (safety valve against a hang).
    private static let finishTimeout: TimeInterval = 30

    private var remaining: TimeInterval {
        max(SessionRecorder.sessionDuration - recorder.elapsed, 0)
    }

    // Reminder shown when recording starts: sit up + which hand to use.
    private var startReminderMessage: String {
        let handPhrase: String
        switch hand {
        case .left: handPhrase = "your LEFT hand"
        case .right: handPhrase = "your RIGHT hand"
        case .both: handPhrase = "BOTH hands"
        case .unknown: handPhrase = "your assigned hand"
        }
        return "Sit up straight and keep your arm off the desk. Type with \(handPhrase) for this session."
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                broadcastStatusBar
                sessionHeader

                LoggingTextView(text: $text, isEditable: recorder.isRecording)
                    .padding()
            }
            .navigationTitle(pendingDirectory == nil ? timeString(remaining) : "Saving…")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Backing out is only allowed before anything is
                    // recording. During saving there's no exit at all — it
                    // auto-closes when the video is saved.
                    if !recorder.isRecording && pendingDirectory == nil {
                        Button("Cancel", action: dismiss.callAsFunction)
                    }
                }
            }
            .alert("Recording Error", isPresented: $showError) {
                Button("OK", action: dismiss.callAsFunction)
            } message: {
                Text(errorMessage)
            }
            .alert("Remember", isPresented: $showStartReminder) {
                Button("OK, got it", role: .cancel) {}
            } message: {
                Text(startReminderMessage)
            }
            .alert("Session too short", isPresented: $showAbort) {
                Button("OK", action: dismiss.callAsFunction)
            } message: {
                Text("The broadcast stopped before the full minute, so this session wasn't saved. Please run it again and type for the full time.")
            }
        }
        .onChange(of: text) { _, newValue in
            // Start the 1-minute countdown on the first keystroke, so the
            // pre-typing reminder popup doesn't eat into recording time.
            if recorder.isRecording && !newValue.isEmpty {
                recorder.beginTimerIfNeeded()
            }
        }
        .onAppear(perform: startPolling)
        .onDisappear(perform: handleDisappear)
    }

    // MARK: - Broadcast status / start UI

    @ViewBuilder
    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session \(sessionNumber) of \(StudyProtocol.totalSessions)")
                    .font(.subheadline).bold()
                Spacer()
                Label(hand.displayName, systemImage: "hand.raised.fill")
                    .font(.caption).bold()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Text(prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    @ViewBuilder
    private var broadcastStatusBar: some View {
        HStack(spacing: 10) {
            if pendingDirectory != nil {
                ProgressView()
            } else {
                Image(systemName: broadcast.isBroadcasting ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(broadcast.isBroadcasting ? .red : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if broadcast.appGroupUnavailable {
                    Text("Screen recording unavailable")
                        .font(.caption).bold().foregroundStyle(.orange)
                    Text("App Group isn't set up. See docs/SCREEN_BROADCAST_SETUP.md.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if pendingDirectory != nil {
                    if broadcast.isBroadcasting {
                        // 1-min limit reached; we've asked the extension to
                        // stop the broadcast and are waiting for it to end.
                        Text("Time's up! Finishing up…")
                            .font(.caption).bold()
                        Text("Stopping the recording automatically. Please wait.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Saving your recording…").font(.caption).bold()
                        Text("Please wait. This closes automatically; don't close the app.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if broadcast.isBroadcasting {
                    Text("Recording, type freely").font(.system(size: 24)).bold()
                    Text("Type for the full minute. Don't stop the broadcast early — the session is only saved once the time is up.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Step 1: tap ● → FreeTypeRecorder → Start Broadcast")
                        .font(.caption).bold()
                    Text("Recording your screen starts the typing session automatically.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // The system broadcast picker — one tap opens the Start Broadcast
            // sheet. Only shown before recording begins.
            if pendingDirectory == nil && !broadcast.isBroadcasting {
                BroadcastPickerButton()
                    .frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // MARK: - Lifecycle

    private func startRecording() {
        guard !isStartingSession, !recorder.isRecording else { return }
        isStartingSession = true
        text = ""
        RecentKeysTracker.shared.reset()
        recorder.start(hand: hand, sessionNumber: sessionNumber, prompt: prompt, onAutoStop: stopRecording) { error in
            isStartingSession = false
            if let error {
                errorMessage = error.localizedDescription
                showError = true
            } else {
                RippleController.shared.isRecording = true
                showStartReminder = true
            }
        }
    }

    // The participant stopped the broadcast before the session's full minute
    // elapsed. Sessions must run the full time, so discard the partial
    // recording, leave the study count untouched (finalize is never called),
    // and send them back to redo the session.
    private func abortSession() {
        guard !isAborting, !didFinalize else { return }
        isAborting = true
        RippleController.shared.isRecording = false
        recorder.stop(finalText: text) { directory in
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
            // Drop any screen recording the extension just finished so a
            // stray video can't leak into the next session.
            broadcast.discardFinishedRecording()
            showAbort = true
        }
    }

    private func stopRecording() {
        RippleController.shared.isRecording = false
        recorder.stop(finalText: text) { directory in
            guard let directory else {
                dismiss()
                return
            }
            broadcast.refresh()
            // If our broadcast was used at any point, or a finished file is
            // already sitting in the shared container, wait to collect it
            // before finalizing. Otherwise finalize now (no screen recording).
            if broadcastWasUsed || broadcast.isBroadcasting || broadcast.hasFinishedRecording {
                // The minute is up (this only runs from the auto-stop timer),
                // so end the broadcast automatically instead of making the
                // participant stop it by hand — an app can't stop a broadcast
                // directly, but the extension polls for this request each frame
                // and ends itself, after which its finished file lands and the
                // collect→finalize flow below runs on its own.
                if broadcast.isBroadcasting {
                    broadcast.requestStop()
                }
                pendingBroadcastEndedAt = nil
                pendingDirectory = directory
                checkPendingBroadcastFinished()
            } else {
                finalize(directory)
                dismiss()
            }
        }
    }

    // Polls the shared container (the broadcast runs out-of-process) to
    // drive the live indicator and to detect when a post-Stop broadcast
    // has finished so we can collect its file.
    private func startPolling() {
        broadcast.refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                broadcast.refresh()
                if broadcast.isBroadcasting {
                    broadcastWasUsed = true
                    // The broadcast drives the session: auto-start the app's
                    // recorders when the broadcast begins, so the participant
                    // only ever taps Start Broadcast (not a separate Start).
                    if !recorder.isRecording && pendingDirectory == nil {
                        startRecording()
                    }
                } else if broadcastWasUsed && recorder.isRecording {
                    // Broadcast stopped before the full minute elapsed →
                    // abort. Reaching the full duration fires onAutoStop,
                    // which stops the recorder first, so isRecording still
                    // being true here always means an early stop.
                    abortSession()
                }
                checkPendingBroadcastFinished()
            }
        }
    }

    private func checkPendingBroadcastFinished() {
        guard let directory = pendingDirectory else { return }

        // The finished file appears once the extension renamed it on
        // broadcast stop — the definitive "done" signal. Collect it, save,
        // and auto-close.
        if broadcast.hasFinishedRecording {
            broadcast.collectRecording(into: directory)
            finishPending(directory)
            return
        }

        // Otherwise keep waiting. Once the broadcast has actually stopped,
        // give its file a bounded window to land; if it never does, save the
        // session without the screen recording rather than hang forever.
        if !broadcast.isBroadcasting {
            if pendingBroadcastEndedAt == nil {
                pendingBroadcastEndedAt = Date()
            } else if Date().timeIntervalSince(pendingBroadcastEndedAt!) > Self.finishTimeout {
                finishPending(directory)
            }
        }
    }

    private func finishPending(_ directory: URL) {
        pendingDirectory = nil
        pendingBroadcastEndedAt = nil
        finalize(directory)
        dismiss()
    }

    private func handleDisappear() {
        RippleController.shared.isRecording = false
        pollTimer?.invalidate()
        pollTimer = nil
        if recorder.isRecording {
            recorder.stop(finalText: text) { directory in
                guard let directory else { return }
                // Best-effort: grab a broadcast file if one already landed.
                BroadcastCoordinator.shared.collectRecording(into: directory)
                finalize(directory)
            }
        }
    }

    // The single finalize path: count the session in the study protocol
    // (once), then hand its files to the backup pipeline. Runs after
    // dismiss-worthy state is set, so a slow upload never blocks closing.
    private func finalize(_ directory: URL) {
        guard !didFinalize else { return }
        didFinalize = true
        StudyProtocol.shared.recordCompletion(hand: hand)
        SessionBackup.attempt(
            sessionDirectory: directory,
            sessionID: directory.lastPathComponent,
            participantName: ParticipantStore.shared.driveFolderName,
            hand: hand
        )
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
