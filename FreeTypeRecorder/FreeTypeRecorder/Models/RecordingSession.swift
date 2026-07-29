import Foundation

/// One saved free-type session. `face.mov` (segmented video) is always
/// present; `screen.mov` only exists if the participant ran the screen
/// broadcast during the session (see BroadcastCoordinator).
struct RecordingSession: Identifiable, Hashable {
    let id: String
    let date: Date
    let faceURL: URL

    /// The on-disk folder containing every file this session produced.
    let sessionDirectory: URL

    /// Expected path of the broadcast screen recording; may not exist.
    var screenURL: URL { sessionDirectory.appendingPathComponent("screen.mov") }

    /// Whether a screen recording was captured for this session.
    var hasScreenRecording: Bool {
        FileManager.default.fileExists(atPath: screenURL.path)
    }

    /// Every regular file under `sessionDirectory`, recursively — used for
    /// the manual Save/Share fallback so it covers the same file set the
    /// automatic backup does, not just the two videos.
    var allFileURLs: [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [faceURL]
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegularFile {
                files.append(url)
            }
        }
        return files
    }

    static func sessionsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Sessions", isDirectory: true)
    }

    static func loadAll() -> [RecordingSession] {
        let directory = sessionsDirectory()
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return folders.compactMap { folder -> RecordingSession? in
            let face = folder.appendingPathComponent("face.mov")
            // face.mov is the always-present anchor; screen.mov is optional
            // (only if the participant ran the broadcast).
            guard FileManager.default.fileExists(atPath: face.path) else { return nil }
            let creationDate = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            return RecordingSession(id: folder.lastPathComponent, date: creationDate, faceURL: face, sessionDirectory: folder)
        }
        .sorted { $0.date > $1.date }
    }

    /// Deletes every locally recorded session. Local-only — this does not
    /// touch anything already uploaded to Drive, and cannot be undone.
    static func deleteAll() {
        let directory = sessionsDirectory()
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
