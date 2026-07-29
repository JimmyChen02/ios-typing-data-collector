import Foundation

enum KeystrokeEventType: String {
    case insert, delete, replace, paste
}

/// Logs every text-change event in the notepad to `keystrokes.csv` for a
/// session. The free-typing analogue of TypingResearch's InputEvent — same
/// event-type/timing shape, minus the expected-word/correctness fields
/// that only make sense for a fixed-word trial.
@MainActor
final class KeystrokeLogger {
    static let shared = KeystrokeLogger()

    struct Event {
        let tMs: Double
        let eventType: KeystrokeEventType
        let replacementText: String
        let rangeStart: Int
        let rangeLength: Int
        let resultingTextLength: Int
        let interKeyIntervalMs: Double
    }

    private var events: [Event] = []
    private var startDate: Date?
    private var lastEventDate: Date?

    private init() {}

    func start() {
        events.removeAll(keepingCapacity: true)
        startDate = Date()
        lastEventDate = nil
    }

    func logEvent(
        type: KeystrokeEventType,
        replacementText: String,
        rangeStart: Int,
        rangeLength: Int,
        resultingTextLength: Int
    ) {
        guard let startDate else { return }
        let now = Date()
        let interKeyIntervalMs = lastEventDate.map { now.timeIntervalSince($0) * 1000.0 } ?? 0
        lastEventDate = now
        events.append(Event(
            tMs: now.timeIntervalSince(startDate) * 1000.0,
            eventType: type,
            replacementText: replacementText,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            resultingTextLength: resultingTextLength,
            interKeyIntervalMs: interKeyIntervalMs
        ))
    }

    /// Writes buffered events to `outputURL` (typically
    /// `<sessionDirectory>/keystrokes.csv`). Returns the URL on success,
    /// nil if nothing was logged or the write failed.
    func stop(writingTo outputURL: URL) -> URL? {
        defer { events.removeAll() }
        guard !events.isEmpty else { return nil }

        var csv = "t_ms,event_type,replacement_text,range_start,range_length,resulting_text_length,inter_key_interval_ms\n"
        for event in events {
            csv += "\(String(format: "%.3f", event.tMs)),\(event.eventType.rawValue),"
            csv += "\(Self.csvEscape(event.replacementText)),\(event.rangeStart),\(event.rangeLength),"
            csv += "\(event.resultingTextLength),\(String(format: "%.3f", event.interKeyIntervalMs))\n"
        }

        do {
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            print("KeystrokeLogger: failed to write CSV: \(error)")
            return nil
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }
}
