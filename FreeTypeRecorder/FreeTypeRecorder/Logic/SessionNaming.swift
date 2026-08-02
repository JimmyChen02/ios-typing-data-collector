import Foundation

/// Builds the per-session folder/Drive leaf name "NN_hand" (e.g. "03_left").
enum SessionNaming {
    static func folderName(number: Int, hand: HoldingHand) -> String {
        String(format: "%02d_%@", number, hand.rawValue)
    }

    /// The base "NN_hand" name, or "NN_hand_<suffix>" if a folder by the base
    /// name already exists — guards against overwriting a prior (e.g.
    /// abandoned) attempt at the same session number.
    static func uniqueFolderName(
        number: Int,
        hand: HoldingHand,
        exists: (String) -> Bool,
        suffix: () -> String = SessionNaming.timeSuffix
    ) -> String {
        let base = folderName(number: number, hand: hand)
        guard exists(base) else { return base }
        return "\(base)_\(suffix())"
    }

    static func timeSuffix() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }
}
