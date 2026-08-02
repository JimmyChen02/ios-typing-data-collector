import Foundation
import Observation

/// Drives the guided pilot: fixed quotas (Left 3 / Right 3 / Both 4 = 10),
/// a per-participant shuffled prompt order (no repeats), and global session
/// numbering 1…10 in completion order. Persisted so a run survives app
/// relaunch. Single source of truth for the study home + recorder.
@MainActor
@Observable
final class StudyProtocol {
    struct CompletedSession: Codable, Equatable {
        let number: Int
        let hand: String
        let prompt: String
    }

    static let shared = StudyProtocol()
    static let totalSessions = 10

    /// Ordered so `availableConditions` reads Left, Right, Both.
    private static let quotaTable: [(hand: HoldingHand, count: Int)] =
        [(.left, 3), (.right, 3), (.both, 4)]

    private static let promptOrderKey = "FreeTypeRecorder.promptOrder"
    private static let completedKey = "FreeTypeRecorder.completedSessions"

    private let defaults: UserDefaults
    private(set) var promptOrder: [String]
    private(set) var completed: [CompletedSession]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.promptOrder = Self.decode([String].self, from: defaults, key: Self.promptOrderKey)
            ?? PromptBank.prompts
        self.completed = Self.decode([CompletedSession].self, from: defaults, key: Self.completedKey)
            ?? []
    }

    // MARK: Derived state
    var completedCount: Int { completed.count }
    var isComplete: Bool { completedCount >= Self.totalSessions }
    var nextSessionNumber: Int { completedCount + 1 }

    func quota(for hand: HoldingHand) -> Int {
        Self.quotaTable.first { $0.hand == hand }?.count ?? 0
    }
    func completedCount(for hand: HoldingHand) -> Int {
        completed.filter { $0.hand == hand.rawValue }.count
    }
    func remaining(for hand: HoldingHand) -> Int {
        max(quota(for: hand) - completedCount(for: hand), 0)
    }
    var availableConditions: [HoldingHand] {
        Self.quotaTable.map(\.hand).filter { remaining(for: $0) > 0 }
    }

    /// Prompt for the next not-yet-recorded session.
    func promptForNextSession() -> String {
        guard completedCount < promptOrder.count else {
            return promptOrder.last ?? PromptBank.prompts[0]
        }
        return promptOrder[completedCount]
    }

    // MARK: Mutations
    /// Begin a fresh run for a new participant: new shuffled prompt order,
    /// no completed sessions.
    func startNewParticipant() {
        var rng = SystemRandomNumberGenerator()
        promptOrder = PromptBank.shuffledOrder(using: &rng)
        completed = []
        persist()
    }

    /// Record that the current session (`nextSessionNumber`, `promptForNextSession()`)
    /// was completed with `hand`. No-op if the study is complete or `hand`
    /// has no remaining quota.
    func recordCompletion(hand: HoldingHand) {
        guard !isComplete, remaining(for: hand) > 0 else { return }
        completed.append(CompletedSession(
            number: nextSessionNumber,
            hand: hand.rawValue,
            prompt: promptForNextSession()
        ))
        persist()
    }

    // MARK: Persistence
    private func persist() {
        if let data = try? JSONEncoder().encode(promptOrder) {
            defaults.set(data, forKey: Self.promptOrderKey)
        }
        if let data = try? JSONEncoder().encode(completed) {
            defaults.set(data, forKey: Self.completedKey)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
