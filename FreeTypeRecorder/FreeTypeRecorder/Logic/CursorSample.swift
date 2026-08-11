import Foundation

/// One caret/selection observation, in text-view coordinates (points).
///
/// Deliberately Foundation-only: LoggingTextView converts every UIKit
/// geometry value to points before building one of these, which keeps the
/// type compilable into the unit-test bundle and keeps coordinate-space
/// conversion in one place.
struct CursorSample: Equatable {
    let selStart: Int
    let selLength: Int
    let prevSelStart: Int
    let prevSelLength: Int
    let caretX: Double?
    let caretY: Double?
    let caretH: Double?
    let touchX: Double?
    let touchY: Double?
    let touchPhase: String?
    let touchAgeMs: Double?
    /// True when this selection change was merely the consequence of a text
    /// edit (the caret advancing as you type), rather than a reposition.
    let afterTextChange: Bool
    /// True when the app assigned the text wholesale, not the participant.
    let programmatic: Bool
    let textLength: Int

    /// Signed caret displacement; negative means the caret moved backward.
    var deltaChars: Int { selStart - prevSelStart }

    static let csvHeader = "t_ms,sel_start,sel_length,prev_sel_start,prev_sel_length,delta_chars,caret_x,caret_y,caret_h,touch_x,touch_y,touch_phase,touch_age_ms,after_text_change,programmatic,text_length"

    /// One CSV row. Unavailable geometry is written as an empty field rather
    /// than 0, so analysis can tell "no touch was in flight" from "a touch at
    /// the origin". No field can contain a comma, so no escaping is needed:
    /// every value is numeric except touchPhase, which is a fixed keyword.
    func csvRow(tMs: Double) -> String {
        [
            Self.format(tMs),
            "\(selStart)", "\(selLength)",
            "\(prevSelStart)", "\(prevSelLength)",
            "\(deltaChars)",
            Self.format(caretX), Self.format(caretY), Self.format(caretH),
            Self.format(touchX), Self.format(touchY),
            touchPhase ?? "",
            Self.format(touchAgeMs),
            afterTextChange ? "1" : "0",
            programmatic ? "1" : "0",
            "\(textLength)"
        ].joined(separator: ",")
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.3f", value)
    }
}
