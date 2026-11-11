import Foundation
import CoreFoundation

public enum CustomSiteParser {
    public static let maxResponseBytes = 524_288

    public static func parseJSON(data: Data, config: CustomSiteConfig, id: UUID, at date: Date = Date()) throws -> BalanceReading {
        try config.validate()
        guard config.mode == .json, !data.isEmpty, data.count <= maxResponseBytes else { throw CustomSiteError.invalidReading }
        do {
            let root = try JSONSerialization.jsonObject(with: data)
            if let success = config.success {
                guard let value = lookup(success.path, in: root), matches(value, success.equals) else { throw CustomSiteError.invalidReading }
            }
            return try parse(config: config, id: id, at: date) { location, metric in
                guard let value = lookup(location, in: root) else { throw CustomSiteError.invalidReading }
                return try number(value, prefix: metric.prefix, suffix: metric.suffix)
            }
        } catch { throw CustomSiteError.invalidReading }
    }

    /// The provider passes exact textContent values indexed by CSS selector.
    public static func parseDOM(values: [String: String], config: CustomSiteConfig, id: UUID, at date: Date = Date()) throws -> BalanceReading {
        try config.validate()
        guard config.mode == .dom, values.count <= 12, values.values.allSatisfy({ $0.utf8.count <= 4096 }) else { throw CustomSiteError.invalidReading }
        return try parse(config: config, id: id, at: date) { location, metric in
            guard let value = values[location] else { throw CustomSiteError.invalidReading }
            return try number(value, prefix: metric.prefix, suffix: metric.suffix)
        }
    }

    private static func parse(config: CustomSiteConfig, id: UUID, at date: Date,
                              value: (String, CustomSiteMetric) throws -> Double) throws -> BalanceReading {
        guard ServiceID(rawValue: "custom:" + id.uuidString) != nil, date.timeIntervalSince1970.isFinite else { throw CustomSiteError.invalidReading }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6; formatter.minimumFractionDigits = 0
        let metrics = try config.metrics.map { metric -> BalanceMetric in
            let raw = try value(metric.value, metric)
            let total = try metric.total.map { try value($0, metric) }
            guard total == nil || total! > 0 else { throw CustomSiteError.invalidReading }
            let result: Double
            if metric.operation == .remaining {
                guard let total, raw >= 0 else { throw CustomSiteError.invalidReading }
                result = (total - raw) * metric.multiplier
            } else { result = raw * metric.multiplier }
            guard result.isFinite, abs(result) <= 9_007_199_254_740_991 else { throw CustomSiteError.invalidReading }
            if metric.unit == "%" {
                // Overages may produce negative remaining or >100% used. A
                // remaining value above 100 or negative used value contradicts
                // the declared semantics and commonly signals a wrong mapping.
                guard !(metric.meaning == .remaining && result > 100),
                      !(metric.meaning == .used && result < 0) else { throw CustomSiteError.invalidReading }
            }
            var fraction: Double?
            if metric.meaning == .remaining {
                if let total { fraction = min(1, max(0, result / (total * metric.multiplier))) }
                else if metric.unit == "%" { fraction = min(1, max(0, result / 100)) }
            }
            guard let formatted = formatter.string(from: NSNumber(value: result)) else { throw CustomSiteError.invalidReading }
            return BalanceMetric(id: metric.id, label: metric.label, value: formatted + (metric.unit == "%" ? "%" : " " + metric.unit), remainingFraction: fraction)
        }
        return BalanceReading(service: .custom(id), metrics: metrics, fetchedAt: date,
                              source: config.mode == .json ? "自定义站点（JSON）" : "自定义站点（网页）")
    }

    private static func lookup(_ pointer: String, in root: Any) -> Any? {
        var current: Any = root
        for part in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current as? [String: Any], let value = object[token] { current = value }
            else if let list = current as? [Any], token.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                    let index = Int(token), list.indices.contains(index) { current = list[index] }
            else { return nil }
        }
        return current
    }

    private static func matches(_ value: Any, _ scalar: CustomJSONScalar) -> Bool {
        switch scalar {
        case .bool(let expected):
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue == expected
        case .number(let expected):
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue == expected
        case .string(let expected): return (value as? String) == expected
        }
    }

    private static func number(_ value: Any, prefix: String, suffix: String) throws -> Double {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  abs(number.doubleValue) <= 9_007_199_254_740_991 else { throw CustomSiteError.invalidReading }
            return number.doubleValue
        }
        guard var text = value as? String, text.utf8.count <= 4096 else { throw CustomSiteError.invalidReading }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            guard text.hasPrefix(prefix) else { throw CustomSiteError.invalidReading }
            text.removeFirst(prefix.count)
        }
        if !suffix.isEmpty {
            guard text.hasSuffix(suffix) else { throw CustomSiteError.invalidReading }
            text.removeLast(suffix.count)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Do not guess currencies, decimal separators, "unlimited", loading placeholders, or arithmetic.
        guard text.range(of: "^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let number = Double(text.replacingOccurrences(of: ",", with: "")), number.isFinite,
              abs(number) <= 9_007_199_254_740_991 else { throw CustomSiteError.invalidReading }
        return number
    }
}
