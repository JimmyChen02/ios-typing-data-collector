import Foundation

/// Coordinates backing up every file a session produced — screen.mov,
/// face.mov, imu.csv, keystrokes.csv, seg_images/*.jpg + manifest.csv —
/// via two independent paths: the zero-setup AppsScriptUploader (works out
/// of the box on every participant's device with no per-device action)
/// and the optional local FolderBackupService (a Files-picker folder,
/// useful for e.g. the researcher's own device). A session counts as
/// backed up once *every* file has reached its destination via *either*
/// path. Walks the session's folder recursively rather than a fixed
/// filename list, since the file set has grown past just two videos.
///
/// Files are uploaded one at a time, not all at once: a session can
/// produce 60+ files, and firing every request concurrently caused
/// dozens of near-simultaneous Apps Script executions to race on
/// Drive's find-or-create-folder logic, creating duplicate participant/
/// session folders (Drive's folder-search index lags slightly behind
/// creation). The script now also locks around that section server-side,
/// but staying sequential here avoids piling up that many concurrent
/// executions in the first place.
@MainActor
enum SessionBackup {
    static func attempt(sessionDirectory: URL, sessionID: String, participantName: String, completion: ((Bool) -> Void)? = nil) {
        let files = allFiles(under: sessionDirectory)
        guard !files.isEmpty else {
            completion?(true)
            return
        }
        uploadNext(
            files: files,
            index: 0,
            sessionDirectory: sessionDirectory,
            sessionID: sessionID,
            participantName: participantName,
            allSucceeded: true,
            completion: completion
        )
    }

    private static func uploadNext(
        files: [URL],
        index: Int,
        sessionDirectory: URL,
        sessionID: String,
        participantName: String,
        allSucceeded: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard index < files.count else {
            if allSucceeded {
                UploadStatusStore.shared.markUploaded(sessionID)
            }
            completion?(allSucceeded)
            return
        }

        let fileURL = files[index]
        let relativePath = relativePath(of: fileURL, under: sessionDirectory)
        attemptFile(fileURL, relativePath: relativePath, sessionID: sessionID, participantName: participantName) { succeeded in
            uploadNext(
                files: files,
                index: index + 1,
                sessionDirectory: sessionDirectory,
                sessionID: sessionID,
                participantName: participantName,
                allSucceeded: allSucceeded && succeeded,
                completion: completion
            )
        }
    }

    private static func attemptFile(
        _ fileURL: URL,
        relativePath: String,
        sessionID: String,
        participantName: String,
        completion: @escaping (Bool) -> Void
    ) {
        var remaining = FolderBackupService.shared.hasFolder ? 2 : 1
        var succeeded = false

        func settle() {
            remaining -= 1
            if remaining == 0 {
                completion(succeeded)
            }
        }

        AppsScriptUploader.shared.upload(
            fileURL: fileURL,
            relativePath: relativePath,
            participantName: participantName,
            sessionID: sessionID
        ) { result in
            if case .success = result { succeeded = true }
            settle()
        }
        if FolderBackupService.shared.hasFolder {
            FolderBackupService.shared.copy(
                fileURL,
                relativePath: relativePath,
                participantName: participantName,
                sessionID: sessionID
            ) { result in
                if case .success = result { succeeded = true }
                settle()
            }
        }
    }

    private static func allFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegularFile {
                files.append(url)
            }
        }
        return files
    }

    private static func relativePath(of fileURL: URL, under directory: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        guard filePath.hasPrefix(dirPath) else { return fileURL.lastPathComponent }
        var relative = String(filePath.dropFirst(dirPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
