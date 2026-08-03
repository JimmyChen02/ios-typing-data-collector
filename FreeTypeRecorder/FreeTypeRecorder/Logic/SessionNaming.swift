import Foundation

/// Builds the per-session folder / Drive leaf name "<name>,<trial>,<hand>"
/// (e.g. "Alex,3,left"), where trial is the global session number 1...10.
enum SessionNaming {
    static func folderName(name: String, number: Int, hand: HoldingHand) -> String {
        "\(sanitize(name)),\(number),\(hand.rawValue)"
    }

    /// The base "<name>,<trial>,<hand>" name, or that plus "_<suffix>" if a
    /// folder by the base name already exists — guards against overwriting a
    /// prior (e.g. abandoned) attempt at the same session number.
    static func uniqueFolderName(
        name: String,
        number: Int,
        hand: HoldingHand,
        exists: (String) -> Bool,
        suffix: () -> String = SessionNaming.timeSuffix
    ) -> String {
        let base = folderName(name: name, number: number, hand: hand)
        guard exists(base) else { return base }
        return "\(base)_\(suffix())"
    }

    static func timeSuffix() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }

    /// Removes characters that would break a folder path or the comma-delimited
    /// naming scheme (slashes and commas), and trims surrounding whitespace.
    private static func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/,"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
