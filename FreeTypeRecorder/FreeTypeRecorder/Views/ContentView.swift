import SwiftUI

struct ContentView: View {
    var body: some View {
        if let name = ParticipantStore.shared.name, !name.isEmpty {
            NavigationStack {
                SessionListView()
            }
        } else {
            ParticipantSetupView()
        }
    }
}
