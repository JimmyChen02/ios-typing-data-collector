import SwiftUI

/// The study home: overall progress, per-condition remaining, a quota-gated
/// "start next session" flow (quick hand pick, then straight to the recording
/// screen — the hand/posture reminder pops up once recording starts), the
/// completed-session list with backup status, and a re-viewable posture guide.
struct StudyHomeView: View {
    @State private var protocolState = StudyProtocol.shared
    @State private var sessions: [RecordingSession] = []

    @State private var showingHandPicker = false
    @State private var launchHand: HoldingHand?         // drives the recording cover
    @State private var launchNumber = 0
    @State private var launchPrompt = ""

    @State private var showingPostureGuide = false
    @State private var showingFolderPicker = false
    @State private var showingDeleteAllConfirmation = false
    @State private var backupErrorMessage: String?

    var body: some View {
        List {
            Section { progressCard }
            Section { backupFolderRow }
            Section("Recorded sessions") {
                if sessions.isEmpty {
                    Text("No sessions yet. Tap “Start next session” to begin.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
        .navigationTitle("Typing Study")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Review posture guide") { showingPostureGuide = true }
                    Button("Change Participant", role: .destructive) {
                        ParticipantStore.shared.clear()
                    }
                    Button("Delete All Sessions", role: .destructive) {
                        showingDeleteAllConfirmation = true
                    }
                } label: {
                    Label(ParticipantStore.shared.name ?? "Participant", systemImage: "person.crop.circle")
                }
            }
        }
        .confirmationDialog("Which hand for this session?",
                            isPresented: $showingHandPicker, titleVisibility: .visible) {
            ForEach(protocolState.availableConditions) { hand in
                Button(hand.displayName) { startSession(with: hand) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(item: $launchHand, onDismiss: reload) { hand in
            NotepadView(hand: hand, sessionNumber: launchNumber, prompt: launchPrompt)
        }
        .sheet(isPresented: $showingPostureGuide) {
            PostureGuideView(isOnboarding: false) { showingPostureGuide = false }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in FolderBackupService.shared.setFolder(url) }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete all \(sessions.count) session\(sessions.count == 1 ? "" : "s") from this device?",
            isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible
        ) {
            Button("Delete All Sessions", role: .destructive) {
                RecordingSession.deleteAll()
                UploadStatusStore.shared.clearAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every locally recorded session. It does not delete anything already backed up to Drive.")
        }
        .alert("Backup Folder", isPresented: .init(
            get: { backupErrorMessage != nil },
            set: { if !$0 { backupErrorMessage = nil } }
        )) {
            Button("OK") { backupErrorMessage = nil }
        } message: {
            Text(backupErrorMessage ?? "")
        }
    }

    /// Capture the session's number + prompt, then present the recorder on a
    /// later runloop turn (so the hand-picker dialog is fully gone first).
    private func startSession(with hand: HoldingHand) {
        launchNumber = protocolState.nextSessionNumber
        launchPrompt = protocolState.promptForNextSession()
        DispatchQueue.main.async { launchHand = hand }
    }

    // MARK: Progress

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Progress").font(.headline)
                Spacer()
                Text("\(protocolState.completedCount) / \(StudyProtocol.totalSessions)")
                    .font(.headline).monospacedDigit()
            }
            ProgressView(value: Double(protocolState.completedCount),
                         total: Double(StudyProtocol.totalSessions))
            VStack(spacing: 6) {
                conditionRow(.left)
                conditionRow(.right)
                conditionRow(.both)
            }
            if protocolState.isComplete {
                Text("All \(StudyProtocol.totalSessions) sessions complete. Thank you! 🎉")
                    .font(.subheadline).bold().foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    showingHandPicker = true
                } label: {
                    Label("Start next session", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func conditionRow(_ hand: HoldingHand) -> some View {
        let quota = protocolState.quota(for: hand)
        let done = protocolState.completedCount(for: hand)
        HStack(spacing: 10) {
            Text(hand.displayName).font(.subheadline)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<quota, id: \.self) { i in
                    Circle()
                        .fill(i < done ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 9, height: 9)
                }
            }
            Text(done == quota ? "done" : "\(max(quota - done, 0)) left")
                .font(.caption).foregroundStyle(done == quota ? .green : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Backup folder row (unchanged behavior)

    @ViewBuilder
    private var backupFolderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: AppsScriptUploader.shared.isConfigured ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(AppsScriptUploader.shared.isConfigured ? .green : .orange)
                Text(AppsScriptUploader.shared.isConfigured
                     ? "Automatic upload configured. Every session backs up with no setup needed."
                     : "Automatic upload not configured yet. See docs/AUTOMATIC_DRIVE_UPLOAD.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let name = FolderBackupService.shared.folderDisplayName {
                HStack {
                    Image(systemName: "checkmark.folder").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Optional local backup folder set").font(.subheadline)
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { showingFolderPicker = true }.font(.caption)
                }
            } else {
                Button { showingFolderPicker = true } label: {
                    Label("(Optional) Also Choose a Local Drive Folder", systemImage: "folder.badge.plus")
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: Completed-session row (unchanged behavior)

    @ViewBuilder
    private func sessionRow(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.id).font(.headline)
                Spacer()
                backupStatusIcon(session)
            }
            HStack {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ShareLink(items: session.allFileURLs) {
                    Label("Save/Share", systemImage: "square.and.arrow.up")
                }
                .font(.caption).buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func backupStatusIcon(_ session: RecordingSession) -> some View {
        if UploadStatusStore.shared.isUploaded(session.id) {
            Image(systemName: "checkmark.icloud").foregroundStyle(.green)
        } else {
            Button {
                SessionBackup.attempt(
                    sessionDirectory: session.sessionDirectory,
                    sessionID: session.id,
                    participantName: ParticipantStore.shared.driveFolderName,
                    hand: session.hand
                ) { succeeded in
                    if succeeded { reload() }
                    else { backupErrorMessage = "Backup failed. Check your network connection and that automatic upload is configured (see docs/AUTOMATIC_DRIVE_UPLOAD.md)." }
                }
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
    }

    private func reload() {
        sessions = RecordingSession.loadAll()
    }
}
