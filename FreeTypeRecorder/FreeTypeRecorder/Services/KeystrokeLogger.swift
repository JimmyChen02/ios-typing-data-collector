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
        let replacedText: String
        let replacementText: String
        let rangeStart: Int
        let rangeLength: Int
        let resultingTextLength: Int
        let interKeyIntervalMs: Double
        /// Length of the selection when the change fired. Non-zero means the
        /// user selected text and typed over it — the system never substitutes
        /// into a selection, so this separates manual edits with certainty.
        let selectedLengthBefore: Int
        /// Whether an inline prediction was pending (marked text) when the
        /// change fired. The mechanical tell for a prediction accepted with
        /// space, which otherwise looks exactly like autocorrect.
        let markedTextBefore: Bool
    }

    private var events: [Event] = []
    private var taps: [NativeKeyboardTapSample] = []
    private var startUptime: TimeInterval = 0
    private var startDate: Date?
    private var lastEventDate: Date?

    private init() {}

    var isCollectingNativeTaps: Bool { startDate != nil }
    var measuredTapCount: Int { taps.count }

    func start() {
        taps.removeAll(keepingCapacity: true)
        startUptime = ProcessInfo.processInfo.systemUptime
        events.removeAll(keepingCapacity: true)
        startDate = Date()
        lastEventDate = nil
    }

    /// Native touches and text edits are independent streams. A native tap ID
    /// identifies the measurement only; no nearest-time edit association is made.
    func logNativeTap(_ sample: NativeKeyboardTapSample) {
        guard isCollectingNativeTaps, sample.uptime >= startUptime, sample.isValid else { return }
        taps.append(sample)
    }

    func logEvent(
        type: KeystrokeEventType,
        replacedText: String,
        replacementText: String,
        rangeStart: Int,
        rangeLength: Int,
        resultingTextLength: Int,
        selectedLengthBefore: Int = 0,
        markedTextBefore: Bool = false
    ) {
        guard let startDate else { return }
        let now = Date()
        let interKeyIntervalMs = lastEventDate.map { now.timeIntervalSince($0) * 1000.0 } ?? 0
        lastEventDate = now
        events.append(Event(
            tMs: now.timeIntervalSince(startDate) * 1000.0,
            eventType: type,
            replacedText: replacedText,
            replacementText: replacementText,
            rangeStart: rangeStart,
            rangeLength: rangeLength,
            resultingTextLength: resultingTextLength,
            interKeyIntervalMs: interKeyIntervalMs,
            selectedLengthBefore: selectedLengthBefore,
            markedTextBefore: markedTextBefore
        ))
    }

    /// Writes buffered events to `outputURL` (typically
    /// `<sessionDirectory>/keystrokes.csv`). Returns the URL on success,
    /// nil if nothing was logged or the write failed.
    func stop(writingTo outputURL: URL, tapsURL: URL? = nil) -> URL? {
        defer { events.removeAll(); taps.removeAll(); startDate = nil; lastEventDate = nil }
        if let tapsURL {
            do { try tapCSV().write(to: tapsURL, atomically: true, encoding: .utf8) }
            catch { print("KeystrokeLogger: failed to write taps CSV: \(error)") }
        }
        guard !events.isEmpty else { return nil }

        var csv = "t_ms,event_type,replaced_text,replacement_text,range_start,range_length,resulting_text_length,inter_key_interval_ms,selected_length_before,marked_text_before,keyboard_mode,tap_id," + Self.tapHeader + "\n"
        for event in events {
            csv += "\(String(format: "%.3f", event.tMs)),\(event.eventType.rawValue),"
            csv += "\(Self.csvEscape(event.replacedText)),\(Self.csvEscape(event.replacementText)),"
            csv += "\(event.rangeStart),\(event.rangeLength),"
            csv += "\(event.resultingTextLength),\(String(format: "%.3f", event.interKeyIntervalMs)),"
            csv += "\(event.selectedLengthBefore),\(event.markedTextBefore ? 1 : 0),system,"
            // Preserve the export schema, but never associate asynchronous
            // native text edits with a guessed tap ID or geometry.
            csv += Array(repeating: "", count: 21).joined(separator: ",") + "\n"
        }

        do {
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            print("KeystrokeLogger: failed to write CSV: \(error)")
            return nil
        }
    }

    private func tapCSV() -> String {
        var rows = ["tap_id,t_ms,keyboard_mode," + Self.tapHeader]
        for (index, tap) in taps.enumerated() {
            let fields = [String(index + 1), Self.decimal((tap.uptime - startUptime) * 1000), "system"] + Self.tapFields(tap)
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let tapHeader = "tap_x,tap_y,tap_local_x,tap_local_y,tap_norm_x,tap_norm_y,key_label,key_x,key_y,key_width,key_height,keyboard_width,keyboard_height,tap_coordinate_space,tap_screen_x,tap_screen_y,keyboard_screen_x,keyboard_screen_y,tap_source,touch_window"

    private static func tapFields(_ sample: NativeKeyboardTapSample) -> [String] {
        [sample.x, sample.y].map(decimal)
            + Array(repeating: "", count: 9)
            + [sample.keyboardWidth, sample.keyboardHeight].map(decimal)
            + ["keyboard_points"]
            + [sample.screenX, sample.screenY, sample.keyboardScreenX, sample.keyboardScreenY].map(decimal)
            + ["native_keyboard_region", csvEscape(sample.touchWindow)]
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }
}
