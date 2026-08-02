import SwiftUI

/// Shown once before the study home whenever no participant is set (first
/// launch, or after "Change Participant"). Collects name + demographics; the
/// phone model is auto-detected. Saving seeds a fresh study run.
struct ParticipantSetupView: View {
    @State private var name = ""
    @State private var ageText = ""
    @State private var sex: Sex = .preferNotToSay
    @State private var dominantHand: DominantHand = .right

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Age (optional)", text: $ageText)
                        .keyboardType(.numberPad)
                    Picker("Sex", selection: $sex) {
                        ForEach(Sex.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Dominant hand", selection: $dominantHand) {
                        ForEach(DominantHand.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("About you")
                } footer: {
                    Text("Your phone model is detected automatically: \(DeviceInfo.modelName). Sessions are saved to Drive in a folder under your name.")
                }
                Section {
                    Button("Continue") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .navigationTitle("Welcome")
        }
    }

    private func save() {
        let age = Int(ageText.trimmingCharacters(in: .whitespaces))
        ParticipantStore.shared.setProfile(
            name: trimmedName, age: age, sex: sex, dominantHand: dominantHand
        )
        StudyProtocol.shared.startNewParticipant()
    }
}
