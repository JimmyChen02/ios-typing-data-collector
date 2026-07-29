import Foundation
import Observation

/// The current participant's name, entered once on first launch
/// (ParticipantSetupView) and persisted locally. Used to file every
/// session's zip under a same-named subfolder in Drive, both via
/// AppsScriptUploader and the optional FolderBackupService path.
@MainActor
@Observable
final class ParticipantStore {
    static let shared = ParticipantStore()

    private static let nameKey = "FreeTypeRecorder.participantName"
    private let defaults = UserDefaults.standard

    private(set) var name: String?

    private init() {
        name = defaults.string(forKey: Self.nameKey)
    }

    func setName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: Self.nameKey)
        name = trimmed
    }

    /// Resets the gate so ContentView shows ParticipantSetupView again —
    /// e.g. handing the same device to a different participant.
    func clear() {
        defaults.removeObject(forKey: Self.nameKey)
        name = nil
    }
}
