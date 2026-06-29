import SwiftUI
import SwiftData

@main
struct TypingResearchApp: App {
    @State private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            RootView(sessionManager: sessionManager)
        }
        .modelContainer(for: [
            Participant.self,
            Session.self,
            Trial.self,
            InputEvent.self,
            HandSample.self
        ])
    }
}

struct RootView: View {
    var sessionManager: SessionManager

    var body: some View {
        if sessionManager.isSessionActive || sessionManager.isSessionComplete {
            SessionView(sessionManager: sessionManager)
        } else {
            ParticipantSetupView(sessionManager: sessionManager)
        }
    }
}
