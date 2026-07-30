import Foundation

enum BackupError: Error {
    case noFolderChosen
    case accessDenied
}

/// Lets the user pick a destination folder once — via iOS's Files picker,
/// which can browse into Google Drive if the Drive app's "Files" browsing
/// is enabled in its Settings — and remembers it as a security-scoped
/// bookmark. Every session after that copies its files there
/// automatically: no Google API, no OAuth client, no per-session tap.
@MainActor
final class FolderBackupService {
    static let shared = FolderBackupService()

    private static let bookmarkKey = "FreeTypeRecorder.backupFolderBookmark"
    private let defaults = UserDefaults.standard

    private(set) var folderDisplayName: String?

    private init() {
        resolveBookmark()
    }

    var hasFolder: Bool { folderDisplayName != nil }

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            // `.withSecurityScope` doesn't exist on iOS — a plain bookmark of
            // a document-picker-granted URL already preserves that scope
            // when resolved later.
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            folderDisplayName = url.lastPathComponent
        } catch {
            print("FolderBackupService: failed to create bookmark: \(error)")
        }
    }

    func clearFolder() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        folderDisplayName = nil
    }

    /// Copies `fileURL` into
    /// `<participantName>/<hand>/<sessionID>/<relativePath>` inside the
    /// bookmarked folder (all intermediate folders created as needed),
    /// overwriting any same-named file already there — mirrors the same
    /// layout AppsScriptUploader creates in Drive.
    func copy(
        _ fileURL: URL,
        relativePath: String,
        participantName: String,
        hand: String,
        sessionID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            completion(.failure(BackupError.noFolderChosen))
            return
        }
        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard folderURL.startAccessingSecurityScopedResource() else {
                completion(.failure(BackupError.accessDenied))
                return
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            let dest = folderURL
                .appendingPathComponent(participantName, isDirectory: true)
                .appendingPathComponent(hand, isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: fileURL, to: dest)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    private func resolveBookmark() {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            folderDisplayName = url.lastPathComponent
        }
    }
}
