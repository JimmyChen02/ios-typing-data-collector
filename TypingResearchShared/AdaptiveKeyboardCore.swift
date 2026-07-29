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
    public static let schemaVersion = 5
    public static let letterKeys = Array("qwertyuiopasdfghjklzxcvbnm").map(String.init)
}

public enum KeyboardLayoutMode: String, Codable, Sendable {
    case letters
    case numbers
    case symbols
    case emoji
}

public enum OneHandedMode: String, Codable, Sendable {
    case off
    case left
    case right
}

public enum KeyboardEventKind: String, Codable, Sendable {
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
    public var text: String
    public var score: Double
    public var languageScore: Double
    public var isLiteral: Bool

    public init(
        text: String,
        score: Double,
        languageScore: Double = 0,
        isLiteral: Bool = false
    ) {
        self.text = text
        self.score = score
        self.languageScore = languageScore
        self.isLiteral = isLiteral
    }
}

public struct KeyboardResearchEvent: Codable, Identifiable, Sendable {
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
        metadata: [String: String] = [:]
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

    public var isRecording: Bool { !recordingPaused }
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

public final class EncryptedEventLedger {
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

/// Compact English decoder for suggestion bar + autocorrect (not Apple's language model).
public struct LocalLanguageDecoder: Sendable {
    private static let vocabulary = [
        "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as",
        "at", "back", "be", "because", "been", "but", "by", "can", "come", "could",
        "day", "did", "do", "even", "first", "for", "from", "get", "give", "go", "good",
        "had", "has", "have", "he", "hello", "her", "here", "him", "his", "how", "i",
        "if", "in", "into", "is", "it", "its", "just", "know", "like", "look", "make",
        "me", "more", "most", "my", "new", "no", "not", "now", "of", "on", "one",
        "only", "or", "other", "our", "out", "over", "people", "say", "see", "she",
        "so", "some", "take", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "think", "this", "time", "to", "two", "up", "use", "very",
        "want", "was", "way", "we", "well", "were", "what", "when", "which", "who",
        "will", "with", "work", "would", "year", "you", "your"
    ]

    /// Common same-length typos → corrections (boosted for autocorrect demos).
    private static let typoCorrections: [String: String] = [
        "teh": "the",
        "adn": "and",
        "taht": "that",
        "waht": "what",
        "recieve": "receive",
        "seperate": "separate"
    ]

    public init() {}

    public func candidates(for prefix: String, previousWord: String?) -> [DecoderCandidate] {
        let literal = prefix.lowercased()
        guard !literal.isEmpty else {
            return nextWordCandidates(after: previousWord)
        }

        var results: [DecoderCandidate] = []

        // Prefix completions rank above fuzzy edits so the bar feels like QuickType.
        for word in Self.vocabulary where word.hasPrefix(literal) {
            let completionPenalty = Double(word.count - literal.count) * 0.08
            let score = 4.0 - completionPenalty
            results.append(
                DecoderCandidate(
                    text: word,
                    score: score,
                    languageScore: score,
                    isLiteral: word == literal
                )
            )
        }

        for word in Self.vocabulary {
            let rawDistance = editDistance(literal, word)
            let distance = isSingleAdjacentTransposition(literal, word) ? 1 : rawDistance
            guard distance > 0, distance <= 2 else { continue }
            // Permit confident one-character insertion/deletion corrections while
            // still preferring same-length substitutions/transpositions.
            let lengthPenalty = word.count == literal.count ? 0.0 : 0.25
            let score = 3.4 - Double(distance) - lengthPenalty
            results.append(
                DecoderCandidate(
                    text: word,
                    score: score,
                    languageScore: score,
                    isLiteral: false
                )
            )
        }

        if let corrected = Self.typoCorrections[literal] {
            results.append(
                DecoderCandidate(
                    text: corrected,
                    score: 5.0,
                    languageScore: 5.0,
                    isLiteral: false
                )
            )
        }

        let literalScore = Self.vocabulary.contains(literal) ? 3.5 : 1.8
        let literalCandidate = DecoderCandidate(
            text: literal,
            score: literalScore,
            languageScore: literalScore,
            isLiteral: true
        )
        results.append(literalCandidate)

        var ranked = Dictionary(grouping: results, by: \.text)
            .compactMap { $0.value.max(by: { $0.score < $1.score }) }
            .sorted { $0.score > $1.score }

        // Always keep the typed literal in the bar (iOS quotes it when correcting).
        if !ranked.contains(where: { $0.text == literal }) {
            ranked.insert(literalCandidate, at: min(2, ranked.count))
        } else if let index = ranked.firstIndex(where: { $0.text == literal }), index > 2 {
            ranked.remove(at: index)
            ranked.insert(literalCandidate, at: 2)
        }

        return Array(ranked.prefix(3))
    }

    private func nextWordCandidates(after previousWord: String?) -> [DecoderCandidate] {
        let common: [String]
        switch previousWord?.lowercased() {
        case "i": common = ["am", "have", "think"]
        case "thank": common = ["you", "the", "them"]
        case "how": common = ["are", "do", "is"]
        case "the": common = ["best", "first", "new"]
        default: common = ["the", "I", "and"]
        }
        return common.enumerated().map {
            DecoderCandidate(
                text: $0.element,
                score: 1 - Double($0.offset) * 0.1,
                languageScore: 1
            )
        }
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (i, leftCharacter) in left.enumerated() {
            var current = [i + 1]
            for (j, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
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
