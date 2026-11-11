import Foundation

/// Decodes only GetSandUsageStatusResponse fields, after the web bridge whitelist.
/// ProtoJSON omits default booleans, permits null as unset, and permits numeric doubles as strings.
public enum GrokServerParser {
    public static func parse(data: Data, now: Date = Date()) throws -> BalanceReading {
        guard data.count < 1_048_576, now.timeIntervalSince1970.isFinite,
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BalanceError.unavailable("Grok Bot 服务器额度格式异常，请稍后刷新")
        }
        guard !response.usesPooledEnterpriseAllowance else {
            throw BalanceError.unavailable("Grok Bot 使用企业共享额度，服务器未提供个人余额")
        }
        guard let used = response.usagePercent?.value, used.isFinite, used >= 0,
              response.hasNonZeroIncludedLimit else {
            throw BalanceError.unavailable("Grok Bot 服务器尚未提供可用的包含额度")
        }

        let reset = try futureTimestamp(response.nextResetTimestampUtc, now: now)
        // Paid accounts can retain an old trial deadline. Validate its format, but
        // do not invalidate a current quota or infer a live trial from historical data.
        let trialExpiry = try timestamp(response.sandTrialExpiresAt).flatMap { $0 > now ? $0 : nil }
        let remaining = min(100, max(0, 100 - used))
        let rounded = (remaining * 10).rounded() / 10
        let value = rounded == rounded.rounded()
            ? String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), rounded)
            : String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), rounded)

        // A trial-expiry field alone does not prove that this is an active trial.
        // Unified accounts report a Grok/Grok Bot/Cursor shared pool, not a Bot-only pool.
        let label: String
        if trialExpiry != nil {
            label = response.isUnified ? "共享额度剩余" : "额度剩余"
        } else {
            label = response.isUnified ? "共享周额度剩余" : "每周剩余"
        }
        let scope = response.isTeamSeat ? "团队席位 · " : ""
        var metrics = [BalanceMetric(id: "included", label: scope + label, value: value,
                                     remainingFraction: remaining / 100, resetsAt: reset)]
        if let trialExpiry {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            metrics.append(BalanceMetric(id: "trial-expiry", label: "试用截止", value: formatter.string(from: trialExpiry)))
        }
        return BalanceReading(service: .grok, metrics: metrics, fetchedAt: now, source: "Grok Bot 服务器接口")
    }

    private static func futureTimestamp(_ raw: String?, now: Date) throws -> Date? {
        guard let date = try timestamp(raw) else { return nil }
        guard date > now else {
            throw BalanceError.unavailable("Grok Bot 额度日期无效或已过期，请重新查询服务器")
        }
        return date
    }

    private static func timestamp(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        guard let date = rfc3339(raw) else {
            throw BalanceError.unavailable("Grok Bot 额度日期格式无效，请重新查询服务器")
        }
        return date
    }

    /// Validate calendar components before constructing a date; Foundation otherwise
    /// normalizes invalid dates such as February 30 instead of rejecting them.
    private static func rfc3339(_ raw: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?([Zz]|[+-]\d{2}:\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.range.length == raw.utf16.count else { return nil }
        func field(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return String(raw[range])
        }
        guard let year = field(1).flatMap(Int.init), (1...9999).contains(year),
              let month = field(2).flatMap(Int.init), (1...12).contains(month),
              let day = field(3).flatMap(Int.init), (1...31).contains(day),
              let hour = field(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = field(5).flatMap(Int.init), (0...59).contains(minute),
              let second = field(6).flatMap(Int.init), (0...59).contains(second),
              let zone = field(8) else { return nil }
        var offset = 0
        if zone.uppercased() != "Z" {
            let pieces = zone.dropFirst().split(separator: ":")
            guard pieces.count == 2, let hours = Int(pieces[0]), hours <= 23,
                  let minutes = Int(pieces[1]), minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base)
        guard checked.year == year, checked.month == month, checked.day == day,
              checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
        let fraction = field(7).flatMap { Double("0." + $0) } ?? 0
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private struct ProtoDouble: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else {
                let raw = try container.decode(String.self)
                guard raw.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
                      let number = Double(raw) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid numeric percentage")
                }
                value = number
            }
        }
    }

    private struct Response: Decodable {
        let usagePercent: ProtoDouble?
        let hasNonZeroIncludedLimit: Bool
        let nextResetTimestampUtc: String?
        let isTeamSeat: Bool
        let usesPooledEnterpriseAllowance: Bool
        let sandTrialExpiresAt: String?
        let isUnified: Bool
        enum CodingKeys: String, CodingKey {
            case usagePercent, hasNonZeroIncludedLimit, nextResetTimestampUtc, isTeamSeat
            case usesPooledEnterpriseAllowance, sandTrialExpiresAt, isUnified
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            usagePercent = try values.decodeIfPresent(ProtoDouble.self, forKey: .usagePercent)
            hasNonZeroIncludedLimit = try values.decodeIfPresent(Bool.self, forKey: .hasNonZeroIncludedLimit) ?? false
            nextResetTimestampUtc = try values.decodeIfPresent(String.self, forKey: .nextResetTimestampUtc)
            isTeamSeat = try values.decodeIfPresent(Bool.self, forKey: .isTeamSeat) ?? false
            usesPooledEnterpriseAllowance = try values.decodeIfPresent(Bool.self, forKey: .usesPooledEnterpriseAllowance) ?? false
            sandTrialExpiresAt = try values.decodeIfPresent(String.self, forKey: .sandTrialExpiresAt)
            isUnified = try values.decodeIfPresent(Bool.self, forKey: .isUnified) ?? false
        }
    }
}
