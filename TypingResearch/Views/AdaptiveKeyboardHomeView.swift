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
    @State private var autoCapitalization = SharedKeyboardPreferences.shared.autoCapitalizationEnabled
    @State private var autocorrection = SharedKeyboardPreferences.shared.autocorrectionEnabled
    @State private var predictive = SharedKeyboardPreferences.shared.predictiveEnabled
    @State private var characterPreview = SharedKeyboardPreferences.shared.characterPreviewEnabled
    @State private var capsLock = SharedKeyboardPreferences.shared.capsLockEnabled
    @State private var smartPunctuation = SharedKeyboardPreferences.shared.smartPunctuationEnabled
    @State private var oneHandedMode = SharedKeyboardPreferences.shared.oneHandedMode

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Research Keyboard")
                        .font(.title2.weight(.bold))
                    Text("Stock iOS-style keyboard with a three-candidate suggestion bar, autocorrect feedback, key popups, accents, emoji, one-handed/landscape layouts, and logging.")
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
                        Text("Tap this field, switch to Adaptive Keyboard (globe key), then type. Tap a suggestion to accept it, or type “teh ” to try autocorrect.")
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

                Section {
                    Toggle("Auto-Capitalization", isOn: $autoCapitalization)
                        .onChange(of: autoCapitalization) { _, value in
                            SharedKeyboardPreferences.shared.autoCapitalizationEnabled = value
                        }
                    Toggle("Auto-Correction", isOn: $autocorrection)
                        .onChange(of: autocorrection) { _, value in
                            SharedKeyboardPreferences.shared.autocorrectionEnabled = value
                        }
                    Toggle("Predictive", isOn: $predictive)
                        .onChange(of: predictive) { _, value in
                            SharedKeyboardPreferences.shared.predictiveEnabled = value
                        }
                    Toggle("Character Preview", isOn: $characterPreview)
                        .onChange(of: characterPreview) { _, value in
                            SharedKeyboardPreferences.shared.characterPreviewEnabled = value
                        }
                    Toggle("Enable Caps Lock", isOn: $capsLock)
                        .onChange(of: capsLock) { _, value in
                            SharedKeyboardPreferences.shared.capsLockEnabled = value
                        }
                    Toggle("Smart Punctuation", isOn: $smartPunctuation)
                        .onChange(of: smartPunctuation) { _, value in
                            SharedKeyboardPreferences.shared.smartPunctuationEnabled = value
                        }
                    Picker("One-Handed Keyboard", selection: $oneHandedMode) {
                        Text("Off").tag(OneHandedMode.off)
                        Text("Left").tag(OneHandedMode.left)
                        Text("Right").tag(OneHandedMode.right)
                    }
                    .onChange(of: oneHandedMode) { _, value in
                        SharedKeyboardPreferences.shared.oneHandedMode = value
                    }
                } header: {
                    Text("Keyboard behavior")
                } footer: {
                    Text("Mirrors Settings → General → Keyboard. One-handed mode is also reachable by holding the globe key.")
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
                        recordingPaused ? "Recording paused" : "Recording taps, suggestions, autocorrect, and raw text",
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
                    Text("The keyboard uses a three-candidate suggestion bar. Longer suggestions are inserted only when tapped; space/return only apply qualifying typo autocorrections. Dictation and QuickPath remain out of scope. Autocorrect still uses the local language model.")
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
