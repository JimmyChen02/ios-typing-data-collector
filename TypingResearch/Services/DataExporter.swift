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

    /// Bundles the hand manifest CSV and every captured image into a single
    /// `.zip`, so the whole camera dataset can be AirDropped as one file
    /// instead of hundreds of separate images.
    ///
    /// Layout inside the archive:
    ///   - `hand_manifest_<first>_<last>.csv`
    ///   - `hand_images/<uuid>.jpg` (all captured images)
    func exportHandDataZip(samples: [HandSample], participant: Participant?) -> URL? {
        guard !samples.isEmpty else { return nil }

        let fm = FileManager.default
        let first = participant?.firstName ?? "unknown"
        let last  = participant?.lastName  ?? "unknown"
        let stagingName = "hand_export_\(first)_\(last)"

        // Fresh staging directory under tmp/ — remove any leftover from a prior export.
        let staging = fm.temporaryDirectory.appendingPathComponent(stagingName, isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            print("DataExporter: could not create hand-export staging dir: \(error)")
            return nil
        }

        // 1. Manifest CSV.
        guard let manifestURL = exportHandManifestCSV(samples: samples, participant: participant) else {
            return nil
        }
        try? fm.copyItem(at: manifestURL, to: staging.appendingPathComponent(manifestURL.lastPathComponent))

        // 2. Images into a hand_images/ subfolder.
        let imagesDest = staging.appendingPathComponent("hand_images", isDirectory: true)
        try? fm.createDirectory(at: imagesDest, withIntermediateDirectories: true)
        for imageURL in HandImageStore.shared.allImageURLs() {
            try? fm.copyItem(at: imageURL, to: imagesDest.appendingPathComponent(imageURL.lastPathComponent))
        }

        // 3. Zip the staging directory.
        return zipDirectory(staging, zipName: "\(stagingName).zip")
    }

    /// Zips `directory` into a single archive named `zipName` under tmp/.
    /// Uses NSFileCoordinator's `.forUploading` intent, which produces a zipped
    /// copy of a directory without any third-party dependency.
    private func zipDirectory(_ directory: URL, zipName: String) -> URL? {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent(zipName)
        try? fm.removeItem(at: dest)

        var coordinatorError: NSError?
        var resultURL: URL?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinatorError
        ) { zippedURL in
            // `zippedURL` is a temporary archive the coordinator created; copy it
            // out to a stable location before this block returns.
            do {
                try fm.copyItem(at: zippedURL, to: dest)
                resultURL = dest
            } catch {
                print("DataExporter: zip copy failed: \(error)")
            }
        }

        if let coordinatorError {
            print("DataExporter: zip coordination failed: \(coordinatorError)")
            return nil
        }
        return resultURL
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
