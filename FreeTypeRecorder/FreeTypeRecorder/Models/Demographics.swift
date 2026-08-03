import Foundation

enum Sex: String, Codable, CaseIterable, Identifiable {
    case male, female, preferNotToSay
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .preferNotToSay: return "Prefer not to say"
        }
    }
}

/// The participant's real handedness (a demographic) — distinct from the
/// per-session holding-hand condition (`HoldingHand`).
enum DominantHand: String, Codable, CaseIterable, Identifiable {
    case left, right, ambidextrous
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .ambidextrous: return "Ambidextrous"
        }
    }
}
