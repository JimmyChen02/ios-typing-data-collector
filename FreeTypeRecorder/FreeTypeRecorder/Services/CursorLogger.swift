import Foundation

/// Logs caret and selection movement to `cursor.csv` for a session — the
/// companion to KeystrokeLogger, which records *what* the text changed to
/// while this records *where the caret was*. Same lifecycle and the same
/// `t_ms` origin, so the two files merge on time.
///
/// Rows are formatted on arrival rather than buffered as structs: the
/// formatting is pure (see CursorSample.csvRow) and this keeps the logger to
/// buffering, timing, and file IO.
@MainActor
final class CursorLogger {
    static let shared = CursorLogger()

    private var rows: [String] = []
    private var startDate: Date?

    private init() {}

    func start() {
        rows.removeAll(keepingCapacity: true)
        startDate = Date()
    }

    func log(_ sample: CursorSample) {
        guard let startDate else { return }
        let tMs = Date().timeIntervalSince(startDate) * 1000.0
        rows.append(sample.csvRow(tMs: tMs))
    }

    /// Writes buffered rows to `outputURL` (typically
    /// `<sessionDirectory>/cursor.csv`). Returns the URL on success, nil if
    /// nothing was logged or the write failed.
    func stop(writingTo outputURL: URL) -> URL? {
        defer { rows.removeAll() }
        guard !rows.isEmpty else { return nil }

        let csv = CursorSample.csvHeader + "\n" + rows.joined(separator: "\n") + "\n"
        do {
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            print("CursorLogger: failed to write CSV: \(error)")
            return nil
        }
    }
}
