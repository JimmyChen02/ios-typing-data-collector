import Foundation

// MARK: - KeystrokeCleaner
//
// Swift port of scripts/clean_keystrokes.py. Flags outliers on each event
// without discarding rows — downstream code can filter by `isOutlier` or by
// individual flags.
//
// Keep this file in sync with scripts/clean_keystrokes.py.

enum OutlierFlag: String {
    case spatial          // tap >½ key-width outside the HIT key
    case farFromTarget    = "far_from_target"  // tap >1.25 key-widths from EXPECTED key
    case ikiLow           = "iki_low"
    case ikiHigh          = "iki_high"
    case trialStart       = "trial_start"
    case deleteEvent      = "delete_event"
}

struct KeystrokeFlagResult {
    let tapNormX: Double
    let tapNormY: Double
    let distFromTargetKW: Double?    // nil when expected key is unknown
    let flags: [OutlierFlag]

    var isOutlier: Bool { !flags.isEmpty }
    // True only for taps that are physically implausible — used to clean CSV and Gaussian corpus.
    var isSpatialOutlier: Bool {
        flags.contains(.spatial) || flags.contains(.farFromTarget)
    }
    var flagsString: String { flags.map(\.rawValue).joined(separator: "|") }
}

enum KeystrokeCleaner {

    // Thresholds — mirror clean_keystrokes.py
    static let spatialMin: Double = -0.5
    static let spatialMax: Double =  1.5
    static let ikiMinMs:   Double =  50.0
    static let ikiMaxMs:   Double = 3000.0
    static let distMaxKW:  Double =  1.25

    // Keyboard layout in key-width units; row height = 1.35 key-widths.
    private static let rowH: Double = 1.35

    private struct Rect {
        let xmin: Double
        let ymin: Double
        let xmax: Double
        let ymax: Double
    }

    private static let keyRects: [String: Rect] = {
        var rects: [String: Rect] = [:]
        func row(_ keys: [String], xStart: Double, r: Int) {
            for (i, k) in keys.enumerated() {
                let x = xStart + Double(i)
                rects[k] = Rect(xmin: x, ymin: Double(r) * rowH,
                                xmax: x + 1.0, ymax: Double(r + 1) * rowH)
            }
        }
        row(["q","w","e","r","t","y","u","i","o","p"], xStart: 0.0, r: 0)
        row(["a","s","d","f","g","h","j","k","l"],     xStart: 0.5, r: 1)
        row(["z","x","c","v","b","n","m"],             xStart: 1.5, r: 2)
        rects["delete"] = Rect(xmin: 8.5, ymin: 2 * rowH, xmax: 10.0, ymax: 3 * rowH)
        rects["space"]  = Rect(xmin: 1.5, ymin: 3 * rowH, xmax:  8.5, ymax: 4 * rowH)
        return rects
    }()

    static func flag(_ e: InputEventData) -> KeystrokeFlagResult {
        var flags: [OutlierFlag] = []

        // Normalized tap position within the HIT key
        let normX = e.keyWidth  > 0 ? e.tapLocalX / e.keyWidth  : 0.5
        let normY = e.keyHeight > 0 ? e.tapLocalY / e.keyHeight : 0.5

        if !(spatialMin...spatialMax).contains(normX) ||
           !(spatialMin...spatialMax).contains(normY) {
            flags.append(.spatial)
        }

        // IKI — iki == 0 is handled by trial_start
        let iki = e.interKeyIntervalMs
        if iki < ikiMinMs && iki > 0 { flags.append(.ikiLow) }
        if iki > ikiMaxMs            { flags.append(.ikiHigh) }

        if e.textBefore.trimmingCharacters(in: .whitespaces).isEmpty {
            flags.append(.trialStart)
        }

        if e.eventType == .delete {
            flags.append(.deleteEvent)
        }

        // Distance from expected key, measured in key-widths
        var dist: Double? = nil
        if let expectedKey = expectedKey(from: e.expectedChar),
           let expRect = keyRects[expectedKey],
           let pos = tapAbsolutePosition(e)
        {
            let d = distanceToRect(x: pos.x, y: pos.y, rect: expRect)
            dist = d
            if d > distMaxKW { flags.append(.farFromTarget) }
        }

        return KeystrokeFlagResult(
            tapNormX: normX,
            tapNormY: normY,
            distFromTargetKW: dist,
            flags: flags
        )
    }

    // MARK: - Helpers

    private static func expectedKey(from raw: String) -> String? {
        if raw == " " { return "space" }
        let k = raw.lowercased()
        return keyRects[k] != nil ? k : nil
    }

    private static func tapAbsolutePosition(_ e: InputEventData) -> (x: Double, y: Double)? {
        let key = e.keyLabel.lowercased()
        guard let rect = keyRects[key],
              e.keyWidth > 0, e.keyHeight > 0
        else { return nil }
        let nx = e.tapLocalX / e.keyWidth
        let ny = e.tapLocalY / e.keyHeight
        let x = rect.xmin + nx * (rect.xmax - rect.xmin)
        let y = rect.ymin + ny * (rect.ymax - rect.ymin)
        return (x, y)
    }

    private static func distanceToRect(x: Double, y: Double, rect: Rect) -> Double {
        let dx = max(rect.xmin - x, 0.0, x - rect.xmax)
        let dy = max(rect.ymin - y, 0.0, y - rect.ymax)
        return (dx * dx + dy * dy).squareRoot()
    }
}
