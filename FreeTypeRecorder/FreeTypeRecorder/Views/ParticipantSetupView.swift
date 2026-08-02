import SwiftUI

/// Shown once before the study home whenever no participant is set (first
/// launch, or after "Change Participant"). Collects name + demographics; the
/// phone model is auto-detected. Every field is required — Continue stays
/// disabled until all are filled. Saving seeds a fresh study run.
struct ParticipantSetupView: View {
    @State private var name = ""
    @State private var ageText = ""
    @State private var sex: Sex?
    @State private var dominantHand: DominantHand?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var age: Int? {
        Int(ageText.trimmingCharacters(in: .whitespaces))
    }

    /// Every input must be provided before the participant can continue.
    private var isComplete: Bool {
        !trimmedName.isEmpty && (age ?? 0) > 0 && sex != nil && dominantHand != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Age", text: $ageText)
                        .keyboardType(.numberPad)
                    Picker("Sex", selection: $sex) {
                        Text("Select").tag(Sex?.none)
                        ForEach(Sex.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker("Dominant hand", selection: $dominantHand) {
                        Text("Select").tag(DominantHand?.none)
                        ForEach(DominantHand.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                } header: {
                    Text("About you")
                } footer: {
                    Text("All fields are required. Your phone model is detected automatically: \(DeviceInfo.modelName). Sessions are saved to Drive in a folder under your name and phone.")
                }
                Section {
                    Button("Continue") { save() }
                        .disabled(!isComplete)
                }
            }
            .navigationTitle("Welcome")
        }
    }

    private func save() {
        guard let sex, let dominantHand, let age else { return }
        ParticipantStore.shared.setProfile(
            name: trimmedName, age: age, sex: sex, dominantHand: dominantHand
        )
        StudyProtocol.shared.startNewParticipant()
    }
}
