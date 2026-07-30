import Foundation

/// One saved free-type session. `face.mov` (segmented video) is always
/// present; `screen.mov` only exists if the participant ran the screen
/// broadcast during the session (see BroadcastCoordinator).
struct RecordingSession: Identifiable, Hashable {
    let id: String
    let date: Date
    let hand: HoldingHand
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
        let root = sessionsDirectory()
        let fm = FileManager.default
        guard let firstLevel = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [RecordingSession] = []
        for entry in firstLevel {
            // Old flat layout: Sessions/<timestamp>/face.mov.
            if let flat = session(at: entry, hand: .unknown) {
                sessions.append(flat)
                continue
            }
            // New layout: Sessions/<hand>/<timestamp>/face.mov.
            guard let hand = HoldingHand(rawValue: entry.lastPathComponent),
                  let children = try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for child in children {
                if let s = session(at: child, hand: hand) { sessions.append(s) }
            }
        }
        return sessions.sorted { $0.date > $1.date }
    }

    private static func session(at folder: URL, hand: HoldingHand) -> RecordingSession? {
        let face = folder.appendingPathComponent("face.mov")
        guard FileManager.default.fileExists(atPath: face.path) else { return nil }
        let creationDate = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        return RecordingSession(id: folder.lastPathComponent, date: creationDate, hand: hand, faceURL: face, sessionDirectory: folder)
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
