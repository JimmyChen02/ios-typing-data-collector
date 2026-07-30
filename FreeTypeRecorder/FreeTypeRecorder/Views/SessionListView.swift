import SwiftUI

struct SessionListView: View {
    @State private var sessions: [RecordingSession] = []
    @State private var showingHandPicker = false
    @State private var sessionHand: HoldingHand?
    @State private var showingFolderPicker = false
    @State private var showingDeleteAllConfirmation = false
    @State private var backupErrorMessage: String?

    var body: some View {
        List {
            Section {
                backupFolderRow
            }
            Section {
                if sessions.isEmpty {
                    Text("No sessions yet. Start a new free-type session to record one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
        .navigationTitle("Free Type Sessions")
        .navigationDestination(for: RecordingSession.self) { session in
            SessionDetailView(session: session)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
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
            ToolbarItem(placement: .primaryAction) {
                Button("New Session") {
                    showingHandPicker = true
                }
            }
        }
        .confirmationDialog(
            "Which hand are you holding the phone with?",
            isPresented: $showingHandPicker,
            titleVisibility: .visible
        ) {
            Button("Left hand") { sessionHand = .left }
            Button("Right hand") { sessionHand = .right }
            Button("Both hands") { sessionHand = .both }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(item: $sessionHand, onDismiss: reload) { hand in
            NotepadView(hand: hand)
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                FolderBackupService.shared.setFolder(url)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete all \(sessions.count) session\(sessions.count == 1 ? "" : "s") from this device?",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Sessions", role: .destructive) {
                RecordingSession.deleteAll()
                UploadStatusStore.shared.clearAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every locally recorded session (videos, IMU, keystrokes, seg-images). It does not delete anything already backed up to Drive.")
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

    @ViewBuilder
    private var backupFolderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: AppsScriptUploader.shared.isConfigured ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(AppsScriptUploader.shared.isConfigured ? .green : .orange)
                Text(AppsScriptUploader.shared.isConfigured
                     ? "Automatic upload configured — every session backs up with no setup needed."
                     : "Automatic upload not configured yet. See docs/AUTOMATIC_DRIVE_UPLOAD.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // Optional second path — mainly useful for a researcher's own
            // test device that already has direct Files access to Drive.
            if let name = FolderBackupService.shared.folderDisplayName {
                HStack {
                    Image(systemName: "checkmark.folder")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Optional local backup folder set")
                            .font(.subheadline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { showingFolderPicker = true }
                        .font(.caption)
                }
            } else {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("(Optional) Also Choose a Local Drive Folder", systemImage: "folder.badge.plus")
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: RecordingSession) -> some View {
        NavigationLink(value: session) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Spacer()
                    backupStatusIcon(session)
                }
                HStack {
                    Text(session.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Manual fallback — always available, not just when the
                    // automatic backup failed, so a session can be backed up
                    // redundantly on request. Shares every file the session
                    // produced (videos, CSVs, seg-image stills), no zip.
                    ShareLink(items: session.allFileURLs) {
                        Label("Save/Share", systemImage: "square.and.arrow.up")
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func backupStatusIcon(_ session: RecordingSession) -> some View {
        if UploadStatusStore.shared.isUploaded(session.id) {
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.green)
        } else {
            Button {
                SessionBackup.attempt(
                    sessionDirectory: session.sessionDirectory,
                    sessionID: session.id,
                    participantName: ParticipantStore.shared.name ?? "Unknown"
                ) { succeeded in
                    if succeeded {
                        reload()
                    } else {
                        backupErrorMessage = "Backup failed — check your network connection and that automatic upload is configured (see docs/AUTOMATIC_DRIVE_UPLOAD.md)."
                    }
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
