import Foundation
import SwiftData

// MARK: - HoldingHand

enum HoldingHand: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case both
    case unknown

    var displayName: String {
        switch self {
        case .left:    return "Left hand"
        case .right:   return "Right hand"
        case .both:    return "Both hands"
        case .unknown: return "Unknown"
        }
    }

    /// Returns a reasonable default holding-hand label given the participant's
    /// stated dominant hand. Ambidextrous maps to .unknown so the picker stays
    /// editable without a misleading pre-selection.
    static func suggested(for hand: DominantHand) -> HoldingHand {
        switch hand {
        case .left:          return .left
        case .right:         return .right
        case .ambidextrous:  return .unknown
        }
    }
}

// MARK: - HandSample

/// One labeled holding-hand observation. Persisted in SwiftData; the
/// corresponding JPEG (if captured) lives at
/// `Documents/<imageRelativePath>`.
@Model
final class HandSample {
    var id: UUID
    var participantId: UUID
    var sessionId: UUID?          // nil if captured outside a session
    var studyId: UUID
    var studySessionIndex: Int    // 0-based; -1 if not session-scoped
    var capturedAt: Date
    var holdingHand: HoldingHand
    var imageRelativePath: String // relative to Documents/; "" if no photo
    var imuRelativePath: String   // relative to Documents/; "" if no IMU CSV
    var imagePixelWidth: Int
    var imagePixelHeight: Int
    var cameraPosition: String    // "front" (forward-compat for back-cam)
    var deviceModel: String
    var systemVersion: String
    var notes: String

    init(
        participantId: UUID,
        sessionId: UUID? = nil,
        studyId: UUID,
        studySessionIndex: Int = -1,
        capturedAt: Date = Date(),
        holdingHand: HoldingHand = .unknown,
        imageRelativePath: String = "",
        imuRelativePath: String = "",
        imagePixelWidth: Int = 0,
        imagePixelHeight: Int = 0,
        cameraPosition: String = "front",
        deviceModel: String = "",
        systemVersion: String = "",
        notes: String = ""
    ) {
        self.id = UUID()
        self.participantId = participantId
        self.sessionId = sessionId
        self.studyId = studyId
        self.studySessionIndex = studySessionIndex
        self.capturedAt = capturedAt
        self.holdingHand = holdingHand
        self.imageRelativePath = imageRelativePath
        self.imuRelativePath = imuRelativePath
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.cameraPosition = cameraPosition
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.notes = notes
    }
}
