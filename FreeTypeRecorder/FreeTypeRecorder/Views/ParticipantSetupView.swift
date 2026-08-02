import SwiftUI

/// Shown once before the study home whenever no participant is set (first
/// launch, or after "Change Participant"). Collects name + demographics; the
/// phone model is auto-detected. Every field is required, and each row shows
/// live whether it's filled (green check) or still needed (red). Continue
/// stays disabled until all are valid. Saving seeds a fresh study run.
struct ParticipantSetupView: View {
    @State private var name = ""
    @State private var ageText = ""
    @State private var sex: Sex?
    @State private var dominantHand: DominantHand?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var age: Int? { Int(ageText.trimmingCharacters(in: .whitespaces)) }

    private var nameValid: Bool { !trimmedName.isEmpty }
    private var ageValid: Bool { (age ?? 0) > 0 }
    private var sexValid: Bool { sex != nil }
    private var handValid: Bool { dominantHand != nil }
    private var isComplete: Bool { nameValid && ageValid && sexValid && handValid }

    private var missingFields: [String] {
        var m: [String] = []
        if !nameValid { m.append("name") }
        if !ageValid { m.append("age") }
        if !sexValid { m.append("sex") }
        if !handValid { m.append("dominant hand") }
        return m
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Your name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        statusIcon(nameValid)
                    }
                    HStack {
                        TextField("Age", text: $ageText)
                            .keyboardType(.numberPad)
                        statusIcon(ageValid)
                    }
                    choiceRow(title: "Sex", value: sex?.displayName, valid: sexValid) {
                        ForEach(Sex.allCases) { option in
                            Button(option.displayName) { sex = option }
                        }
                    }
                    choiceRow(title: "Dominant hand", value: dominantHand?.displayName, valid: handValid) {
                        ForEach(DominantHand.allCases) { option in
                            Button(option.displayName) { dominantHand = option }
                        }
                    }
                } header: {
                    Text("About you")
                } footer: {
                    Text("All fields are required. Your phone model is detected automatically: \(DeviceInfo.modelName). Sessions are saved to Drive in a folder under your name and phone.")
                }

                Section {
                    Button("Continue") { save() }
                        .disabled(!isComplete)
                } footer: {
                    if isComplete {
                        Label("All set. You're ready to start.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else {
                        Label("Still needed: \(missingFields.joined(separator: ", ")).",
                              systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Welcome")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func statusIcon(_ valid: Bool) -> some View {
        Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(valid ? .green : .red)
            .accessibilityLabel(valid ? "Filled in" : "Required, not filled in")
    }

    /// A tappable menu row (used for the pickers) that shows the chosen value
    /// or a red "Required", plus the same green/red status icon as the text
    /// fields — so every required field reads consistently.
    @ViewBuilder
    private func choiceRow<Options: View>(
        title: String,
        value: String?,
        valid: Bool,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Menu {
            options()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value ?? "Required")
                    .foregroundStyle(value == nil ? .red : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusIcon(valid)
            }
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
