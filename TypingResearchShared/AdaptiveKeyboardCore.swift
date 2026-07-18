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
    public static let schemaVersion = 2
    public static let letterKeys = Array("qwertyuiopasdfghjklzxcvbnm").map(String.init)
}

public enum KeyboardLayoutMode: String, Codable, Sendable {
    case letters
    case numbers
    case symbols
}

public enum KeyboardEventKind: String, Codable, Sendable {
    case touch
    case insert
    case delete
    case cursorMoved
    case externalMutation
    case recordingChanged
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
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AdaptiveKeyboardConstants.appGroup)
            ?? .standard
        if self.defaults.object(forKey: Key.retentionDays) == nil {
            self.defaults.set(30, forKey: Key.retentionDays)
        }
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
