import SwiftUI

struct ContentView: View {
    @State private var store = ParticipantStore.shared

    var body: some View {
        if let name = store.name, !name.isEmpty {
            if store.hasSeenPostureGuide {
                NavigationStack { StudyHomeView() }
            } else {
                PostureGuideView(isOnboarding: true) {
                    store.markPostureGuideSeen()
                }
            }
        } else {
            ParticipantSetupView()
        }
    }
}
