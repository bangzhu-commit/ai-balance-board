import Foundation

/// Decodes the account/rateLimits/read result without assuming a fixed quota window.
public enum CodexParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> BalanceReading {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw BalanceError.unavailable("Codex 额度响应格式异常，请稍后刷新。")
        }
        guard !envelope.hasError, let result = envelope.result else {
            throw BalanceError.unavailable("Codex 暂时无法读取额度，请检查命令行登录状态。")
        }

        let buckets: [(String, Snapshot)]
        if let map = result.rateLimitsByLimitId, !map.isEmpty {
            buckets = map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else if let snapshot = result.rateLimits {
            buckets = [(snapshot.limitId ?? "codex", snapshot)]
        } else {
            throw BalanceError.unavailable("Codex 尚未返回可用的额度数据。")
        }

        var metrics: [BalanceMetric] = []
        for (key, bucket) in buckets {
            let bucketName = nonempty(bucket.limitName) ?? nonempty(bucket.limitId) ?? key
            let prefix = buckets.count > 1 ? "\(bucketName) · " : ""
            for (kind, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                let remaining = window.usedPercent.flatMap { used -> Double? in
                    guard used.isFinite else { return nil }
                    return min(100, max(0, 100 - used))
                }
                let reset = window.resetsAt.flatMap { timestamp -> Date? in
                    guard timestamp.isFinite, timestamp >= 0 else { return nil }
                    return Date(timeIntervalSince1970: timestamp)
                }
                metrics.append(BalanceMetric(
                    id: "\(key).\(kind)",
                    label: prefix + windowLabel(window.windowDurationMins, kind: kind),
                    value: remaining.map { formatPercent($0) + "%" } ?? "暂不可用",
                    remainingFraction: remaining.map { $0 / 100 },
                    resetsAt: reset
                ))
            }
            if let credits = bucket.credits {
                let balance: String
                if credits.unlimited == true {
                    balance = "不限额"
                } else if let raw = credits.balance, let decimal = decimalValue(raw) {
                    balance = formatBalance(decimal)
                } else {
                    // A missing balance, including hasCredits=false, is not proof of zero.
                    balance = "暂不可用"
                }
                metrics.append(BalanceMetric(id: "\(key).credits", label: prefix + "额度余额", value: balance))
            }
        }
        guard !metrics.isEmpty else {
            throw BalanceError.unavailable("Codex 尚未返回可用的额度数据。")
        }
        return BalanceReading(service: .codex, metrics: metrics, fetchedAt: fetchedAt, source: "Codex 官方额度接口")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func windowLabel(_ minutes: Int?, kind: String) -> String {
        guard let minutes, minutes > 0 else { return kind == "primary" ? "主窗口剩余" : "次窗口剩余" }
        switch minutes {
        case 10_080: return "每周剩余"
        case 1_440: return "每日剩余"
        case let value where value % 1_440 == 0: return "\(value / 1_440) 天剩余"
        case let value where value % 60 == 0: return "\(value / 60) 小时剩余"
        default: return "\(minutes) 分钟剩余"
        }
    }

    private static func formatPercent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func decimalValue(_ raw: String) -> Decimal? {
        // Decimal(string:) accepts a numeric prefix, so first reject trailing junk.
        guard raw.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0, !value.isNaN else { return nil }
        return value
    }

    private static func formatBalance(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    private struct Envelope: Decodable {
        var result: ResultBody?
        var hasError: Bool
        enum CodingKeys: String, CodingKey { case result, error }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.error) {
                hasError = !(try values.decodeNil(forKey: .error))
            } else {
                hasError = false
            }
            result = try values.decodeIfPresent(ResultBody.self, forKey: .result)
        }
    }
    private struct ResultBody: Decodable {
        var rateLimits: Snapshot?
        var rateLimitsByLimitId: [String: Snapshot]?
    }
    private struct Snapshot: Decodable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var credits: Credits?
    }
    private struct Window: Decodable {
        var usedPercent: Double?
        var windowDurationMins: Int?
        var resetsAt: Double?
    }
    private struct Credits: Decodable {
        var balance: String?
        var unlimited: Bool?
    }
}
