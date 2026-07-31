import Foundation
import Observation

/// A rolling, human-readable log of the most recently typed characters.
/// Written to a shared App-Group file (see BroadcastShared.recentKeysURL)
/// and burned into the screen recording by the broadcast extension —
/// hidden from the participant's live screen, but present in the video, so
/// a reviewer can still read exactly what was typed even though the system
/// keyboard itself never appears in the recording (iOS hides it from
/// ReplayKit for input privacy). Keyboard substitutions — autocorrect,
/// QuickType picks, smart punctuation, sentence caps — are shown as one
/// `[old→new]` token so a correction reads intuitively instead of leaving
/// the pre-correction characters stranded next to the result.
@MainActor
@Observable
final class RecentKeysTracker {
    static let shared = RecentKeysTracker()

    private static let maxLength = 40

    private(set) var recentText: String = ""

    private init() {}

    /// `symbol` is what to display for one keystroke event — the typed
    /// character(s) for an insert/paste, or "⌫" for a delete. Older text is
    /// trimmed from the front once over maxLength.
    func record(_ symbol: String) {
        recentText += symbol
        commit()
    }

    /// Records a keyboard substitution (autocorrect, QuickType pick, smart
    /// punctuation, sentence caps) as a single `[old→new]` token. The old
    /// characters are usually already in the log because they were just
    /// typed, so they're dropped from the tail first — otherwise "ij"
    /// autocorrecting to "in" would read as "ijin". Any trailing whitespace
    /// the keyboard appended is kept just outside the bracket: "[ij→in] ".
    func recordReplacement(old: String, new: String) {
        var body = new
        var trailing = ""
        while let last = body.last, last == " " || last == "\n" {
            trailing = String(last) + trailing
            body.removeLast()
        }
        if !old.isEmpty, recentText.hasSuffix(old) {
            recentText.removeLast(old.count)
        }
        recentText += "[\(old)→\(body)]\(trailing)"
        commit()
    }

    func reset() {
        recentText = ""
        writeShared()
    }

    private func commit() {
        if recentText.count > Self.maxLength {
            recentText = String(recentText.suffix(Self.maxLength))
        }
        writeShared()
    }

    private func writeShared() {
        guard let url = BroadcastShared.recentKeysURL() else { return }
        try? recentText.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
