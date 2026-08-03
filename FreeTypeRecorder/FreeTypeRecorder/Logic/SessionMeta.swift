import Foundation

/// Per-session metadata written to `session_meta.json` in the session folder
/// and uploaded to Drive with the rest of the session's files. Carries the
/// participant demographics, auto-detected phone type, and the session's
/// number + prompt for later analysis.
struct SessionMeta: Codable, Equatable {
    let participant: String
    let hand: String
    let startedAt: String
    let age: Int?
    let sex: String
    let dominantHand: String
    let deviceModel: String
    let deviceModelIdentifier: String
    let systemVersion: String
    let appVersion: String
    let sessionNumber: Int
    let prompt: String
}
