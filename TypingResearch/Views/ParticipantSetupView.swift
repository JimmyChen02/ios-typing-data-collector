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
    @State private var totalSessions: Int = 4

    // D2a — opt-in "Posture training run" sub-flow entry point. NOT folded
    // into the default timed study (see the D2 spec's research-integrity
    // requirement) — presented as a separate screen reachable from setup.
    @State private var showPostureSelect: Bool = false
    @State private var showLiveDemo: Bool = false
    @State private var showKeyboardPlayground: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showKeyboardPlayground = true
                    } label: {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Text("Open Keyboard")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Text("Focus mode — fix touch / suggestions / export CSV")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.blue)
                } footer: {
                    Text("Use this first. Letter keys are sized from this iPhone’s screen width (iOS-style); opening the keyboard briefly calibrates total height to the system keyboard. Suggestions appear in the bar; tap to accept. Space applies spelling autocorrect only.")
                }

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
                    // Gaussian / adaptive routing is paused while we lock the
                    // classic iOS keyboard feel. Studies always use classic.
                    LabeledContent("Keyboard", value: "Classic (iOS-style)")
                    Stepper(value: $totalSessions, in: 1...20, step: 1) {
                        HStack {
                            Text("Sessions")
                            Spacer()
                            Text("\(totalSessions)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text("All sessions use the classic in-app keyboard. Adaptive/Gaussian hit routing is disabled for now.")
                        .font(.caption).foregroundColor(.secondary)
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
                                Text("\(totalSessions) sessions · \(totalSessions) min total")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.orange)
                }

                Section {
                    Button(action: { showPostureSelect = true }) {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Text("Posture Training Run")
                                    .fontWeight(.semibold)
                                Text("Opt-in — labels one typing session with a declared hand posture")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(.systemGray6))
                } footer: {
                    Text("Separate from the study above — captures photos + motion data continuously while you type, labeled with the posture you pick next. Does not affect keystroke-study data.")
                }

                Section {
                    Button(action: { showLiveDemo = true }) {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Label("Live Posture Demo", systemImage: "person.crop.square.badge.camera")
                                    .fontWeight(.semibold)
                                Text("Camera feed + live model prediction")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(.systemGray6))
                } footer: {
                    Text("Demo only — nothing is recorded or saved. Requires the bundled Core ML posture model for live predictions.")
                }
            }
            .navigationTitle("TypingResearch")
            .fullScreenCover(isPresented: $showKeyboardPlayground) {
                KeyboardPlaygroundView()
            }
            .fullScreenCover(isPresented: $showLiveDemo) {
                LivePostureDemoView()
            }
            .sheet(isPresented: $showPostureSelect) {
                PostureSelectView(
                    onSelect: { posture in
                        showPostureSelect = false
                        startPostureTrainingRun(posture: posture)
                    },
                    onCancel: { showPostureSelect = false }
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            ) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    // Capture this device's real system keyboard once so the
                    // in-app keyboard can match it across iPhone models.
                    SystemKeyboardMetrics.recordSystemKeyboardFrame(frame)
                    sessionManager.measuredKeyboardHeight = SystemKeyboardMetrics.totalDockedHeight()
                    sessionManager.safeAreaBottom = SystemKeyboardMetrics.bottomSafeAreaInset()
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
        sessionManager.startStudy(
            participant: participant,
            totalSessions: totalSessions,
            design: .classicOnly
        )
    }

    // MARK: - Posture Training Run (D2a/D2b)
    //
    // A single classic-mode session (no Gaussian switch-over — irrelevant to
    // labeled posture capture) with isPostureTrainingRun = true and
    // selectedPosture set from PostureSelectView. Everything else about the
    // normal session/trial flow (SessionView -> TrialView, keystroke logging,
    // timers) is unchanged; only the background capture hooks in TrialView
    // are gated on isPostureTrainingRun.
    private func startPostureTrainingRun(posture: HoldingHand) {
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
        sessionManager.selectedPosture = posture
        sessionManager.isPostureTrainingRun = true
        sessionManager.startStudy(participant: participant, totalSessions: 1, design: .classicOnly)
    }
}
