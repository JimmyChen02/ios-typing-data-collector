import Foundation
import Security
import Darwin

public struct KeyboardUploadConfiguration: Sendable {
    public let projectURL: URL?
    public let publishableKey: String

    public init(projectURL: URL?, publishableKey: String) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
    }

    public init(bundle: Bundle = .main) {
        let urlString = bundle.object(forInfoDictionaryKey: "SupabaseProjectURL") as? String
        projectURL = urlString.flatMap(URL.init(string:))
        publishableKey = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String ?? ""
    }

    public var isConfigured: Bool {
        guard let projectURL,
              projectURL.scheme == "https",
              !publishableKey.isEmpty,
              !publishableKey.contains("YOUR_") else { return false }
        return true
    }

    var anonymousSignUpURL: URL? {
        projectURL?.appendingPathComponent("auth/v1/signup")
    }

    var tokenRefreshURL: URL? {
        projectURL?.appendingPathComponent("auth/v1/token")
    }

    var ingestURL: URL? {
        projectURL?.appendingPathComponent("functions/v1/ingest-keyboard-events")
    }
}

public struct KeyboardUploadStatus: Sendable, Equatable {
    public let totalEvents: Int
    public let pendingEvents: Int
    public let acknowledgedEvents: Int
    public let lastSuccessfulUpload: Date?
    public let consentGranted: Bool
    public let isConfigured: Bool
}

public struct KeyboardUploadResult: Sendable, Equatable {
    public let uploadedEvents: Int
    public let remainingEvents: Int
    public let lastSuccessfulUpload: Date?
}

public enum KeyboardUploadError: LocalizedError, Equatable {
    case consentRequired
    case notConfigured
    case invalidServerResponse
    case server(status: Int, message: String)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "Consent is required before full keyboard telemetry can be uploaded."
        case .notConfigured:
            return "Supabase is not configured for this build."
        case .invalidServerResponse:
            return "The upload server returned an invalid response."
        case let .server(status, message):
            return "Upload failed (HTTP \(status)): \(message)"
        case .authenticationFailed:
            return "The anonymous upload session could not be created or refreshed."
        }
    }
}

public protocol KeyboardEventSource: Sendable {
    func uploadEvents() throws -> [KeyboardResearchEvent]
}

extension EncryptedEventLedger: KeyboardEventSource {
    public func uploadEvents() throws -> [KeyboardResearchEvent] {
        try readEvents()
    }
}

public protocol KeyboardUploadTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol KeyboardUploadAuthStoring: Sendable {
    func load() -> KeyboardUploadAuthSession?
    func save(_ session: KeyboardUploadAuthSession)
    func clear()
}

public struct URLSessionKeyboardUploadTransport: KeyboardUploadTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

public final class KeyboardUploadStateStore: @unchecked Sendable {
    public static let consentVersion = 1

    private enum Key {
        static let installationID = "keyboard.upload.installationID"
        static let consentVersion = "keyboard.upload.consentVersion"
        static let consentedAt = "keyboard.upload.consentedAt"
        static let acknowledgedIDs = "keyboard.upload.acknowledgedIDs"
        static let lastAttempt = "keyboard.upload.lastAttempt"
        static let lastSuccess = "keyboard.upload.lastSuccess"
        static let nextRetry = "keyboard.upload.nextRetry"
        static let failureCount = "keyboard.upload.failureCount"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AdaptiveKeyboardConstants.appGroup)
            ?? .standard
    }

    public var installationID: UUID {
        lock.withLock {
            if let value = defaults.string(forKey: Key.installationID),
               let id = UUID(uuidString: value) {
                return id
            }
            let id = UUID()
            defaults.set(id.uuidString, forKey: Key.installationID)
            return id
        }
    }

    public var hasCurrentConsent: Bool {
        defaults.integer(forKey: Key.consentVersion) == Self.consentVersion
    }

    public var consentedAt: Date? {
        defaults.object(forKey: Key.consentedAt) as? Date
    }

    public func setConsent(granted: Bool, at date: Date = Date()) {
        lock.withLock {
            defaults.set(granted ? Self.consentVersion : 0, forKey: Key.consentVersion)
            defaults.set(granted ? date : nil, forKey: Key.consentedAt)
        }
    }

    public var lastSuccessfulUpload: Date? {
        defaults.object(forKey: Key.lastSuccess) as? Date
    }

    public func acknowledgedIDs() -> Set<UUID> {
        Set((defaults.stringArray(forKey: Key.acknowledgedIDs) ?? []).compactMap(UUID.init))
    }

    public func replaceAcknowledgedIDs(_ ids: Set<UUID>) {
        lock.withLock {
            defaults.set(ids.map(\.uuidString).sorted(), forKey: Key.acknowledgedIDs)
        }
    }

    public func claimAutomaticAttempt(
        at date: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let fileLock = CrossProcessClaimLock.acquire() else { return false }
        defer { fileLock.release() }
        return lock.withLock {
            defaults.synchronize()
            if let retry = defaults.object(forKey: Key.nextRetry) as? Date, retry > date {
                return false
            }
            if let last = defaults.object(forKey: Key.lastAttempt) as? Date,
               date.timeIntervalSince(last) < minimumInterval {
                return false
            }
            defaults.set(date, forKey: Key.lastAttempt)
            defaults.synchronize()
            return true
        }
    }

    public func recordSuccess(at date: Date) {
        lock.withLock {
            defaults.set(date, forKey: Key.lastSuccess)
            defaults.set(0, forKey: Key.failureCount)
            defaults.removeObject(forKey: Key.nextRetry)
        }
    }

    public func recordFailure(at date: Date) {
        lock.withLock {
            let count = min(defaults.integer(forKey: Key.failureCount) + 1, 10)
            let delay = min(60.0 * pow(2.0, Double(max(0, count - 1))), 3_600.0)
            defaults.set(count, forKey: Key.failureCount)
            defaults.set(date.addingTimeInterval(delay), forKey: Key.nextRetry)
        }
    }
}

private final class CrossProcessClaimLock {
    private let descriptor: Int32
    private let url: URL

    private init(descriptor: Int32, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }

    static func acquire() -> CrossProcessClaimLock? {
        guard let directory = try? SharedKeyboardStorage.directory() else { return nil }
        let url = directory.appendingPathComponent("upload-claim.lock")
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 30 {
            try? fileManager.removeItem(at: url)
        }
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        return CrossProcessClaimLock(descriptor: descriptor, url: url)
    }

    func release() {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: url)
    }
}

public actor KeyboardEventUploader {
    public static let shared = KeyboardEventUploader()
    public static let automaticInterval: TimeInterval = 15 * 60
    public static let batchSize = 50

    private let configuration: KeyboardUploadConfiguration
    private let state: KeyboardUploadStateStore
    private let eventSource: KeyboardEventSource
    private let transport: KeyboardUploadTransport
    private let authStore: KeyboardUploadAuthStoring
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: KeyboardUploadConfiguration = KeyboardUploadConfiguration(),
        state: KeyboardUploadStateStore = KeyboardUploadStateStore(),
        eventSource: KeyboardEventSource = EncryptedEventLedger.shared,
        transport: KeyboardUploadTransport = URLSessionKeyboardUploadTransport(),
        authStore: KeyboardUploadAuthStoring = KeyboardUploadAuthStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.state = state
        self.eventSource = eventSource
        self.transport = transport
        self.authStore = authStore
        self.now = now
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func status() throws -> KeyboardUploadStatus {
        let events = try eventSource.uploadEvents()
        let eventIDs = Set(events.map(\.id))
        let acknowledged = state.acknowledgedIDs().intersection(eventIDs)
        if acknowledged != state.acknowledgedIDs() {
            state.replaceAcknowledgedIDs(acknowledged)
        }
        let eligibleEvents = events.filter(isCoveredByConsent)
        let eligibleIDs = Set(eligibleEvents.map(\.id))
        return KeyboardUploadStatus(
            totalEvents: events.count,
            pendingEvents: eligibleEvents.count - acknowledged.intersection(eligibleIDs).count,
            acknowledgedEvents: acknowledged.intersection(eligibleIDs).count,
            lastSuccessfulUpload: state.lastSuccessfulUpload,
            consentGranted: state.hasCurrentConsent,
            isConfigured: configuration.isConfigured
        )
    }

    @discardableResult
    public func uploadIfDue() async throws -> KeyboardUploadResult? {
        guard state.hasCurrentConsent else { return nil }
        let date = now()
        guard state.claimAutomaticAttempt(
            at: date,
            minimumInterval: Self.automaticInterval
        ) else { return nil }
        return try await upload(maximumBatches: 1, at: date)
    }

    @discardableResult
    public func uploadNow() async throws -> KeyboardUploadResult {
        guard state.hasCurrentConsent else {
            throw KeyboardUploadError.consentRequired
        }
        return try await upload(maximumBatches: .max, at: now())
    }

    private func upload(maximumBatches: Int, at attemptDate: Date) async throws -> KeyboardUploadResult {
        guard configuration.isConfigured else {
            throw KeyboardUploadError.notConfigured
        }

        do {
            let allEvents = try eventSource.uploadEvents()
            let currentIDs = Set(allEvents.map(\.id))
            var acknowledged = state.acknowledgedIDs().intersection(currentIDs)
            state.replaceAcknowledgedIDs(acknowledged)
            var events = allEvents.filter(isCoveredByConsent)
            events.removeAll { acknowledged.contains($0.id) }

            if events.isEmpty {
                state.recordSuccess(at: attemptDate)
                return KeyboardUploadResult(
                    uploadedEvents: 0,
                    remainingEvents: 0,
                    lastSuccessfulUpload: attemptDate
                )
            }

            var uploadedCount = 0
            var batchCount = 0
            while !events.isEmpty && batchCount < maximumBatches {
                let batch = Array(events.prefix(Self.batchSize))
                let acknowledgedBatch = try await send(batch)
                guard acknowledgedBatch == Set(batch.map(\.id)) else {
                    throw KeyboardUploadError.invalidServerResponse
                }
                acknowledged.formUnion(acknowledgedBatch)
                state.replaceAcknowledgedIDs(acknowledged)
                uploadedCount += batch.count
                batchCount += 1
                events.removeFirst(batch.count)
            }

            let successDate = now()
            state.recordSuccess(at: successDate)
            return KeyboardUploadResult(
                uploadedEvents: uploadedCount,
                remainingEvents: events.count,
                lastSuccessfulUpload: successDate
            )
        } catch {
            state.recordFailure(at: attemptDate)
            throw error
        }
    }

    private func send(_ events: [KeyboardResearchEvent]) async throws -> Set<UUID> {
        guard let url = configuration.ingestURL else {
            throw KeyboardUploadError.notConfigured
        }
        let session = try await validAuthSession()
        let batchID = UUID()
        let envelope = KeyboardUploadEnvelope(
            batchId: batchID,
            installationId: state.installationID,
            consentVersion: KeyboardUploadStateStore.consentVersion,
            events: events
        )
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(envelope)

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KeyboardUploadError.invalidServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                authStore.clear()
            }
            let message = (try? decoder.decode(ServerErrorResponse.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw KeyboardUploadError.server(status: http.statusCode, message: message)
        }
        let receipt = try decoder.decode(KeyboardUploadReceipt.self, from: data)
        guard receipt.batchId == batchID else {
            throw KeyboardUploadError.invalidServerResponse
        }
        return Set(receipt.acknowledgedEventIDs)
    }

    private func isCoveredByConsent(_ event: KeyboardResearchEvent) -> Bool {
        guard let consentedAt = state.consentedAt else { return false }
        return event.timestamp >= consentedAt
    }

    private func validAuthSession() async throws -> KeyboardUploadAuthSession {
        if let existing = authStore.load(),
           existing.expiresAt.timeIntervalSince(now()) > 60 {
            return existing
        }
        if let existing = authStore.load(),
           let refreshed = try? await authenticate(
            url: configuration.tokenRefreshURL,
            body: ["refresh_token": existing.refreshToken],
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")]
           ) {
            authStore.save(refreshed)
            return refreshed
        }
        guard let session = try? await authenticate(
            url: configuration.anonymousSignUpURL,
            body: [:],
            query: []
        ) else {
            throw KeyboardUploadError.authenticationFailed
        }
        authStore.save(session)
        return session
    }

    private func authenticate(
        url: URL?,
        body: [String: String],
        query: [URLQueryItem]
    ) async throws -> KeyboardUploadAuthSession {
        guard let url else { throw KeyboardUploadError.notConfigured }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let requestURL = components?.url else {
            throw KeyboardUploadError.notConfigured
        }
        var request = URLRequest(url: requestURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let payload = try? decoder.decode(SupabaseAuthResponse.self, from: data) else {
            throw KeyboardUploadError.authenticationFailed
        }
        return KeyboardUploadAuthSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date(timeIntervalSince1970: payload.expiresAt)
        )
    }
}

public final class KeyboardUploadAuthStore: KeyboardUploadAuthStoring, @unchecked Sendable {
    private let service = "edu.cornell.typingresearch.keyboard-upload"
    private let account = "supabase-anonymous-session"

    public init() {}

    public func load() -> KeyboardUploadAuthSession? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(returnData: true) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyboardUploadAuthSession.self, from: data)
    }

    public func save(_ session: KeyboardUploadAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(baseQuery(returnData: false) as CFDictionary)
        var query = baseQuery(returnData: false)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery(returnData: false) as CFDictionary)
    }

    private func baseQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AdaptiveKeyboardConstants.keychainGroup
        ]
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

public struct KeyboardUploadAuthSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

private struct KeyboardUploadEnvelope: Encodable {
    let batchId: UUID
    let installationId: UUID
    let consentVersion: Int
    let events: [KeyboardResearchEvent]
}

private struct KeyboardUploadReceipt: Decodable {
    let batchId: UUID
    let acknowledgedEventIDs: [UUID]
    let serverTime: Date
}

private struct ServerErrorResponse: Decodable {
    let error: String
}

private struct SupabaseAuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
