import Foundation
import SwiftData

final class DataExporter {

    // MARK: - Raw Keystroke CSV

    func exportKeystrokesCSV(
        session: Session,
        events: [InputEventData],
        participant: Participant?
    ) -> URL? {
        let csv = makeCSV(events: events, session: session,
                          participant: participant, cleaned: false)
        let name = filename(participant: participant, suffix: "keystrokes", ext: "csv")
        return writeToTempFile(content: csv, filename: name)
    }

    // MARK: - Cleaned Keystroke CSV
    //
    // Mirrors scripts/clean_keystrokes.py: appends dist_from_target_kw,
    // is_outlier, and outlier_flags to the raw row schema. (tap_norm_x and
    // tap_norm_y already exist in the raw schema and carry the same values
    // the cleaner would compute, so they are not duplicated.)

    func exportCleanedKeystrokesCSV(
        session: Session,
        events: [InputEventData],
        participant: Participant?
    ) -> URL? {
        let csv = makeCSV(events: events, session: session,
                          participant: participant, cleaned: true)
        let name = filename(participant: participant,
                            suffix: "keystrokes_cleaned", ext: "csv")
        return writeToTempFile(content: csv, filename: name)
    }

    // MARK: - CSV Construction

    private func makeCSV(
        events: [InputEventData],
        session: Session,
        participant: Participant?,
        cleaned: Bool
    ) -> String {
        var header: [String] = [
            "participant_first", "participant_last", "session_id",
            "session_mode", "study_session_index", "trial_id", "trial_index",
            "event_type", "key_label",
            "tap_local_x", "tap_local_y",
            "tap_norm_x", "tap_norm_y",
            "key_width", "key_height",
            "key_row", "key_col",
            "expected_char", "actual_char", "corrected_char", "is_correct",
            "previous_key_label",
            "text_before",
            "timestamp_ms", "inter_key_interval_ms"
        ]
        if cleaned {
            header += ["dist_from_target_kw", "is_outlier", "outlier_flags"]
        }

        var rows: [String] = [header.joined(separator: ",")]
        let sessionStart = session.startedAt

        for event in events {
            let flagged: KeystrokeFlagResult? = cleaned ? KeystrokeCleaner.flag(event) : nil
            if let flagged, flagged.isSpatialOutlier { continue }

            let keyColStr   = event.keyCol.map { "\($0)" } ?? ""
            let isCorrectStr = event.eventType == .delete ? "" : (event.isCorrect ? "1" : "0")
            var row: [String] = [
                csvEscape(participant?.firstName ?? ""),
                csvEscape(participant?.lastName  ?? ""),
                csvEscape(event.studyId.uuidString),
                csvEscape(event.sessionMode),
                String(event.studySessionIndex + 1),
                csvEscape(event.trialId.uuidString),
                String(event.studySessionIndex + 1),
                csvEscape(event.eventType.rawValue),
                csvEscape(event.keyLabel),
                String(format: "%.4f", event.tapLocalX),
                String(format: "%.4f", event.tapLocalY),
                String(format: "%.4f", event.tapNormX),
                String(format: "%.4f", event.tapNormY),
                String(format: "%.4f", event.keyWidth),
                String(format: "%.4f", event.keyHeight),
                csvEscape(event.keyRow),
                keyColStr,
                csvEscape(event.expectedChar),
                csvEscape(event.actualChar),
                csvEscape(event.correctedChar),
                isCorrectStr,
                csvEscape(event.previousKeyLabel),
                csvEscape(event.textBefore),
                String(format: "%.3f", event.timestamp.timeIntervalSince(sessionStart) * 1000),
                String(format: "%.3f", event.interKeyIntervalMs)
            ]

            if let flagged {
                let distStr = flagged.distFromTargetKW
                    .map { String(format: "%.3f", $0) } ?? ""
                row += [
                    distStr,
                    flagged.isOutlier ? "1" : "0",
                    csvEscape(flagged.flagsString)
                ]
            }

            rows.append(row.joined(separator: ","))
        }

        return rows.joined(separator: "\n")
    }

    // MARK: - Hand Manifest CSV
    //
    // One row per HandSample. Schema matches the manifest consumed by
    // scripts/hand_dataset.py and scripts/train_hand_classifier.py.

    func exportHandManifestCSV(samples: [HandSample], participant: Participant?) -> URL? {
        guard !samples.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        let header = [
            "participant_first", "participant_last", "study_id", "session_id",
            "study_session_index", "captured_at_iso", "holding_hand",
            "image_relative_path", "image_pixel_width", "image_pixel_height",
            "camera_position", "device_model", "system_version", "notes"
        ]

        var rows: [String] = [header.joined(separator: ",")]
        for s in samples {
            let row: [String] = [
                csvEscape(participant?.firstName ?? ""),
                csvEscape(participant?.lastName  ?? ""),
                csvEscape(s.studyId.uuidString),
                csvEscape(s.sessionId?.uuidString ?? ""),
                String(s.studySessionIndex),
                csvEscape(iso.string(from: s.capturedAt)),
                csvEscape(s.holdingHand.rawValue),
                csvEscape(s.imageRelativePath),
                String(s.imagePixelWidth),
                String(s.imagePixelHeight),
                csvEscape(s.cameraPosition),
                csvEscape(s.deviceModel),
                csvEscape(s.systemVersion),
                csvEscape(s.notes)
            ]
            rows.append(row.joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")
        let name = filename(participant: participant, suffix: "hand_manifest", ext: "csv")
        return writeToTempFile(content: csv, filename: name)
    }

    // MARK: - Helpers

    private func filename(participant: Participant?, suffix: String, ext: String) -> String {
        let first = participant?.firstName ?? "unknown"
        let last  = participant?.lastName  ?? "unknown"
        return "\(suffix)_\(first)_\(last).\(ext)"
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func writeToTempFile(content: String, filename: String) -> URL? {
        guard let data = content.data(using: .utf8) else { return nil }
        return writeToTempFile(data: data, filename: filename)
    }

    private func writeToTempFile(data: Data, filename: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            print("DataExporter error: \(error)")
            return nil
        }
    }
}
