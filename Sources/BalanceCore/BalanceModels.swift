import Foundation

/// Preserves the original string encoding while allowing locally configured sites.
public struct ServiceID: RawRepresentable, Hashable, Codable, CaseIterable, Sendable {
    public let rawValue: String
    public static let foxcode = ServiceID(unchecked: "foxcode")
    public static let codex = ServiceID(unchecked: "codex")
    public static let grok = ServiceID(unchecked: "grok")
    public static let allCases: [ServiceID] = [.foxcode, .codex, .grok]

    private init(unchecked: String) { rawValue = unchecked }
    public init?(rawValue: String) {
        if Self.allCases.contains(where: { $0.rawValue == rawValue }) { self.rawValue = rawValue; return }
        guard rawValue.hasPrefix("custom:"), let id = UUID(uuidString: String(rawValue.dropFirst(7))),
              id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return nil }
        self.rawValue = "custom:" + id.uuidString.lowercased()
    }
    public static func custom(_ id: UUID) -> ServiceID { ServiceID(unchecked: "custom:" + id.uuidString.lowercased()) }
    public var customUUID: UUID? { rawValue.hasPrefix("custom:") ? UUID(uuidString: String(rawValue.dropFirst(7))) : nil }
    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        let raw = try box.decode(String.self)
        guard let value = Self(rawValue: raw) else { throw DecodingError.dataCorruptedError(in: box, debugDescription: "Unknown service identifier") }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer(); try box.encode(rawValue)
    }
}

public enum ServiceConnectionState: String, Codable, Sendable {
    case notConfigured, ready, authenticationRequired, dependencyMissing
    case networkUnavailable, rateLimited, invalidResponse, connectionUnavailable, temporaryFailure

    public var needsConnection: Bool {
        switch self {
        case .notConfigured, .authenticationRequired, .dependencyMissing, .connectionUnavailable: return true
        default: return false
        }
    }
}

public struct BalanceMetric: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var value: String
    public var remainingFraction: Double?
    public var resetsAt: Date?
    public init(id: String, label: String, value: String, remainingFraction: Double? = nil, resetsAt: Date? = nil) {
        self.id = id; self.label = label; self.value = value
        self.remainingFraction = remainingFraction; self.resetsAt = resetsAt
    }
}

public struct BalanceReading: Codable, Equatable, Sendable {
    public var service: ServiceID
    public var metrics: [BalanceMetric]
    public var fetchedAt: Date
    public var source: String
    public init(service: ServiceID, metrics: [BalanceMetric], fetchedAt: Date = Date(), source: String) {
        self.service = service; self.metrics = metrics; self.fetchedAt = fetchedAt; self.source = source
    }
}

public struct ServiceCard: Identifiable, Sendable {
    public var id: ServiceID
    public var title: String
    public var subtitle: String
    public var reading: BalanceReading?
    public var status: String
    public var needsConnection: Bool
    public var connectionState: ServiceConnectionState
    public var isRefreshing = false
    public var hasError = false
    public var isStale: Bool {
        guard let reading else { return true }
        return hasError || Date().timeIntervalSince(reading.fetchedAt) > 900 || reading.metrics.contains { ($0.resetsAt ?? .distantFuture) <= Date() }
    }
    public init(id: ServiceID, title: String, subtitle: String, reading: BalanceReading? = nil, status: String, needsConnection: Bool = true, connectionState: ServiceConnectionState = .notConfigured) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.reading = reading
        self.status = status; self.needsConnection = needsConnection
        self.connectionState = connectionState
    }
}

public enum BalanceError: LocalizedError {
    case unavailable(String)
    case authenticationRequired(String), dependencyMissing(String), network(String), rateLimited(String), invalidResponse(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .authenticationRequired(let reason), .dependencyMissing(let reason),
             .network(let reason), .rateLimited(let reason), .invalidResponse(let reason): return reason
        }
    }
    public var connectionState: ServiceConnectionState {
        switch self {
        case .unavailable: return .temporaryFailure
        case .authenticationRequired: return .authenticationRequired
        case .dependencyMissing: return .dependencyMissing
        case .network: return .networkUnavailable
        case .rateLimited: return .rateLimited
        case .invalidResponse: return .invalidResponse
        }
    }
    public var shouldRetrySoon: Bool {
        if case .network = self { return true }
        return false
    }
}
