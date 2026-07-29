import SwiftUI

/// Shown once, before the session list, whenever no participant name is
/// set yet (first launch, or after "Change Participant"). The name is used
/// to file every session's zip under a same-named Drive subfolder.
struct ParticipantSetupView: View {
    @State private var name = ""

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
                } footer: {
                    Text("Your sessions are saved to Drive in a folder under this name.")
                }
                Section {
                    Button("Continue") {
                        ParticipantStore.shared.setName(trimmedName)
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .navigationTitle("Welcome")
        }
    }
}
