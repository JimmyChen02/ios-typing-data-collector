import Foundation

/// The fixed set of free-typing prompts. Each participant gets a shuffled
/// order (StudyProtocol), and a prompt is never shown twice within a run.
enum PromptBank {
    static let prompts: [String] = [
        "What did you eat today, and did you like it?",
        "What did you do today?",
        "What was your morning routine like?",
        "Describe the last movie or show you watched.",
        "What's your favorite place you've traveled to, and why?",
        "What are you planning to do this weekend?",
        "Describe your ideal meal.",
        "What's a hobby you enjoy, and what got you into it?",
        "What did you have for breakfast?",
        "Who did you talk to today?",
        "What's the weather like where you are right now?",
        "Describe your walk or commute today.",
    ]

    static func shuffledOrder<G: RandomNumberGenerator>(using generator: inout G) -> [String] {
        prompts.shuffled(using: &generator)
    }
}
