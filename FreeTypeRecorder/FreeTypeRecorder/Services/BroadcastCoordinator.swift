import Foundation
import Observation

/// Main-app side of the broadcast pipeline. The full-screen recording is
/// produced by the separate BroadcastExtension process (the only capture
/// path that includes the system keyboard). Coordination is file-based
/// through the shared App Group container (see BroadcastShared):
/// - `isBroadcasting` — the extension's marker file is present
/// - `hasFinishedRecording` — the completed video is ready to collect
/// - `collectRecording` — move the finished file into a session folder
/// - `requestStop` — ask the running extension to stop itself
///
/// The broadcast's lifecycle is user-driven (iOS requires the participant
/// to tap "Start Broadcast" in a system sheet; no app can start it), so
/// these are polled rather than event-driven.
@MainActor
@Observable
final class BroadcastCoordinator {
    static let shared = BroadcastCoordinator()

    private init() {}

    /// True while our extension is alive (its marker file is present).
    private(set) var isBroadcasting = false

    /// True once the extension has finished and published its final file.
    private(set) var hasFinishedRecording = false

    /// True if the shared App Group container isn't reachable at all — a
    /// strong signal the App Group capability isn't set up on this build.
    var appGroupUnavailable: Bool {
        BroadcastShared.containerURL() == nil
    }

    func refresh() {
        isBroadcasting = fileExists(BroadcastShared.activeMarkerURL())
        hasFinishedRecording = fileExists(BroadcastShared.finishedURL())
    }

    /// Moves the extension's finished recording into `sessionDirectory` as
    /// `screen.mov`. Returns true if a finished file was present and moved.
    @discardableResult
    func collectRecording(into sessionDirectory: URL) -> Bool {
        guard let source = BroadcastShared.finishedURL(),
              FileManager.default.fileExists(atPath: source.path) else {
            return false
        }
        let dest = sessionDirectory.appendingPathComponent("screen.mov")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: source, to: dest)
            refresh()
            return true
        } catch {
            print("BroadcastCoordinator: failed to move recording: \(error)")
            return false
        }
    }

    /// Asks the running extension to stop itself (powers "End Early"). The
    /// extension polls for this file each frame and ends the broadcast when
    /// it appears; the normal stop→collect→save flow then runs.
    func requestStop() {
        guard let url = BroadcastShared.stopRequestURL() else { return }
        try? Data().write(to: url)
    }

    private func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
