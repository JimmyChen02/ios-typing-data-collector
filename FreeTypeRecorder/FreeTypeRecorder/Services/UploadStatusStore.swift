import Foundation

/// Tracks which sessions have been successfully backed up, so
/// SessionListView can show status and only prompt a manual retry for the
/// ones that failed or never got a chance (e.g. no backup configured yet).
@MainActor
final class UploadStatusStore {
    static let shared = UploadStatusStore()

    private static let key = "FreeTypeRecorder.uploadedSessionIDs"
    private let defaults = UserDefaults.standard

    private init() {}

    func markUploaded(_ sessionID: String) {
        var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
        ids.insert(sessionID)
        defaults.set(Array(ids), forKey: Self.key)
    }

    func isUploaded(_ sessionID: String) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(sessionID)
    }

    /// Clears all recorded statuses — call alongside RecordingSession.deleteAll()
    /// so no stale IDs linger for sessions that no longer exist.
    func clearAll() {
        defaults.removeObject(forKey: Self.key)
    }
}
