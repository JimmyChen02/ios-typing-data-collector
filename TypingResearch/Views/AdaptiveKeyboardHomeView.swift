import SwiftUI
import UIKit

struct AdaptiveKeyboardHomeView: View {
    @State private var recordingPaused = SharedKeyboardPreferences.shared.recordingPaused
    @State private var exportURL: URL?
    @State private var eventCount = 0
    @State private var pendingEventCount = 0
    @State private var acknowledgedEventCount = 0
    @State private var lastSuccessfulUpload: Date?
    @State private var consentGranted = KeyboardUploadStateStore().hasCurrentConsent
    @State private var isConfigured = KeyboardUploadConfiguration().isConfigured
    @State private var isUploading = false
    @State private var statusMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var showingConsentConfirmation = false
    private let uploadState = KeyboardUploadStateStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Enable the keyboard") {
                    Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle")
                    Label("Add New Keyboard → Adaptive Keyboard", systemImage: "2.circle")
                    Label("Allow Full Access (needed for logging)", systemImage: "3.circle")
                    Label("In any text field, tap 🌐 and choose Adaptive Keyboard", systemImage: "4.circle")
                    Button("Open App Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }

                Section("Full telemetry consent") {
                    Toggle("Allow recording and automatic upload", isOn: Binding(
                        get: { consentGranted },
                        set: { newValue in
                            if newValue {
                                showingConsentConfirmation = true
                            } else {
                                uploadState.setConsent(granted: false)
                                consentGranted = false
                                statusMessage = "Recording and uploads are disabled."
                                refreshUploadStatus()
                            }
                        }
                    ))
                    Text(
                        "This research keyboard records the full event schema. It may include "
                        + "typed text, nearby text context, inserted, deleted, and replacement "
                        + "text, suggestions, emoji, key labels, touch locations, timing, and "
                        + "device/keyboard settings. Data is sent to the research server."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Telemetry") {
                    Toggle("Pause recording", isOn: Binding(
                        get: { recordingPaused },
                        set: {
                            recordingPaused = $0
                            SharedKeyboardPreferences.shared.recordingPaused = $0
                        }
                    ))
                    .disabled(!consentGranted)
                    LabeledContent("Encrypted events", value: "\(eventCount)")
                    LabeledContent("Pending upload", value: "\(pendingEventCount)")
                    LabeledContent("Server acknowledged", value: "\(acknowledgedEventCount)")
                    LabeledContent(
                        "Last successful upload",
                        value: lastSuccessfulUpload?.formatted(date: .abbreviated, time: .shortened)
                            ?? "Never"
                    )
                    if !isConfigured {
                        Label(
                            "Supabase is not configured for this build.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Button {
                        uploadNow()
                    } label: {
                        if isUploading {
                            ProgressView()
                        } else {
                            Label("Send data now", systemImage: "arrow.up.circle")
                        }
                    }
                    .disabled(!consentGranted || !isConfigured || isUploading)
                    Button("Refresh event count") {
                        refreshUploadStatus()
                    }
                    Button("Prepare decrypted JSONL export") {
                        do {
                            exportURL = try EncryptedEventLedger.shared.exportDecrypted()
                            refreshUploadStatus()
                            statusMessage = "Export prepared."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share prepared export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Delete all keyboard logs", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Keyboard")
            .onAppear(perform: refreshUploadStatus)
            .alert("Allow full keyboard telemetry?", isPresented: $showingConsentConfirmation) {
                Button("Allow recording and upload") {
                    uploadState.setConsent(granted: true)
                    consentGranted = true
                    recordingPaused = false
                    SharedKeyboardPreferences.shared.recordingPaused = false
                    statusMessage = "Consent recorded. Keyboard telemetry is enabled."
                    refreshUploadStatus()
                }
                Button("Cancel", role: .cancel) {
                    consentGranted = uploadState.hasCurrentConsent
                }
            } message: {
                Text(
                    "Typed and surrounding text may be recorded and uploaded. "
                    + "Only continue after reading and agreeing to the study consent information."
                )
            }
            .alert("Delete keyboard logs?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    do {
                        try EncryptedEventLedger.shared.deleteAll()
                        exportURL = nil
                        eventCount = 0
                        pendingEventCount = 0
                        acknowledgedEventCount = 0
                        statusMessage = "Local logs deleted. Previously uploaded server data remains."
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permanently removes the encrypted ledger from this device. "
                    + "It does not delete data already stored on the research server."
                )
            }
        }
    }

    private func refreshUploadStatus() {
        consentGranted = uploadState.hasCurrentConsent
        isConfigured = KeyboardUploadConfiguration().isConfigured
        Task {
            do {
                let status = try await KeyboardEventUploader.shared.status()
                await MainActor.run {
                    eventCount = status.totalEvents
                    pendingEventCount = status.pendingEvents
                    acknowledgedEventCount = status.acknowledgedEvents
                    lastSuccessfulUpload = status.lastSuccessfulUpload
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func uploadNow() {
        isUploading = true
        statusMessage = "Uploading…"
        Task {
            do {
                let result = try await KeyboardEventUploader.shared.uploadNow()
                await MainActor.run {
                    isUploading = false
                    lastSuccessfulUpload = result.lastSuccessfulUpload
                    statusMessage = result.uploadedEvents == 0
                        ? "Everything is already uploaded."
                        : "Uploaded \(result.uploadedEvents) events."
                    refreshUploadStatus()
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    statusMessage = error.localizedDescription
                    refreshUploadStatus()
                }
            }
        }
    }
}
