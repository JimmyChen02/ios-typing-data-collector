import Foundation
import SwiftData

final class DataExporter {

    struct ResearchPackageValidationReport {
        let isComplete: Bool
        let requiredArtifacts: [String]
        let missingArtifacts: [String]
    }

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

    // MARK: - Behavior Annotation CSV

    func exportBehaviorAnnotationsCSV(
        session: Session,
        events: [InputEventData],
        participant: Participant?
    ) -> URL? {
        let annotations = EditBehaviorAnnotator.annotate(events: events)
        var rows: [String] = [[
            "participant_first", "participant_last", "session_id",
            "event_index", "trial_index", "event_type", "edit_source", "edit_kind",
            "category", "intent_preserved", "cursor_moved",
            "used_autocorrect", "used_suggestion",
            "wrongfully_typed_token", "llm_edited_token",
            "original_text", "emitted_text", "selected_suggestion",
            "text_before", "text_after"
        ].joined(separator: ",")]

        for ann in annotations {
            guard ann.eventIndex >= 0, ann.eventIndex < events.count else { continue }
            let e = events[ann.eventIndex]
            rows.append([
                csvEscape(participant?.firstName ?? ""),
                csvEscape(participant?.lastName ?? ""),
                csvEscape(session.id.uuidString),
                String(ann.eventIndex),
                String(e.trialIndex + 1),
                csvEscape(e.eventType.rawValue),
                csvEscape(e.editSource),
                csvEscape(e.editKind),
                csvEscape(ann.category),
                ann.intentPreserved ? "1" : "0",
                ann.cursorMoved ? "1" : "0",
                ann.usedAutocorrect ? "1" : "0",
                ann.usedSuggestion ? "1" : "0",
                csvEscape(ann.wrongfullyTypedToken),
                csvEscape(ann.llmEditedToken),
                csvEscape(e.originalText),
                csvEscape(e.emittedText),
                csvEscape(e.selectedSuggestion),
                csvEscape(e.textBefore),
                csvEscape(e.textAfter)
            ].joined(separator: ","))
        }
        let name = filename(participant: participant, suffix: "edit_behavior_annotations", ext: "csv")
        return writeToTempFile(content: rows.joined(separator: "\n"), filename: name)
    }

    // MARK: - Full research package (manual share-to-Drive)

    func exportResearchPackageZip(
        session: Session,
        events: [InputEventData],
        participant: Participant?,
        handSamples: [HandSample]
    ) -> URL? {
        exportResearchPackageZipWithValidation(
            session: session,
            events: events,
            participant: participant,
            handSamples: handSamples
        ).url
    }

    func exportResearchPackageZipWithValidation(
        session: Session,
        events: [InputEventData],
        participant: Participant?,
        handSamples: [HandSample]
    ) -> (url: URL?, report: ResearchPackageValidationReport) {
        let fm = FileManager.default
        let first = participant?.firstName ?? "unknown"
        let last = participant?.lastName ?? "unknown"
        let stamp = Int(Date().timeIntervalSince1970)
        let stagingName = "research_export_\(first)_\(last)_\(stamp)"
        let staging = fm.temporaryDirectory.appendingPathComponent(stagingName, isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            print("DataExporter: could not create research-export staging dir: \(error)")
            return (
                nil,
                ResearchPackageValidationReport(
                    isComplete: false,
                    requiredArtifacts: [],
                    missingArtifacts: ["staging_directory_creation_failed"]
                )
            )
        }

        let rawCSV = makeCSV(events: events, session: session, participant: participant, cleaned: false)
        let cleanedCSV = makeCSV(events: events, session: session, participant: participant, cleaned: true)
        let annotations = EditBehaviorAnnotator.annotate(events: events)
        let behaviorCSV = makeBehaviorCSV(
            annotations: annotations,
            events: events,
            participant: participant,
            session: session
        )

        _ = writeContent(rawCSV, to: staging.appendingPathComponent("keystrokes_raw.csv"))
        _ = writeContent(cleanedCSV, to: staging.appendingPathComponent("keystrokes_cleaned.csv"))
        _ = writeContent(behaviorCSV, to: staging.appendingPathComponent("edit_behavior_annotations.csv"))
        _ = writeResearchJSON(
            events: events,
            annotations: annotations,
            participant: participant,
            session: session,
            to: staging.appendingPathComponent("research_events.json")
        )

        // Include hand manifest + images + IMU if available.
        if !handSamples.isEmpty,
           let manifest = exportHandManifestCSV(samples: handSamples, participant: participant) {
            try? fm.copyItem(at: manifest, to: staging.appendingPathComponent(manifest.lastPathComponent))
            let imagesDest = staging.appendingPathComponent("hand_images", isDirectory: true)
            try? fm.createDirectory(at: imagesDest, withIntermediateDirectories: true)
            for imageURL in HandImageStore.shared.allImageURLs() {
                try? fm.copyItem(at: imageURL, to: imagesDest.appendingPathComponent(imageURL.lastPathComponent))
            }
        }

        let imuSrc = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imu", isDirectory: true)
        if fm.fileExists(atPath: imuSrc.path) {
            let imuDest = staging.appendingPathComponent("imu", isDirectory: true)
            try? fm.createDirectory(at: imuDest, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: imuSrc, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "csv" {
                    try? fm.copyItem(at: f, to: imuDest.appendingPathComponent(f.lastPathComponent))
                }
            }
        }

        let requiredArtifacts = [
            "keystrokes_raw.csv",
            "keystrokes_cleaned.csv",
            "edit_behavior_annotations.csv",
            "research_events.json"
        ]
        let missingArtifacts = requiredArtifacts.filter { artifact in
            !fm.fileExists(atPath: staging.appendingPathComponent(artifact).path)
        }
        let report = ResearchPackageValidationReport(
            isComplete: missingArtifacts.isEmpty,
            requiredArtifacts: requiredArtifacts,
            missingArtifacts: missingArtifacts
        )
        let url = zipDirectory(staging, zipName: "\(stagingName).zip")
        return (url, report)
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
            "text_before", "text_after",
            "edit_source", "edit_kind", "original_text", "emitted_text",
            "suggestions_offered", "selected_suggestion",
            "touch_gesture_json",
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
                String(event.trialIndex + 1),
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
                csvEscape(event.textAfter),
                csvEscape(event.editSource),
                csvEscape(event.editKind),
                csvEscape(event.originalText),
                csvEscape(event.emittedText),
                csvEscape(event.suggestionsOffered),
                csvEscape(event.selectedSuggestion),
                csvEscape(event.touchGestureJSON),
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
            "image_relative_path", "imu_relative_path", "image_pixel_width", "image_pixel_height",
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
                csvEscape(s.imuRelativePath),
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
    ///   - `imu/<sessionId>.csv` (all session IMU recordings)
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

        // 3. IMU CSVs: Documents/imu/<sessionId>.csv → staging/imu/<sessionId>.csv
        let imuSrc = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imu", isDirectory: true)
        if fm.fileExists(atPath: imuSrc.path) {
            let imuDest = staging.appendingPathComponent("imu", isDirectory: true)
            try? fm.createDirectory(at: imuDest, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: imuSrc, includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "csv" {
                    try? fm.copyItem(at: f, to: imuDest.appendingPathComponent(f.lastPathComponent))
                }
            }
        }

        // 4. Zip the staging directory.
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

    private func writeContent(_ content: String, to url: URL) -> Bool {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("DataExporter: write failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func makeBehaviorCSV(
        annotations: [EditBehaviorAnnotation],
        events: [InputEventData],
        participant: Participant?,
        session: Session
    ) -> String {
        var rows: [String] = [[
            "participant_first", "participant_last", "session_id",
            "event_index", "trial_index", "event_type", "edit_source", "edit_kind",
            "category", "intent_preserved", "cursor_moved",
            "used_autocorrect", "used_suggestion",
            "wrongfully_typed_token", "llm_edited_token",
            "original_text", "emitted_text", "selected_suggestion",
            "text_before", "text_after"
        ].joined(separator: ",")]
        for ann in annotations {
            guard ann.eventIndex >= 0, ann.eventIndex < events.count else { continue }
            let e = events[ann.eventIndex]
            rows.append([
                csvEscape(participant?.firstName ?? ""),
                csvEscape(participant?.lastName ?? ""),
                csvEscape(session.id.uuidString),
                String(ann.eventIndex),
                String(e.trialIndex + 1),
                csvEscape(e.eventType.rawValue),
                csvEscape(e.editSource),
                csvEscape(e.editKind),
                csvEscape(ann.category),
                ann.intentPreserved ? "1" : "0",
                ann.cursorMoved ? "1" : "0",
                ann.usedAutocorrect ? "1" : "0",
                ann.usedSuggestion ? "1" : "0",
                csvEscape(ann.wrongfullyTypedToken),
                csvEscape(ann.llmEditedToken),
                csvEscape(e.originalText),
                csvEscape(e.emittedText),
                csvEscape(e.selectedSuggestion),
                csvEscape(e.textBefore),
                csvEscape(e.textAfter)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func writeResearchJSON(
        events: [InputEventData],
        annotations: [EditBehaviorAnnotation],
        participant: Participant?,
        session: Session,
        to url: URL
    ) -> Bool {
        struct ExportRecord: Codable {
            let eventIndex: Int
            let trialIndex: Int
            let timestampISO: String
            let eventType: String
            let editSource: String
            let editKind: String
            let keyLabel: String
            let textBefore: String
            let textAfter: String
            let originalText: String
            let emittedText: String
            let selectedSuggestion: String
            let suggestionsOffered: String
            let touchGestureJSON: String
            let annotationCategory: String
            let intentPreserved: Bool
            let cursorMoved: Bool
            let usedAutocorrect: Bool
            let usedSuggestion: Bool
            let wrongfullyTypedToken: String
            let llmEditedToken: String
        }
        struct Payload: Codable {
            let sessionId: String
            let participantFirst: String
            let participantLast: String
            let generatedAtISO: String
            let records: [ExportRecord]
        }

        let iso = ISO8601DateFormatter()
        let annByIndex = Dictionary(uniqueKeysWithValues: annotations.map { ($0.eventIndex, $0) })
        let records: [ExportRecord] = events.enumerated().map { idx, e in
            let ann = annByIndex[idx]
            return ExportRecord(
                eventIndex: idx,
                trialIndex: e.trialIndex + 1,
                timestampISO: iso.string(from: e.timestamp),
                eventType: e.eventType.rawValue,
                editSource: e.editSource,
                editKind: e.editKind,
                keyLabel: e.keyLabel,
                textBefore: e.textBefore,
                textAfter: e.textAfter,
                originalText: e.originalText,
                emittedText: e.emittedText,
                selectedSuggestion: e.selectedSuggestion,
                suggestionsOffered: e.suggestionsOffered,
                touchGestureJSON: e.touchGestureJSON,
                annotationCategory: ann?.category ?? "",
                intentPreserved: ann?.intentPreserved ?? false,
                cursorMoved: ann?.cursorMoved ?? false,
                usedAutocorrect: ann?.usedAutocorrect ?? false,
                usedSuggestion: ann?.usedSuggestion ?? false,
                wrongfullyTypedToken: ann?.wrongfullyTypedToken ?? "",
                llmEditedToken: ann?.llmEditedToken ?? ""
            )
        }
        let payload = Payload(
            sessionId: session.id.uuidString,
            participantFirst: participant?.firstName ?? "",
            participantLast: participant?.lastName ?? "",
            generatedAtISO: iso.string(from: Date()),
            records: records
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("DataExporter: failed to write research json: \(error)")
            return false
        }
    }
}
