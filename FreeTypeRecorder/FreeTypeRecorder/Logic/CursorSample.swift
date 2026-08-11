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
    /// ms since the most recent text edit, or nil if no edit has happened yet.
    /// Raw rather than a derived "was this typing?" flag: a timestamp cannot go
    /// stale the way a one-shot latch can. UIKit fires no selection change for a
    /// same-length edit ("teh " -> "the " autocorrect leaves the caret where it
    /// was), which stranded the old latch and mislabeled a later, unrelated
    /// caret move as typing. Analysis thresholds this offline.
    let msSinceLastTextChange: Double?
    let textLength: Int

    /// Signed caret displacement; negative means the caret moved backward.
    var deltaChars: Int { selStart - prevSelStart }

    static let csvHeader = "t_ms,sel_start,sel_length,prev_sel_start,prev_sel_length,delta_chars,caret_x,caret_y,caret_h,touch_x,touch_y,touch_phase,touch_age_ms,ms_since_last_text_change,text_length"

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
            Self.format(msSinceLastTextChange),
            "\(textLength)"
        ].joined(separator: ",")
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.3f", value)
    }
}
