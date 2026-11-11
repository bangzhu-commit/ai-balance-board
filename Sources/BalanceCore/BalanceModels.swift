import Foundation

public enum ServiceID: String, Codable, CaseIterable, Sendable { case foxcode, codex, grok }

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
