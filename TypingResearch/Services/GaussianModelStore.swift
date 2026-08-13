import Foundation

// MARK: - GaussianModelStore
//
// Cross-session persistence for the Gaussian keyboard model. The new
// GaussianKeyModel fits directly from `[InputEventData]`, so this store
// persists a minimal per-tap snapshot — just the fields fit/exporter read —
// and re-fits on demand.
//
// Storage: `Documents/gaussian_taps.json`
// Layout: { "version": 2, "taps": [ {...}, {...}, … ] }

final class GaussianModelStore {

    static let shared = GaussianModelStore()

    // Minimal persistable projection of InputEventData. Anything the new
    // GaussianKeyModel.fit reads must be here (tap coords, key size,
    // keyLabel, expectedChar, actual/corrected chars, eventType, isCorrect).
    // Everything else is discarded — we don't need trial IDs or timestamps
    // to fit a Gaussian.
    struct PersistedTap: Codable {
        let eventType: InputEventType?
        let keyLabel: String
        let expectedChar: String
        let actualChar: String?
        let correctedChar: String?
        let tapLocalX: Double
        let tapLocalY: Double
        let keyWidth: Double
        let keyHeight: Double
        let isCorrect: Bool
    }

    private struct Payload: Codable {
        var version: Int
        var taps: [PersistedTap]
    }

    private let filename = "gaussian_taps.json"
    private let phaseBSnapshotFilename = "gaussian_taps_phase_b_snapshot.json"
    private let allowed: Set<String> = {
        var s = Set<String>()
        for c in "qwertyuiopasdfghjklzxcvbnm" { s.insert(String(c)) }
        s.insert("space")
        s.insert("delete")
        return s
    }()

    private init() {}

    // MARK: - Public API

    // Append a session's valid taps to the persistent corpus. Inserts train
    // the inferred intended key; delete taps train the delete target and act
    // as implicit correction feedback for nearby inserts.
    func update(with events: [InputEventData], annotations: [EditBehaviorAnnotation]? = nil) {
        var taps = loadTaps()
        let annByIndex: [Int: EditBehaviorAnnotation] = Dictionary(
            uniqueKeysWithValues: (annotations ?? []).map { ($0.eventIndex, $0) }
        )
        for (idx, e) in events.enumerated() {
            if let ann = annByIndex[idx],
               ann.category == "backspace_intent_change_or_cleanup" || ann.category == "cursor_move_intent_change_edit" {
                // Skip taps likely tied to explicit intent-change editing behavior.
                continue
            }
            guard !e.keyLabel.isEmpty,
                  allowed.contains(e.keyLabel),
                  e.keyWidth > 0, e.keyHeight > 0 else { continue }
            guard !KeystrokeCleaner.flag(e).isSpatialOutlier else { continue }
            taps.append(PersistedTap(
                eventType: e.eventType,
                keyLabel: e.keyLabel,
                expectedChar: e.expectedChar,
                actualChar: e.actualChar,
                correctedChar: e.correctedChar,
                tapLocalX: e.tapLocalX,
                tapLocalY: e.tapLocalY,
                keyWidth: e.keyWidth,
                keyHeight: e.keyHeight,
                isCorrect: e.isCorrect
            ))
        }
        save(taps)
    }

    // Reconstruct InputEventData envelopes from the persisted taps and
    // hand them to GaussianKeyModel.fit. The keys list must match what
    // the exporter / keyboard view will draw with.
    func loadModel(keys: [String]) -> GaussianKeyModel {
        let events = loadEvents()
        return GaussianKeyModel.fit(events: events, keys: keys)
    }

    // Same corpus the exporter wants — passes straight through to the
    // PDF pipeline so the raster, ellipses, and dots all see the same
    // history.
    func loadEvents() -> [InputEventData] {
        loadTaps().map { $0.asInputEvent() }
    }

    func totalSampleCount() -> Int { loadTaps().count }

    func reset() {
        try? FileManager.default.removeItem(at: fileURL())
        try? FileManager.default.removeItem(at: snapshotFileURL())
    }

    @discardableResult
    func savePhaseBSnapshot() -> Bool {
        let src = fileURL()
        let dst = snapshotFileURL()
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
                return true
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: - Storage

    private func fileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    private func snapshotFileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(phaseBSnapshotFilename)
    }

    private func loadTaps() -> [PersistedTap] {
        guard let data = try? Data(contentsOf: fileURL()) else { return [] }
        if let p = try? JSONDecoder().decode(Payload.self, from: data) {
            return p.taps
        }
        return []
    }

    private func save(_ taps: [PersistedTap]) {
        let payload = Payload(version: 3, taps: taps)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL(), options: .atomic)
    }
}

// MARK: - PersistedTap → InputEventData

private extension GaussianModelStore.PersistedTap {
    // Rebuild just enough of an InputEventData for GaussianKeyModel.fit
    // and GaussianKeyboardExporter — all other fields are stubbed.
    func asInputEvent() -> InputEventData {
        InputEventData(
            trialId: UUID(),
            sessionId: UUID(),
            studyId: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            eventType: eventType ?? .insert,
            replacementString: "",
            rangeStart: 0,
            rangeLength: 0,
            expectedIndex: 0,
            keyLabel: keyLabel,
            tapLocalX: tapLocalX,
            tapLocalY: tapLocalY,
            keyWidth: keyWidth,
            keyHeight: keyHeight,
            keyRow: "",
            keyCol: nil,
            expectedChar: expectedChar,
            actualChar: actualChar ?? (eventType == .delete ? "" : keyLabel),
            correctedChar: correctedChar ?? "",
            isCorrect: isCorrect,
            previousKeyLabel: "",
            textBefore: "",
            textAfter: "",
            interKeyIntervalMs: 0,
            sessionMode: "classic",
            studySessionIndex: 0,
            trialIndex: 0,
            editSource: "",
            editKind: "",
            originalText: "",
            emittedText: "",
            touchGestureJSON: "",
            suggestionsOffered: "",
            selectedSuggestion: ""
        )
    }
}
