import Foundation
import SwiftData

// MARK: - Enums

enum DominantHand: String, Codable, Sendable {
    case right
    case left
    case ambidextrous
}

enum InputEventType: String, Codable, Sendable {
    case insert
    case delete
    case replace
    case paste
}

// MARK: - Participant

@Model
final class Participant {
    var id: UUID
    var firstName: String
    var lastName: String
    var age: Int?
    var dominantHand: DominantHand
    var createdAt: Date
    var deviceModel: String
    var systemVersion: String
    var screenWidthPt: Double
    var screenHeightPt: Double
    var appVersion: String

    init(
        firstName: String,
        lastName: String,
        age: Int? = nil,
        dominantHand: DominantHand = .right,
        deviceModel: String,
        systemVersion: String,
        screenWidthPt: Double,
        screenHeightPt: Double,
        appVersion: String
    ) {
        self.id = UUID()
        self.firstName = firstName
        self.lastName = lastName
        self.age = age
        self.dominantHand = dominantHand
        self.createdAt = Date()
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.screenWidthPt = screenWidthPt
        self.screenHeightPt = screenHeightPt
        self.appVersion = appVersion
    }
}

// MARK: - Session

@Model
final class Session {
    var id: UUID
    var participantId: UUID
    var startedAt: Date
    var endedAt: Date?
    var totalTrials: Int
    var completedTrials: Int
    var meanAccuracy: Double
    var meanCharsPerSecond: Double
    var totalBackspaces: Int

    init(
        participantId: UUID,
        totalTrials: Int = 15
    ) {
        self.id = UUID()
        self.participantId = participantId
        self.startedAt = Date()
        self.endedAt = nil
        self.totalTrials = totalTrials
        self.completedTrials = 0
        self.meanAccuracy = 0.0
        self.meanCharsPerSecond = 0.0
        self.totalBackspaces = 0
    }
}

// MARK: - Trial

@Model
final class Trial {
    var id: UUID
    var sessionId: UUID
    var trialIndex: Int
    var targetText: String
    var finalText: String
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Double
    var backspaceCount: Int
    var insertCount: Int
    var correctChars: Int
    var totalTargetChars: Int
    var accuracy: Double
    var charsPerSecond: Double
    var wpm: Double

    init(
        sessionId: UUID,
        trialIndex: Int,
        targetText: String
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.trialIndex = trialIndex
        self.targetText = targetText
        self.finalText = ""
        self.startedAt = Date()
        self.endedAt = nil
        self.durationMs = 0.0
        self.backspaceCount = 0
        self.insertCount = 0
        self.correctChars = 0
        self.totalTargetChars = targetText.count
        self.accuracy = 0.0
        self.charsPerSecond = 0.0
        self.wpm = 0.0
    }
}

// MARK: - InputEvent

@Model
final class InputEvent {
    var id: UUID
    var trialId: UUID
    var timestamp: Date
    var eventType: InputEventType
    var replacementString: String
    var rangeStart: Int
    var rangeLength: Int
    var textBefore: String
    var textAfter: String
    var expectedIndex: Int
    var expectedChar: String
    var actualChar: String
    var isCorrect: Bool
    var interKeyIntervalMs: Double

    // Tap coordinate fields (populated by CustomKeyboardView)
    var tapLocalX: Double      // tap x within key, in points from key left edge
    var tapLocalY: Double      // tap y within key, in points from key top edge
    var tapNormX: Double       // tapLocalX / keyWidth (normalized 0-1)
    var tapNormY: Double       // tapLocalY / keyHeight (normalized 0-1)
    var keyLabel: String       // "a"-"z", "space", "delete"
    var keyScreenX: Double     // key origin x on screen (global coords)
    var keyScreenY: Double     // key origin y on screen (global coords)
    var keyWidth: Double       // key width in points
    var keyHeight: Double      // key height in points

    init(
        trialId: UUID,
        timestamp: Date,
        eventType: InputEventType,
        replacementString: String,
        rangeStart: Int,
        rangeLength: Int,
        textBefore: String,
        textAfter: String,
        expectedIndex: Int,
        expectedChar: String,
        actualChar: String,
        isCorrect: Bool,
        interKeyIntervalMs: Double,
        tapLocalX: Double = 0.0,
        tapLocalY: Double = 0.0,
        tapNormX: Double = 0.0,
        tapNormY: Double = 0.0,
        keyLabel: String = "",
        keyScreenX: Double = 0.0,
        keyScreenY: Double = 0.0,
        keyWidth: Double = 0.0,
        keyHeight: Double = 0.0
    ) {
        self.id = UUID()
        self.trialId = trialId
        self.timestamp = timestamp
        self.eventType = eventType
        self.replacementString = replacementString
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.expectedIndex = expectedIndex
        self.expectedChar = expectedChar
        self.actualChar = actualChar
        self.isCorrect = isCorrect
        self.interKeyIntervalMs = interKeyIntervalMs
        self.tapLocalX = tapLocalX
        self.tapLocalY = tapLocalY
        self.tapNormX = tapNormX
        self.tapNormY = tapNormY
        self.keyLabel = keyLabel
        self.keyScreenX = keyScreenX
        self.keyScreenY = keyScreenY
        self.keyWidth = keyWidth
        self.keyHeight = keyHeight
    }
}
