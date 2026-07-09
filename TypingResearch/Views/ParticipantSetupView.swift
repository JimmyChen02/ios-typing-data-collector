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

    // D2a — opt-in "Posture training run" sub-flow entry point. NOT folded
    // into the default timed study (see the D2 spec's research-integrity
    // requirement) — presented as a separate screen reachable from setup.
    @State private var showPostureSelect: Bool = false
    @State private var showLiveDemo: Bool = false

    // Free Writing Mode — self-contained secondary data-collection mode
    // (mirrors the Posture Training Run opt-in entry point pattern above).
    @State private var showFreeWriting: Bool = false

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
                        if newDesign == .classicAndAdaptive, totalSessions % 2 != 0 {
                            totalSessions += 1
                        }
                    }

                    Stepper(value: $totalSessions, in: 2...20, step: studyDesign == .classicAndAdaptive ? 2 : 1) {
                        HStack {
                            Text("Sessions")
                            Spacer()
                            Text("\(totalSessions)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if studyDesign == .classicAndAdaptive {
                        LabeledContent("Classic sessions", value: "\(totalSessions / 2) × 1 min")
                        LabeledContent("Adaptive sessions", value: "\(totalSessions / 2) × 1 min")
                        Text("First \(totalSessions / 2) sessions use the standard keyboard. Gaussian adaptive keyboard activates for the remaining \(totalSessions / 2).")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        LabeledContent("Classic sessions", value: "\(totalSessions) × 1 min")
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
                    Button(action: startFreeWriting) {
                        HStack {
                            Spacer()
                            VStack(spacing: 2) {
                                Text("Free Writing Mode")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Text("Opt-in — 3 minutes on the standard iOS keyboard")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.blue)
                } footer: {
                    Text("Type freely on the standard iOS keyboard for 3 minutes. No custom keyboard — captures how you use Apple's keyboard.")
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
            .fullScreenCover(isPresented: $showLiveDemo) {
                LivePostureDemoView()
            }
            .fullScreenCover(isPresented: $showFreeWriting) {
                FreeWritingView(sessionManager: sessionManager)
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
        sessionManager.startStudy(participant: participant, totalSessions: totalSessions, design: studyDesign)
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

    // MARK: - Free Writing Mode
    //
    // Self-contained secondary data-collection mode — a single 3-minute
    // notepad session on the standard iOS keyboard. Does not touch the
    // study/trial/gaussian flow; sessionManager.startFreeWriting() owns a
    // parallel Session/Trial + timer path (see SessionManager.swift).
    private func startFreeWriting() {
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
        sessionManager.startFreeWriting(participant: participant)
        showFreeWriting = true
    }
}
