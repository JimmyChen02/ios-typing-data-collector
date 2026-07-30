import Foundation
import Observation

/// A rolling, human-readable log of the most recently typed characters,
/// shown in a strip directly above the keyboard (see RecentKeysStripView).
/// Exists because the system keyboard itself can never appear in the
/// screen recording (iOS deliberately hides it from ReplayKit's in-app
/// capture for input-privacy reasons — the same restriction that hides it
/// from AirPlay mirroring/QuickTime screen recording, with no public API
/// to override it); this is ordinary app content instead, which ReplayKit
/// captures completely normally, so rewatching the video still shows
/// exactly what was typed even though the keyboard graphic itself won't.
@MainActor
@Observable
final class RecentKeysTracker {
    static let shared = RecentKeysTracker()

    private static let maxLength = 40

    private(set) var recentText: String = ""

    private init() {}

    /// `symbol` is what to display for one keystroke event — the typed
    /// character(s) for insert/replace/paste, or a marker like "⌫" for
    /// delete. Older text is trimmed from the front once over maxLength.
    func record(_ symbol: String) {
        recentText += symbol
        if recentText.count > Self.maxLength {
            recentText = String(recentText.suffix(Self.maxLength))
        }
        writeShared()
    }

    func reset() {
        recentText = ""
        writeShared()
    }

    private func writeShared() {
        guard let url = BroadcastShared.recentKeysURL() else { return }
        try? recentText.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
