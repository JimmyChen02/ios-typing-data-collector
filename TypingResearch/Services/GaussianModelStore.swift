import Foundation

// MARK: - GaussianModelStore
//
// Cross-session persistence for the Gaussian keyboard model. The new
// GaussianKeyModel fits directly from `[InputEventData]` (correct taps
// only), so this store persists a minimal per-tap snapshot — just the
// fields fit/exporter read — and re-fits on demand.
//
// Storage: `Documents/gaussian_taps.json`
// Layout: { "version": 2, "taps": [ {...}, {...}, … ] }

final class GaussianModelStore {

    static let shared = GaussianModelStore()

    // Minimal persistable projection of InputEventData. Anything the new
    // GaussianKeyModel.fit reads must be here (tap coords, key size,
    // keyLabel, isCorrect). Everything else is discarded — we don't need
    // trial IDs or timestamps to fit a Gaussian.
    struct PersistedTap: Codable {
        let keyLabel: String
        let expectedChar: String
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
    private let allowed: Set<String> = {
        var s = Set<String>()
        for c in "qwertyuiopasdfghjklzxcvbnm" { s.insert(String(c)) }
        s.insert("space")
        s.insert("delete")
        return s
    }()

    private init() {}

    // MARK: - Public API

    // Append a session's valid insert taps (correct OR mistap) to the
    // persistent corpus. The fit itself filters to correct taps — we keep
    // all so a future threshold change can rebuild without losing data.
    func update(with events: [InputEventData]) {
        var taps = loadTaps()
        for e in events where e.eventType != .delete {
            guard !e.keyLabel.isEmpty,
                  allowed.contains(e.keyLabel),
                  e.keyWidth > 0, e.keyHeight > 0 else { continue }
            taps.append(PersistedTap(
                keyLabel: e.keyLabel,
                expectedChar: e.expectedChar,
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
    }

    // MARK: - Storage

    private func fileURL() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    private func loadTaps() -> [PersistedTap] {
        guard let data = try? Data(contentsOf: fileURL()) else { return [] }
        if let p = try? JSONDecoder().decode(Payload.self, from: data) {
            return p.taps
        }
        return []
    }

    private func save(_ taps: [PersistedTap]) {
        let payload = Payload(version: 2, taps: taps)
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
            timestamp: Date(timeIntervalSince1970: 0),
            eventType: .insert,
            keyLabel: keyLabel,
            tapLocalX: tapLocalX,
            tapLocalY: tapLocalY,
            keyWidth: keyWidth,
            keyHeight: keyHeight,
            keyRow: "",
            keyCol: nil,
            expectedChar: expectedChar,
            actualChar: keyLabel,
            correctedChar: "",
            isCorrect: isCorrect,
            previousKeyLabel: "",
            textBefore: "",
            textAfter: "",
            interKeyIntervalMs: 0
        )
    }
}
