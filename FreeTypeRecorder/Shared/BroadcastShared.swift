import Foundation
import os

/// Constants + shared-container paths used by both the main app and the
/// BroadcastExtension (both targets include this file via project.yml's
/// `Shared` source path).
///
/// Coordination is file-based through the shared App Group container's
/// filesystem, which is reliably visible across both processes (unlike App
/// Group `UserDefaults`, which does not reliably propagate cross-process):
/// - `activeMarkerURL` exists → our broadcast is currently running
/// - `writingURL` exists → video is actively being written
/// - `finishedURL` exists → a completed recording is ready to collect
/// - `stopRequestURL` → the app asks the extension to stop itself
enum BroadcastShared {
    /// MUST match the App Group registered in the Apple Developer portal
    /// and the `com.apple.security.application-groups` entitlement on both
    /// targets in project.yml.
    static let appGroupID = "group.jimmyx.freetyperecorder"

    static let log = Logger(subsystem: "jimmyx.freetyperecorder", category: "broadcast")

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Written the instant the extension launches; the app's "is our
    /// broadcast running" signal, independent of video capture.
    static func activeMarkerURL() -> URL? {
        containerURL()?.appendingPathComponent("broadcast_active.marker")
    }

    /// 0-byte flag present while video is actively being written (the real
    /// video lives in the extension's tmp dir — see SampleHandler).
    static func writingURL() -> URL? {
        containerURL()?.appendingPathComponent("broadcast_screen_writing.flag")
    }

    /// Completed recording, ready for the app to move into a session folder.
    static func finishedURL() -> URL? {
        containerURL()?.appendingPathComponent("broadcast_screen.mp4")
    }

    /// The app drops this to ask the extension to stop itself (an app can't
    /// stop a broadcast directly; the extension polls for it each frame and
    /// calls finishBroadcastWithError when it appears). Powers "End Early".
    static func stopRequestURL() -> URL? {
        containerURL()?.appendingPathComponent("broadcast_stop_request")
    }
}
