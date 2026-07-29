import Foundation
import CoreGraphics
import CryptoKit
import Security

public enum AdaptiveKeyboardConstants {
    public static let appGroup = "group.edu.cornell.ab3235.typingresearch"
    public static var keychainGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "SharedKeychainAccessGroup") as? String
            ?? "LJM55B5N37.edu.cornell.ab3235.typingresearch.shared"
    }
    public static let schemaVersion = 6
    public static let letterKeys = Array("qwertyuiopasdfghjklzxcvbnm").map(String.init)
}

public enum KeyboardLayoutMode: String, Codable, Hashable, Sendable {
    case letters
    case numbers
    case symbols
    case emoji
}

public enum OneHandedMode: String, Codable, Hashable, Sendable {
    case off
    case left
    case right
}

public enum KeyboardShiftState: String, Codable, Hashable, Sendable {
    case lowercase
    case uppercase
    case capsLock
}

public enum KeyboardOrientation: String, Codable, Hashable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case unknown
}

public enum TouchPhase: String, Codable, Hashable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public struct CodablePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct TouchTarget: Codable, Hashable, Sendable {
    public var identifier: String
    public var key: String?
    public var frame: CodableRect?

    public init(identifier: String, key: String? = nil, frame: CodableRect? = nil) {
        self.identifier = identifier
        self.key = key
        self.frame = frame
    }
}

public struct TouchSample: Codable, Hashable, Sendable {
    public var phase: TouchPhase
    public var wallTimestamp: Date?
    public var monotonicTimestamp: Double?
    public var absolutePosition: CodablePoint?
    public var preciseAbsolutePosition: CodablePoint?
    public var localPosition: CodablePoint?
    public var normalizedPosition: CodablePoint?
    public var radius: Double?
    public var radiusTolerance: Double?
    public var force: Double?
    public var maximumForce: Double?
    public var touchType: Int?
    public var target: TouchTarget?

    public init(
        phase: TouchPhase,
        wallTimestamp: Date? = nil,
        monotonicTimestamp: Double? = nil,
        absolutePosition: CodablePoint? = nil,
        preciseAbsolutePosition: CodablePoint? = nil,
        localPosition: CodablePoint? = nil,
        normalizedPosition: CodablePoint? = nil,
        radius: Double? = nil,
        radiusTolerance: Double? = nil,
        force: Double? = nil,
        maximumForce: Double? = nil,
        touchType: Int? = nil,
        target: TouchTarget? = nil
    ) {
        self.phase = phase
        self.wallTimestamp = wallTimestamp
        self.monotonicTimestamp = monotonicTimestamp
        self.absolutePosition = absolutePosition
        self.preciseAbsolutePosition = preciseAbsolutePosition
        self.localPosition = localPosition
        self.normalizedPosition = normalizedPosition
        self.radius = radius
        self.radiusTolerance = radiusTolerance
        self.force = force
        self.maximumForce = maximumForce
        self.touchType = touchType
        self.target = target
    }
}

public struct TouchGesture: Codable, Hashable, Sendable {
    public var id: UUID
    public var samples: [TouchSample]
    public var initialTarget: TouchTarget?
    public var finalTarget: TouchTarget?
    public var selectedFrame: CodableRect?
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationMilliseconds: Double?
    public var wasCancelled: Bool
    public var didSlide: Bool

    public init(
        id: UUID = UUID(),
        samples: [TouchSample] = [],
        initialTarget: TouchTarget? = nil,
        finalTarget: TouchTarget? = nil,
        selectedFrame: CodableRect? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationMilliseconds: Double? = nil,
        wasCancelled: Bool = false,
        didSlide: Bool = false
    ) {
        self.id = id
        self.samples = samples
        self.initialTarget = initialTarget
        self.finalTarget = finalTarget
        self.selectedFrame = selectedFrame
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.wasCancelled = wasCancelled
        self.didSlide = didSlide
    }
}

public enum EditOperationType: String, Codable, Hashable, Sendable {
    case insert
    case delete
    case replace
    case cursorMove
    case unknown
}

public enum EditSource: String, Codable, Hashable, Sendable {
    case key
    case gesture
    case candidate
    case autocorrection
    case correctionReversion
    case smartPunctuation
    case emoji
    case external
    case unknown
}

public enum EditTrigger: String, Codable, Hashable, Sendable {
    case touch
    case repeatDelete
    case candidateSelection
    case wordBoundary
    case textDidChange
    case programmatic
    case unknown
}

public struct EditOperation: Codable, Hashable, Sendable {
    public var id: UUID
    public var type: EditOperationType
    public var source: EditSource
    public var trigger: EditTrigger?
    public var contextBefore: String?
    public var contextAfter: String?
    public var originalText: String?
    public var replacementText: String?
    public var deletedText: String?
    public var gestureID: UUID?
    public var parentEventID: UUID?
    public var predictionOfferID: UUID?
    public var correctionID: UUID?

    public init(
        id: UUID = UUID(),
        type: EditOperationType,
        source: EditSource,
        trigger: EditTrigger? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        originalText: String? = nil,
        replacementText: String? = nil,
        deletedText: String? = nil,
        gestureID: UUID? = nil,
        parentEventID: UUID? = nil,
        predictionOfferID: UUID? = nil,
        correctionID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.source = source
        self.trigger = trigger
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.originalText = originalText
        self.replacementText = replacementText
        self.deletedText = deletedText
        self.gestureID = gestureID
        self.parentEventID = parentEventID
        self.predictionOfferID = predictionOfferID
        self.correctionID = correctionID
    }
}

public enum PredictionOutcomeKind: String, Codable, Hashable, Sendable {
    case previewShown
    case accepted
    case ignored
    case replaced
    case reverted
}

public struct ModelProvenance: Codable, Hashable, Sendable {
    public var identifier: String
    public var version: String?
    public var artifact: String?
    public var sourceCommit: String?

    public init(
        identifier: String,
        version: String? = nil,
        artifact: String? = nil,
        sourceCommit: String? = nil
    ) {
        self.identifier = identifier
        self.version = version
        self.artifact = artifact
        self.sourceCommit = sourceCommit
    }
}

public struct PredictionOffer: Codable, Hashable, Sendable {
    public var id: UUID
    public var candidates: [DecoderCandidate]
    public var literalCandidateID: String?
    public var model: ModelProvenance?
    public var offeredAt: Date?

    public init(
        id: UUID = UUID(),
        candidates: [DecoderCandidate],
        literalCandidateID: String? = nil,
        model: ModelProvenance? = nil,
        offeredAt: Date? = nil
    ) {
        self.id = id
        self.candidates = candidates
        self.literalCandidateID = literalCandidateID
        self.model = model
        self.offeredAt = offeredAt
    }
}

public struct PredictionOutcome: Codable, Hashable, Sendable {
    public var offerID: UUID
    public var kind: PredictionOutcomeKind
    public var selectedCandidateID: String?
    public var correctionID: UUID?
    public var occurredAt: Date?

    public init(
        offerID: UUID,
        kind: PredictionOutcomeKind,
        selectedCandidateID: String? = nil,
        correctionID: UUID? = nil,
        occurredAt: Date? = nil
    ) {
        self.offerID = offerID
        self.kind = kind
        self.selectedCandidateID = selectedCandidateID
        self.correctionID = correctionID
        self.occurredAt = occurredAt
    }
}

public struct KeyboardLatency: Codable, Hashable, Sendable {
    public var touchDurationMilliseconds: Double?
    public var interEventMilliseconds: Double?
    public var proxyMutationMilliseconds: Double?
    public var decoderMilliseconds: Double?
    public var actionTotalMilliseconds: Double?
    public var offerToSelectionMilliseconds: Double?

    public init(
        touchDurationMilliseconds: Double? = nil,
        interEventMilliseconds: Double? = nil,
        proxyMutationMilliseconds: Double? = nil,
        decoderMilliseconds: Double? = nil,
        actionTotalMilliseconds: Double? = nil,
        offerToSelectionMilliseconds: Double? = nil
    ) {
        self.touchDurationMilliseconds = touchDurationMilliseconds
        self.interEventMilliseconds = interEventMilliseconds
        self.proxyMutationMilliseconds = proxyMutationMilliseconds
        self.decoderMilliseconds = decoderMilliseconds
        self.actionTotalMilliseconds = actionTotalMilliseconds
        self.offerToSelectionMilliseconds = offerToSelectionMilliseconds
    }
}

public struct KeyboardKeyGeometry: Codable, Hashable, Sendable {
    public var identifier: String
    public var label: String?
    public var frame: CodableRect

    public init(identifier: String, label: String? = nil, frame: CodableRect) {
        self.identifier = identifier
        self.label = label
        self.frame = frame
    }
}

public struct KeyboardLayoutSnapshot: Codable, Hashable, Sendable {
    public var id: UUID
    public var layout: KeyboardLayoutMode
    public var keyboardBounds: CodableRect
    public var screenBounds: CodableRect?
    public var keyGeometries: [KeyboardKeyGeometry]
    public var candidateBarFrame: CodableRect?
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        layout: KeyboardLayoutMode,
        keyboardBounds: CodableRect,
        screenBounds: CodableRect? = nil,
        keyGeometries: [KeyboardKeyGeometry] = [],
        candidateBarFrame: CodableRect? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.layout = layout
        self.keyboardBounds = keyboardBounds
        self.screenBounds = screenBounds
        self.keyGeometries = keyGeometries
        self.candidateBarFrame = candidateBarFrame
        self.createdAt = createdAt
    }
}

public struct KeyboardSettingsSnapshot: Codable, Hashable, Sendable {
    public var autoCapitalizationEnabled: Bool?
    public var autocorrectionEnabled: Bool?
    public var predictiveEnabled: Bool?
    public var characterPreviewEnabled: Bool?
    public var capsLockEnabled: Bool?
    public var smartPunctuationEnabled: Bool?

    public init(
        autoCapitalizationEnabled: Bool? = nil,
        autocorrectionEnabled: Bool? = nil,
        predictiveEnabled: Bool? = nil,
        characterPreviewEnabled: Bool? = nil,
        capsLockEnabled: Bool? = nil,
        smartPunctuationEnabled: Bool? = nil
    ) {
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.autocorrectionEnabled = autocorrectionEnabled
        self.predictiveEnabled = predictiveEnabled
        self.characterPreviewEnabled = characterPreviewEnabled
        self.capsLockEnabled = capsLockEnabled
        self.smartPunctuationEnabled = smartPunctuationEnabled
    }
}

public struct TextFieldTraitsSnapshot: Codable, Hashable, Sendable {
    public var keyboardType: Int?
    public var returnKeyType: Int?
    public var autocapitalizationType: Int?
    public var autocorrectionType: Int?
    public var spellCheckingType: Int?
    public var enablesReturnKeyAutomatically: Bool?
    public var isSecureTextEntry: Bool?

    public init(
        keyboardType: Int? = nil,
        returnKeyType: Int? = nil,
        autocapitalizationType: Int? = nil,
        autocorrectionType: Int? = nil,
        spellCheckingType: Int? = nil,
        enablesReturnKeyAutomatically: Bool? = nil,
        isSecureTextEntry: Bool? = nil
    ) {
        self.keyboardType = keyboardType
        self.returnKeyType = returnKeyType
        self.autocapitalizationType = autocapitalizationType
        self.autocorrectionType = autocorrectionType
        self.spellCheckingType = spellCheckingType
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
        self.isSecureTextEntry = isSecureTextEntry
    }
}

public struct KeyboardEnvironmentSnapshot: Codable, Hashable, Sendable {
    public var orientation: KeyboardOrientation?
    public var oneHandedMode: OneHandedMode?
    public var shiftState: KeyboardShiftState?
    public var candidateBarVisible: Bool?
    public var settings: KeyboardSettingsSnapshot?
    public var deviceModel: String?
    public var screenScale: Double?
    public var operatingSystemVersion: String?
    public var appVersion: String?
    public var fieldTraits: TextFieldTraitsSnapshot?
    public var hasContextBefore: Bool?
    public var hasContextAfter: Bool?
    public var isRecording: Bool?

    public init(
        orientation: KeyboardOrientation? = nil,
        oneHandedMode: OneHandedMode? = nil,
        shiftState: KeyboardShiftState? = nil,
        candidateBarVisible: Bool? = nil,
        settings: KeyboardSettingsSnapshot? = nil,
        deviceModel: String? = nil,
        screenScale: Double? = nil,
        operatingSystemVersion: String? = nil,
        appVersion: String? = nil,
        fieldTraits: TextFieldTraitsSnapshot? = nil,
        hasContextBefore: Bool? = nil,
        hasContextAfter: Bool? = nil,
        isRecording: Bool? = nil
    ) {
        self.orientation = orientation
        self.oneHandedMode = oneHandedMode
        self.shiftState = shiftState
        self.candidateBarVisible = candidateBarVisible
        self.settings = settings
        self.deviceModel = deviceModel
        self.screenScale = screenScale
        self.operatingSystemVersion = operatingSystemVersion
        self.appVersion = appVersion
        self.fieldTraits = fieldTraits
        self.hasContextBefore = hasContextBefore
        self.hasContextAfter = hasContextAfter
        self.isRecording = isRecording
    }
}

public enum KeyboardEventKind: String, Codable, Hashable, Sendable {
    case touch
    case insert
    case delete
    case candidateShown
    case suggestionAccepted
    // Legacy schema-v5 value retained only to decode previously recorded events.
    case inlinePredictionAccepted
    case autocorrectAccepted
    case autocorrectReverted
    case cursorMoved
    case layoutChanged
    case externalMutation
    case recordingChanged
}

public struct DecoderCandidate: Codable, Hashable, Sendable {
    public var stableID: String?
    public var rank: Int?
    public var text: String
    public var score: Double
    public var languageScore: Double
    public var isLiteral: Bool

    public init(
        text: String,
        score: Double,
        languageScore: Double = 0,
        isLiteral: Bool = false,
        stableID: String? = nil,
        rank: Int? = nil
    ) {
        self.stableID = stableID
        self.rank = rank
        self.text = text
        self.score = score
        self.languageScore = languageScore
        self.isLiteral = isLiteral
    }
}

public struct KeyboardResearchEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var schemaVersion: Int
    public var timestamp: Date
    public var sessionID: UUID
    public var kind: KeyboardEventKind
    public var layout: KeyboardLayoutMode
    public var key: String?
    public var emittedText: String?
    public var rawContext: String?
    public var contextHash: String?
    public var touchX: Double?
    public var touchY: Double?
    public var preciseTouchX: Double?
    public var preciseTouchY: Double?
    public var touchRadius: Double?
    public var touchRadiusTolerance: Double?
    public var touchForce: Double?
    public var touchMaximumForce: Double?
    public var touchTimestamp: Double?
    public var touchType: Int?
    public var keyFrame: CodableRect?
    public var candidates: [DecoderCandidate]?
    public var selectedCandidate: String?
    public var latencyMilliseconds: Double?
    public var metadata: [String: String]
    public var sequenceNumber: UInt64?
    public var parentEventID: UUID?
    public var gestureID: UUID?
    public var editID: UUID?
    public var predictionOfferID: UUID?
    public var correctionID: UUID?
    public var touchGesture: TouchGesture?
    public var editOperation: EditOperation?
    public var predictionOffer: PredictionOffer?
    public var predictionOutcome: PredictionOutcome?
    public var latency: KeyboardLatency?
    public var environment: KeyboardEnvironmentSnapshot?
    public var layoutSnapshotID: UUID?
    public var layoutSnapshot: KeyboardLayoutSnapshot?
    public var modelProvenance: ModelProvenance?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID,
        kind: KeyboardEventKind,
        layout: KeyboardLayoutMode,
        key: String? = nil,
        emittedText: String? = nil,
        rawContext: String? = nil,
        contextHash: String? = nil,
        touchX: Double? = nil,
        touchY: Double? = nil,
        preciseTouchX: Double? = nil,
        preciseTouchY: Double? = nil,
        touchRadius: Double? = nil,
        touchRadiusTolerance: Double? = nil,
        touchForce: Double? = nil,
        touchMaximumForce: Double? = nil,
        touchTimestamp: Double? = nil,
        touchType: Int? = nil,
        keyFrame: CodableRect? = nil,
        candidates: [DecoderCandidate]? = nil,
        selectedCandidate: String? = nil,
        latencyMilliseconds: Double? = nil,
        metadata: [String: String] = [:],
        sequenceNumber: UInt64? = nil,
        parentEventID: UUID? = nil,
        gestureID: UUID? = nil,
        editID: UUID? = nil,
        predictionOfferID: UUID? = nil,
        correctionID: UUID? = nil,
        touchGesture: TouchGesture? = nil,
        editOperation: EditOperation? = nil,
        predictionOffer: PredictionOffer? = nil,
        predictionOutcome: PredictionOutcome? = nil,
        latency: KeyboardLatency? = nil,
        environment: KeyboardEnvironmentSnapshot? = nil,
        layoutSnapshotID: UUID? = nil,
        layoutSnapshot: KeyboardLayoutSnapshot? = nil,
        modelProvenance: ModelProvenance? = nil
    ) {
        self.id = id
        self.schemaVersion = AdaptiveKeyboardConstants.schemaVersion
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.kind = kind
        self.layout = layout
        self.key = key
        self.emittedText = emittedText
        self.rawContext = rawContext
        self.contextHash = contextHash
        self.touchX = touchX
        self.touchY = touchY
        self.preciseTouchX = preciseTouchX
        self.preciseTouchY = preciseTouchY
        self.touchRadius = touchRadius
        self.touchRadiusTolerance = touchRadiusTolerance
        self.touchForce = touchForce
        self.touchMaximumForce = touchMaximumForce
        self.touchTimestamp = touchTimestamp
        self.touchType = touchType
        self.keyFrame = keyFrame
        self.candidates = candidates
        self.selectedCandidate = selectedCandidate
        self.latencyMilliseconds = latencyMilliseconds
        self.metadata = metadata
        self.sequenceNumber = sequenceNumber
        self.parentEventID = parentEventID
        self.gestureID = gestureID
        self.editID = editID
        self.predictionOfferID = predictionOfferID
        self.correctionID = correctionID
        self.touchGesture = touchGesture
        self.editOperation = editOperation
        self.predictionOffer = predictionOffer
        self.predictionOutcome = predictionOutcome
        self.latency = latency
        self.environment = environment
        self.layoutSnapshotID = layoutSnapshotID
        self.layoutSnapshot = layoutSnapshot
        self.modelProvenance = modelProvenance
    }
}

public struct CodableRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public final class SharedKeyboardPreferences {
    public static let shared = SharedKeyboardPreferences()

    private enum Key {
        static let recordingPaused = "keyboard.recordingPaused"
        static let retentionDays = "keyboard.retentionDays"
        static let lastRetentionPurge = "keyboard.lastRetentionPurge"
        static let autoCapitalization = "keyboard.autoCapitalization"
        static let autocorrection = "keyboard.autocorrection"
        static let predictive = "keyboard.predictive"
        static let characterPreview = "keyboard.characterPreview"
        static let capsLock = "keyboard.capsLock"
        static let smartPunctuation = "keyboard.smartPunctuation"
        static let oneHandedMode = "keyboard.oneHandedMode"
        static let recentEmoji = "keyboard.recentEmoji"
    }

    /// Toggles that default to on, mirroring Settings → General → Keyboard.
    private static let defaultOnKeys = [
        Key.autoCapitalization,
        Key.autocorrection,
        Key.predictive,
        Key.characterPreview,
        Key.capsLock,
        Key.smartPunctuation
    ]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        let sharedDefaults: UserDefaults? = {
            // Avoid CFPreferences warnings when the App Group container is not yet
            // available in this process (common during extension startup/simulator).
            guard FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AdaptiveKeyboardConstants.appGroup
            ) != nil else {
                return nil
            }
            return UserDefaults(suiteName: AdaptiveKeyboardConstants.appGroup)
        }()
        self.defaults = defaults ?? sharedDefaults ?? .standard
        if self.defaults.object(forKey: Key.retentionDays) == nil {
            self.defaults.set(30, forKey: Key.retentionDays)
        }
        for key in Self.defaultOnKeys where self.defaults.object(forKey: key) == nil {
            self.defaults.set(true, forKey: key)
        }
    }

    public var autoCapitalizationEnabled: Bool {
        get { defaults.bool(forKey: Key.autoCapitalization) }
        set { defaults.set(newValue, forKey: Key.autoCapitalization) }
    }

    public var autocorrectionEnabled: Bool {
        get { defaults.bool(forKey: Key.autocorrection) }
        set { defaults.set(newValue, forKey: Key.autocorrection) }
    }

    public var predictiveEnabled: Bool {
        get { defaults.bool(forKey: Key.predictive) }
        set { defaults.set(newValue, forKey: Key.predictive) }
    }

    public var characterPreviewEnabled: Bool {
        get { defaults.bool(forKey: Key.characterPreview) }
        set { defaults.set(newValue, forKey: Key.characterPreview) }
    }

    public var capsLockEnabled: Bool {
        get { defaults.bool(forKey: Key.capsLock) }
        set { defaults.set(newValue, forKey: Key.capsLock) }
    }

    public var smartPunctuationEnabled: Bool {
        get { defaults.bool(forKey: Key.smartPunctuation) }
        set { defaults.set(newValue, forKey: Key.smartPunctuation) }
    }

    public var oneHandedMode: OneHandedMode {
        get {
            defaults.string(forKey: Key.oneHandedMode)
                .flatMap(OneHandedMode.init(rawValue:)) ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: Key.oneHandedMode) }
    }

    public var recentEmoji: [String] {
        get { defaults.stringArray(forKey: Key.recentEmoji) ?? [] }
        set { defaults.set(Array(newValue.prefix(32)), forKey: Key.recentEmoji) }
    }

    public func noteEmojiUse(_ emoji: String) {
        var recents = recentEmoji.filter { $0 != emoji }
        recents.insert(emoji, at: 0)
        recentEmoji = recents
    }

    /// Stage-1 logging is always on unless the user pauses it.
    public var recordingPaused: Bool {
        get { defaults.bool(forKey: Key.recordingPaused) }
        set { defaults.set(newValue, forKey: Key.recordingPaused) }
    }

    public var retentionDays: Int {
        get { max(1, defaults.integer(forKey: Key.retentionDays)) }
        set { defaults.set(min(max(newValue, 1), 365), forKey: Key.retentionDays) }
    }

    public var lastRetentionPurge: Date? {
        get { defaults.object(forKey: Key.lastRetentionPurge) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRetentionPurge) }
    }

    /// Full-schema telemetry can contain typed and surrounding text. Recording
    /// stays disabled until the containing app records current consent.
    public var hasTelemetryConsent: Bool {
        KeyboardUploadStateStore(defaults: defaults).hasCurrentConsent
    }

    public var isRecording: Bool { !recordingPaused && hasTelemetryConsent }
}

public enum SharedKeyboardStorage {
    private static let resolvedDirectory: URL? = {
        let fileManager = FileManager.default
        let groupBase = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AdaptiveKeyboardConstants.appGroup
        )
        let localBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        for base in [groupBase, localBase].compactMap({ $0 }) {
            let candidate = base.appendingPathComponent("AdaptiveKeyboard", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                let probe = candidate.appendingPathComponent(".write-probe-\(UUID().uuidString)")
                try Data().write(to: probe, options: .atomic)
                try? fileManager.removeItem(at: probe)
                return candidate
            } catch {
                continue
            }
        }
        return nil
    }()

    public static func directory() throws -> URL {
        guard let resolvedDirectory else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return resolvedDirectory
    }

    public static var ledgerURL: URL? {
        try? directory().appendingPathComponent("research-events.aklog")
    }
}

public final class EncryptedEventLedger: @unchecked Sendable {
    public static let shared = EncryptedEventLedger()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let queue = DispatchQueue(label: "adaptive-keyboard.event-ledger")

    public func append(_ event: KeyboardResearchEvent) {
        let preferences = SharedKeyboardPreferences.shared
        guard preferences.isRecording else { return }
        let shouldPurge = preferences.lastRetentionPurge.map {
            Date().timeIntervalSince($0) > 24 * 60 * 60
        } ?? true
        let retentionDays = preferences.retentionDays
        if shouldPurge {
            preferences.lastRetentionPurge = Date()
        }

        queue.async {
            do {
                if shouldPurge {
                    try self.purgeExpiredRecords(retentionDays: retentionDays)
                }
                let payload = try self.encoder.encode(event)
                let encrypted = try self.encrypt(payload)
                try self.appendLine(encrypted.base64EncodedData())
            } catch {
                // Keyboard input must never fail because telemetry failed.
            }
        }
    }

    public func exportDecrypted() throws -> URL {
        queue.sync {}
        guard let source = SharedKeyboardStorage.ledgerURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-events-\(Int(Date().timeIntervalSince1970)).jsonl")
        guard FileManager.default.fileExists(atPath: source.path) else {
            try Data().write(to: output)
            return output
        }

        let contents = try String(contentsOf: source, encoding: .utf8)
        var data = Data()
        for line in contents.split(separator: "\n") {
            guard let sealedData = Data(base64Encoded: String(line)),
                  let decrypted = try? decrypt(sealedData) else { continue }
            data.append(decrypted)
            data.append(0x0A)
        }
        try data.write(to: output, options: [.atomic, .completeFileProtection])
        return output
    }

    public func readEvents() throws -> [KeyboardResearchEvent] {
        let url = try exportDecrypted()
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n").compactMap {
            try? decoder.decode(KeyboardResearchEvent.self, from: Data($0.utf8))
        }
    }

    public func deleteAll() throws {
        queue.sync {}
        guard let url = SharedKeyboardStorage.ledgerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func appendLine(_ line: Data) throws {
        guard let url = SharedKeyboardStorage.ledgerURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        var record = line
        record.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
        } else {
            try record.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    private func purgeExpiredRecords(retentionDays: Int) throws {
        guard let url = SharedKeyboardStorage.ledgerURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let contents = try String(contentsOf: url, encoding: .utf8)
        var retained = Data()
        for line in contents.split(separator: "\n") {
            guard let encrypted = Data(base64Encoded: String(line)),
                  let payload = try? decrypt(encrypted),
                  let event = try? decoder.decode(KeyboardResearchEvent.self, from: payload),
                  event.timestamp >= cutoff else { continue }
            retained.append(line.data(using: .utf8) ?? Data())
            retained.append(0x0A)
        }
        try retained.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: encryptionKey())
        guard let combined = sealed.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: encryptionKey())
    }

    private func encryptionKey() throws -> SymmetricKey {
        let service = "com.jimmychen.typingresearch.keyboard-ledger"
        let account = "event-encryption-key"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AdaptiveKeyboardConstants.keychainGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let data = lookupKey(query: query) {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var retryQuery = query
            retryQuery.removeValue(forKey: kSecValueData as String)
            retryQuery.removeValue(forKey: kSecAttrAccessible as String)
            retryQuery[kSecReturnData as String] = true
            retryQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            if let existing = lookupKey(query: retryQuery) {
                return SymmetricKey(data: existing)
            }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return key
    }

    private func lookupKey(query: [String: Any]) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }
}

public enum ContextPrivacy {
    public static func hash(_ context: String?) -> String? {
        guard let context, !context.isEmpty else { return nil }
        return SHA256.hash(data: Data(context.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Deterministic text-only decoder backed by a frozen SymSpell English lexicon.
///
/// Touch geometry and personalization are deliberately excluded so classic and
/// Gaussian keyboard conditions receive exactly the same language-model scores.
public struct LocalLanguageDecoder: Sendable {
    private let model: EnglishLexiconModel

    public static var modelIdentifier: String {
        EnglishLanguageModelData.modelIdentifier
    }

    public static var modelIsLoaded: Bool {
        EnglishLanguageModelData.isLoaded
    }

    public static var loadedUnigramCount: Int {
        EnglishLanguageModelData.loadedUnigramCount
    }

    public static var expectedUnigramCount: Int {
        EnglishLanguageModelData.expectedUnigramCount
    }

    public static var modelSourceCommit: String {
        EnglishLanguageModelData.sourceCommit
    }

    public init() {
        model = EnglishLanguageModelData.shared
    }

    public func candidates(for prefix: String, previousWord: String?) -> [DecoderCandidate] {
        let literal = prefix.lowercased()
        guard !literal.isEmpty else {
            return nextWordCandidates(after: previousWord)
        }

        var results: [DecoderCandidate] = []
        let sourceWords = literal.first.flatMap { model.prefixBuckets[$0] } ?? []

        // Corpus frequency ranks deterministic prefix completions.
        for word in sourceWords where word.normalized.hasPrefix(literal) {
            let languageScore = score(forFrequency: word.frequency)
            let completionPenalty = Double(word.normalized.count - literal.count) * 0.06
            let score = languageScore + 0.8 - completionPenalty
            results.append(
                DecoderCandidate(
                    text: displayForm(of: word.text, matching: prefix),
                    score: score,
                    languageScore: languageScore,
                    isLiteral: word.normalized == literal
                )
            )
        }

        // A small frozen whitelist resolves ambiguous common one-edit typos.
        if let replacement = model.directCorrections[literal] {
            let normalizedReplacement = replacement.lowercased()
            let frequency = model.wordsByNormalizedForm[normalizedReplacement]?.frequency ?? 100
            let languageScore = score(forFrequency: frequency)
            results.append(
                DecoderCandidate(
                    text: displayForm(of: replacement, matching: prefix),
                    score: languageScore + 2.0,
                    languageScore: languageScore,
                    isLiteral: false
                )
            )
        }

        // Restrict fuzzy search to the bundled frequent vocabulary. This keeps the
        // keyboard responsive while preserving ordinary typo corrections.
        if literal.count >= 2 {
            let candidateLengths = max(1, literal.count - 1)...(literal.count + 1)
            for length in candidateLengths {
                for word in model.correctionBuckets[length] ?? [] {
                    guard !word.normalized.hasPrefix(literal) else { continue }
                    let distance = editDistance(literal, word.normalized, maximum: 1)
                    guard distance == 1 else { continue }
                    let languageScore = score(forFrequency: word.frequency)
                    let lengthPenalty = word.normalized.count == literal.count ? 0.0 : 0.15
                    results.append(
                        DecoderCandidate(
                            text: displayForm(of: word.text, matching: prefix),
                            score: languageScore + 0.6 - lengthPenalty,
                            languageScore: languageScore,
                            isLiteral: false
                        )
                    )
                }
            }
        }

        let knownLiteral = model.wordsByNormalizedForm[literal]
        let literalLanguageScore = knownLiteral.map { score(forFrequency: $0.frequency) } ?? 0
        let literalScore = knownLiteral == nil ? 1.0 : literalLanguageScore + 0.8
        let literalCandidate = DecoderCandidate(
            text: prefix,
            score: literalScore,
            languageScore: literalLanguageScore,
            isLiteral: true
        )
        results.append(literalCandidate)

        var ranked = Dictionary(grouping: results, by: { $0.text.lowercased() })
            .compactMap { $0.value.max(by: { $0.score < $1.score }) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.text.localizedStandardCompare($1.text) == .orderedAscending
            }

        // Always keep the typed literal in the bar (iOS quotes it when correcting).
        if !ranked.contains(where: \.isLiteral) {
            ranked.insert(literalCandidate, at: min(2, ranked.count))
        } else if let index = ranked.firstIndex(where: \.isLiteral), index > 2 {
            ranked.remove(at: index)
            ranked.insert(literalCandidate, at: 2)
        }

        return Array(ranked.prefix(3))
    }

    private func nextWordCandidates(after previousWord: String?) -> [DecoderCandidate] {
        // The SymSpell frequency dictionary contains unigrams but no contextual
        // n-grams. Return its global ranking instead of fabricating
        // context rules; the parameter remains for API compatibility.
        _ = previousWord
        return model.globallyRankedWords.prefix(3).map {
            let languageScore = score(forFrequency: $0.frequency)
            return DecoderCandidate(
                text: $0.text,
                score: languageScore,
                languageScore: languageScore
            )
        }
    }

    private func score(forFrequency frequency: Int) -> Double {
        log10(Double(max(1, frequency)))
    }

    private func displayForm(of candidate: String, matching prefix: String) -> String {
        guard candidate != "I" else { return candidate }
        if prefix.count > 1, prefix == prefix.uppercased() {
            return candidate.uppercased()
        }
        if prefix.first?.isUppercase == true {
            return candidate.prefix(1).uppercased() + String(candidate.dropFirst())
        }
        return candidate
    }

    private func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        if isSingleAdjacentTransposition(lhs, rhs) {
            return 1
        }
        guard abs(lhs.count - rhs.count) <= maximum else { return maximum + 1 }
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (i, leftCharacter) in left.enumerated() {
            var current = [i + 1]
            var rowMinimum = current[0]
            for (j, rightCharacter) in right.enumerated() {
                let value = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                )
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private func isSingleAdjacentTransposition(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count == right.count else { return false }
        let differences = left.indices.filter { left[$0] != right[$0] }
        guard differences.count == 2,
              differences[1] == differences[0] + 1 else { return false }
        let first = differences[0]
        let second = differences[1]
        return left[first] == right[second] && left[second] == right[first]
    }
}

/// Long-press alternates (diacritics and punctuation variants) shown above a held key.
public enum KeyAlternates {
    private static let table: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "0": ["°"],
        "1": ["¹"],
        "2": ["²"],
        "3": ["³"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["¢", "£", "€", "¥", "₩", "₽"],
        "&": ["§"],
        "\"": ["“", "”", "„", "«", "»"],
        "'": ["‘", "’", "‚", "'"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"],
        "=": ["≠", "≈"]
    ]

    public static func alternates(for key: String) -> [String] {
        let lowered = key.lowercased()
        guard let alternates = table[lowered] else { return [] }
        guard key != lowered else { return alternates }
        return alternates.map { $0.uppercased() }
    }

    public static func hasAlternates(for key: String) -> Bool {
        !alternates(for: key).isEmpty
    }
}

/// Approximation of iOS smart punctuation (curly quotes and em dash).
public enum SmartPunctuation {
    public static func substitution(for text: String, contextBefore: String?) -> String {
        let previous = contextBefore?.last
        switch text {
        case "\"":
            return opensQuote(after: previous) ? "“" : "”"
        case "'":
            // Apostrophe inside a word, otherwise a single quote.
            if let previous, previous.isLetter || previous.isNumber { return "’" }
            return opensQuote(after: previous) ? "‘" : "’"
        default:
            return text
        }
    }

    /// True when typing `-` right after another `-` should collapse into an em dash.
    public static func completesEmDash(_ text: String, contextBefore: String?) -> Bool {
        text == "-" && contextBefore?.hasSuffix("-") == true
    }

    private static func opensQuote(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || "([{“‘".contains(previous)
    }
}

public enum CorrectionFeedbackPolicy {
    /// Correct confident substitutions, transpositions, and one-character
    /// insertion/deletion typos without treating prefix completions as corrections.
    public static func automaticCorrection(
        from candidates: [DecoderCandidate],
        literal: String
    ) -> DecoderCandidate? {
        let lowered = literal.lowercased()
        guard lowered.count >= 3 else { return nil }
        let literalScore = candidates.first(where: \.isLiteral)?.score ?? 0
        return candidates.first {
            guard !$0.isLiteral,
                  abs($0.text.count - lowered.count) <= 1,
                  $0.score >= literalScore + 0.35 else {
                return false
            }
            // "hel" → "hello" is completion; "helo" → "hello" is correction.
            if $0.text.count > lowered.count,
               $0.text.lowercased().hasPrefix(lowered) {
                return false
            }
            return true
        }
    }

}
