import Foundation
import Observation

/// The current participant's profile (name + demographics), entered once on
/// first launch (ParticipantSetupView) and persisted locally. Name is used to
/// file sessions under a same-named Drive subfolder; demographics + phone
/// type ride along in each session's `session_meta.json`. Also remembers
/// whether the one-time posture guide has been shown.
@MainActor
@Observable
final class ParticipantStore {
    static let shared = ParticipantStore()

    private enum Key {
        static let name = "FreeTypeRecorder.participantName"
        static let age = "FreeTypeRecorder.participantAge"
        static let sex = "FreeTypeRecorder.participantSex"
        static let dominantHand = "FreeTypeRecorder.participantDominantHand"
        static let seenPosture = "FreeTypeRecorder.hasSeenPostureGuide"
    }

    private let defaults: UserDefaults

    private(set) var name: String?
    private(set) var age: Int?
    private(set) var sex: Sex
    private(set) var dominantHand: DominantHand
    private(set) var hasSeenPostureGuide: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Key.name)
        let storedAge = defaults.integer(forKey: Key.age)
        age = defaults.object(forKey: Key.age) == nil ? nil : storedAge
        sex = Sex(rawValue: defaults.string(forKey: Key.sex) ?? "") ?? .preferNotToSay
        dominantHand = DominantHand(rawValue: defaults.string(forKey: Key.dominantHand) ?? "") ?? .right
        hasSeenPostureGuide = defaults.bool(forKey: Key.seenPosture)
    }

    func setProfile(name: String, age: Int?, sex: Sex, dominantHand: DominantHand) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: Key.name)
        if let age { defaults.set(age, forKey: Key.age) } else { defaults.removeObject(forKey: Key.age) }
        defaults.set(sex.rawValue, forKey: Key.sex)
        defaults.set(dominantHand.rawValue, forKey: Key.dominantHand)
        self.name = trimmed
        self.age = age
        self.sex = sex
        self.dominantHand = dominantHand
    }

    /// Drive base-folder name: "<name> - <phone model>", so each participant's
    /// data is filed per person and device (e.g. "Alex - iPhone 15 Pro").
    var driveFolderName: String {
        "\(name ?? "Unknown") - \(DeviceInfo.modelName)"
    }

    func markPostureGuideSeen() {
        defaults.set(true, forKey: Key.seenPosture)
        hasSeenPostureGuide = true
    }

    /// Resets the gate so ContentView shows setup again — e.g. handing the
    /// device to a different participant. Clears demographics + posture flag.
    func clear() {
        [Key.name, Key.age, Key.sex, Key.dominantHand, Key.seenPosture].forEach {
            defaults.removeObject(forKey: $0)
        }
        name = nil
        age = nil
        sex = .preferNotToSay
        dominantHand = .right
        hasSeenPostureGuide = false
    }
}
