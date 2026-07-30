import Foundation

/// Mirrors TypingResearch's HoldingHand enum exactly — raw values must
/// match the bundled Core ML model's class labels.
enum HoldingHand: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case both
    case unknown

    var displayName: String {
        switch self {
        case .left: return "Left hand"
        case .right: return "Right hand"
        case .both: return "Both hands"
        case .unknown: return "Unknown"
        }
    }
}

extension HoldingHand: Identifiable {
    var id: String { rawValue }
}
