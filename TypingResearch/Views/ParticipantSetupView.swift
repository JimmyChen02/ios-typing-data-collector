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
    @State private var totalSessions: Int = 4  // min 2, step 2
    @State private var studyDesign: StudyDesign = .classicAndAdaptive
    @State private var sessionDurationMinutes: Int = 1

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

                Section("Study Setup") {
                    Picker("Mode", selection: $studyDesign) {
                        Text("Classic + Adaptive").tag(StudyDesign.classicAndAdaptive)
                        Text("Classic Only").tag(StudyDesign.classicOnly)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: studyDesign) { _, newDesign in
                        if newDesign == .classicAndAdaptive {
                            if totalSessions > 20 { totalSessions = 20 }
                            if totalSessions % 2 != 0 { totalSessions += 1 }
                        }
                    }

                    Stepper(value: $totalSessions, in: 2...(studyDesign == .classicOnly ? 30 : 20), step: studyDesign == .classicAndAdaptive ? 2 : 1) {
                        HStack {
                            Text("Sessions")
                            Spacer()
                            Text("\(totalSessions)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Picker("Session Duration", selection: $sessionDurationMinutes) {
                        ForEach(1...5, id: \.self) { min in
                            Text("\(min) min").tag(min)
                        }
                    }

                    if studyDesign == .classicAndAdaptive {
                        LabeledContent("Classic sessions", value: "\(totalSessions / 2) × \(sessionDurationMinutes) min")
                        LabeledContent("Adaptive sessions", value: "\(totalSessions / 2) × \(sessionDurationMinutes) min")
                        Text("First \(totalSessions / 2) sessions use the standard keyboard. Gaussian adaptive keyboard activates for the remaining \(totalSessions / 2).")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        LabeledContent("Classic sessions", value: "\(totalSessions) × \(sessionDurationMinutes) min")
                        Text("All sessions use the standard keyboard. No Gaussian adaptive keyboard.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Section("Device Info") {
                    LabeledContent("Device", value: DeviceInfo.modelName)
                    LabeledContent("iOS", value: DeviceInfo.systemVersion)
                    LabeledContent("Screen", value: "\(Int(DeviceInfo.screenWidthPt)) x \(Int(DeviceInfo.screenHeightPt)) pt")
                }

                Section {
                    Button(action: startStudy) {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Text("Start Study")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Text("\(totalSessions) sessions · \(totalSessions * sessionDurationMinutes) min total")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.orange)
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

    private func startStudy() {
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
        sessionManager.startStudy(participant: participant, totalSessions: totalSessions, design: studyDesign, sessionDurationSeconds: sessionDurationMinutes * 60)
    }
}
