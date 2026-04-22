import SwiftUI
import SwiftData
import UIKit

struct ParticipantSetupView: View {
    @Environment(\.modelContext) private var modelContext
    var sessionManager: SessionManager

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var ageText: String = ""
    @State private var dominantHand: DominantHand = .right

    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    private let sessionDurationSeconds = 300   // fixed 5-minute sessions

    var body: some View {
        NavigationStack {
            Form {
                Section("Participant Information") {
                    TextField("First Name", text: $firstName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)

                    TextField("Last Name", text: $lastName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)

                    TextField("Age (optional)", text: $ageText)
                        .keyboardType(.numberPad)

                    Picker("Dominant Hand", selection: $dominantHand) {
                        Text("Right").tag(DominantHand.right)
                        Text("Left").tag(DominantHand.left)
                        Text("Ambidextrous").tag(DominantHand.ambidextrous)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Session Duration") {
                    LabeledContent("Duration", value: "5 minutes")
                    Text("A random corpus will be assigned when the session starts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Device Info") {
                    LabeledContent("Device", value: DeviceInfo.modelName)
                    LabeledContent("iOS", value: DeviceInfo.systemVersion)
                    LabeledContent("Screen", value: "\(Int(DeviceInfo.screenWidthPt)) x \(Int(DeviceInfo.screenHeightPt)) pt")
                }

                Section {
                    Button(action: { startSession(mode: .classic) }) {
                        HStack {
                            Spacer()
                            Text("Start Session")
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.orange)
                    // Name fields are optional — session can start without them
                }

                Section {
                    Button(action: { startSession(mode: .gaussian) }) {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Text("Start Gaussian Session")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Text(gaussianModelSubtitle)
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.teal)
                } header: {
                    Text("Personalized Keyboard")
                } footer: {
                    Text("Classifies taps with a per-key Gaussian model " +
                         "(Mahalanobis). The model learns from every session " +
                         "you run — classic or Gaussian.")
                        .font(.caption)
                }
            }
            .navigationTitle("TypingResearch")
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            ) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    sessionManager.measuredKeyboardHeight = frame.height
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first {
                        sessionManager.safeAreaBottom = window.safeAreaInsets.bottom
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Start

    private var gaussianModelSubtitle: String {
        let n = GaussianModelStore.shared.totalSampleCount()
        if n == 0 { return "No taps recorded yet — first session trains the model" }
        return "Model trained on \(n) taps so far"
    }

    private func startSession(mode: SessionMode) {
        let fn = firstName.trimmingCharacters(in: .whitespaces)
        let ln = lastName.trimmingCharacters(in: .whitespaces)
        let age: Int? = ageText.isEmpty ? nil : Int(ageText)

        let participant = Participant(
            firstName: fn.isEmpty ? "Anonymous" : fn,
            lastName: ln.isEmpty ? "" : ln,
            age: age,
            dominantHand: dominantHand,
            deviceModel: DeviceInfo.modelName,
            systemVersion: DeviceInfo.systemVersion,
            screenWidthPt: DeviceInfo.screenWidthPt,
            screenHeightPt: DeviceInfo.screenHeightPt,
            appVersion: DeviceInfo.appVersion
        )
        modelContext.insert(participant)
        sessionManager.configure(modelContext: modelContext)
        sessionManager.startSession(participant: participant,
                                    durationSeconds: sessionDurationSeconds,
                                    mode: mode)
    }
}
