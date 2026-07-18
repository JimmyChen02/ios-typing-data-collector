import SwiftUI
import UIKit

struct AdaptiveKeyboardHomeView: View {
    @State private var typedText = ""
    @State private var recordingPaused = SharedKeyboardPreferences.shared.recordingPaused
    @State private var retentionDays = SharedKeyboardPreferences.shared.retentionDays
    @State private var exportURL: URL?
    @State private var statusMessage: String?
    @State private var eventCount = 0
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Colorful Research Keyboard")
                        .font(.title2.weight(.bold))
                    Text("Stage 1: iOS-style layout, no calibration. Keys are colorful so you can tell this keyboard is active. Every tap is logged.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Type here") {
                    TextEditor(text: $typedText)
                        .frame(minHeight: 160)
                        .font(.body)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if typedText.isEmpty {
                        Text("Tap this field, switch to Adaptive Keyboard (globe key), then type. Your raw text appears here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Characters", value: "\(typedText.count)")
                        Button("Clear typed text", role: .destructive) {
                            typedText = ""
                        }
                    }
                }

                Section("Enable the keyboard") {
                    Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle")
                    Label("Add New Keyboard → Adaptive Keyboard", systemImage: "2.circle")
                    Label("Allow Full Access (needed for logging)", systemImage: "3.circle")
                    Label("In the field above, tap 🌐 and choose Adaptive Keyboard", systemImage: "4.circle")
                    Button("Open App Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }

                Section("Logging") {
                    Toggle("Pause recording", isOn: Binding(
                        get: { recordingPaused },
                        set: {
                            recordingPaused = $0
                            SharedKeyboardPreferences.shared.recordingPaused = $0
                        }
                    ))
                    Label(
                        recordingPaused ? "Recording paused" : "Recording every tap + raw text",
                        systemImage: recordingPaused ? "pause.circle" : "record.circle"
                    )
                    .foregroundStyle(recordingPaused ? Color.secondary : Color.red)
                    LabeledContent("Logged events", value: "\(eventCount)")
                    Button("Refresh event count") {
                        refreshEventCount()
                    }
                }

                Section("Logged data") {
                    Button("Prepare decrypted JSONL export") {
                        do {
                            exportURL = try EncryptedEventLedger.shared.exportDecrypted()
                            refreshEventCount()
                            statusMessage = "Export prepared."
                        } catch {
                            statusMessage = error.localizedDescription
                        }
                    }
                    Stepper("Retain events for \(retentionDays) days", value: $retentionDays, in: 1...365)
                        .onChange(of: retentionDays) { _, value in
                            SharedKeyboardPreferences.shared.retentionDays = value
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

                Section("Notes") {
                    Text("iOS replaces third-party keyboards in password fields. Apple autocorrect and dictation are not available to this keyboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Keyboard")
            .onAppear(perform: refreshEventCount)
            .alert("Delete keyboard logs?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    do {
                        try EncryptedEventLedger.shared.deleteAll()
                        exportURL = nil
                        eventCount = 0
                        statusMessage = "Logs deleted."
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the encrypted touch ledger from this device.")
            }
        }
    }

    private func refreshEventCount() {
        eventCount = (try? EncryptedEventLedger.shared.readEvents().count) ?? 0
    }
}
