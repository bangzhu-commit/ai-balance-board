import Foundation

/// Grok Bot 0.79.4 的只读缓存格式。未知格式必须失败，不能伪造零用量。
public enum GrokParser {
    public static let maximumFileBytes = 1_048_576
    public static let accountSlotKey = "sand.client.slice.client-meta.account-slot"

    public static func accountSlot(from data: Data) throws -> String {
        try checkSize(data)
        guard let envelope = try? JSONDecoder().decode(SlotEnvelope.self, from: data),
              envelope.schemaVersion == 1,
              !envelope.value.isEmpty, envelope.value.utf8.count <= 512 else {
            throw BalanceError.unavailable("Grok Bot 账号缓存格式已变化，请更新适配器")
        }
        return envelope.value
    }

    public static func usageKey(accountSlot: String) throws -> String {
        // 与客户端的 encodeURIComponent 一致，不使用 urlPathAllowed（它保留 '/'）。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let encoded = accountSlot.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw BalanceError.unavailable("无法识别 Grok Bot 当前账号")
        }
        return "sand.client.slice.account.\(encoded).weekly-usage.cache"
    }

    public static func fileName(for key: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var result = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in key.utf8 {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((buffer >> bits) & 31)])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: result, as: UTF8.self) + ".blob"
    }

    public static func parse(data: Data, now: Date = Date()) throws -> BalanceReading {
        try checkSize(data)
        guard let envelope = try? JSONDecoder().decode(UsageEnvelope.self, from: data),
              envelope.schemaVersion == 2 else {
            throw BalanceError.unavailable("Grok Bot 用量缓存格式已变化，请更新适配器")
        }
        let value = envelope.value
        guard value.kind == "present", let reading = value.reading else {
            throw BalanceError.unavailable("Grok Bot 尚无可用额度缓存，请在客户端查看用量")
        }
        let usage = reading.usage
        guard usage.percentUsed.isFinite, usage.percentUsed >= 0,
              usage.hasNonZeroIncludedLimit else {
            throw BalanceError.unavailable("Grok Bot 当前套餐没有可读取的周额度")
        }
        let nowMs = now.timeIntervalSince1970 * 1_000
        guard nowMs.isFinite, reading.readAtMs.isFinite, reading.readAtMs > 0,
              reading.readAtMs <= nowMs, value.expiresAtMs.isFinite,
              value.expiresAtMs > reading.readAtMs else {
            throw BalanceError.unavailable("Grok Bot 缓存时间无效，请在客户端刷新用量")
        }
        guard value.expiresAtMs > nowMs, nowMs - reading.readAtMs < 86_400_000 else {
            throw BalanceError.unavailable("Grok Bot 额度缓存已过期，请在客户端刷新用量")
        }
        var reset: Date?
        if let resetMs = usage.nextResetMs {
            guard resetMs.isFinite, resetMs > nowMs else {
                throw BalanceError.unavailable("Grok Bot 已进入新的额度周期，请在客户端刷新用量")
            }
            reset = Date(timeIntervalSince1970: resetMs / 1_000)
        }
        let remaining = min(100, max(0, 100 - usage.percentUsed))
        let rounded = (remaining * 10).rounded() / 10
        let percent = rounded == rounded.rounded()
            ? String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), rounded)
            : String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), rounded)
        let label = usage.isSandTrial ? "试用额度剩余" : "每周剩余"
        let isTeam = value.selectedTeamId != nil || usage.isTeamSeat == true
        return BalanceReading(
            service: .grok,
            metrics: [BalanceMetric(id: "weekly", label: isTeam ? "团队席位 · \(label)" : label,
                                    value: percent, remainingFraction: remaining / 100, resetsAt: reset)],
            fetchedAt: Date(timeIntervalSince1970: reading.readAtMs / 1_000),
            source: "客户端缓存"
        )
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count < maximumFileBytes else {
            throw BalanceError.unavailable("Grok Bot 额度缓存大小异常，已停止读取")
        }
    }

    private struct SlotEnvelope: Decodable { let schemaVersion: Int; let value: String }
    private struct UsageEnvelope: Decodable { let schemaVersion: Int; let value: CacheValue }
    private struct CacheValue: Decodable {
        let kind: String
        let selectedTeamId: Int?
        let reading: CachedReading?
        let expiresAtMs: Double
        enum CodingKeys: String, CodingKey { case kind, selectedTeamId, reading, expiresAtMs }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            // 明确区分 null（个人）与缺字段（格式未知）。
            selectedTeamId = try c.decode(Int?.self, forKey: .selectedTeamId)
            if let selectedTeamId, selectedTeamId <= 0 {
                throw DecodingError.dataCorruptedError(forKey: .selectedTeamId, in: c, debugDescription: "Invalid team scope")
            }
            reading = try c.decodeIfPresent(CachedReading.self, forKey: .reading)
            expiresAtMs = try c.decode(Double.self, forKey: .expiresAtMs)
        }
    }
    private struct CachedReading: Decodable { let usage: Usage; let readAtMs: Double }
    private struct Usage: Decodable {
        let percentUsed: Double
        let nextResetMs: Double?
        let isSandTrial: Bool
        let hasNonZeroIncludedLimit: Bool
        let isTeamSeat: Bool?
        enum CodingKeys: String, CodingKey {
            case percentUsed, nextResetMs, isSandTrial, hasNonZeroIncludedLimit, isTeamSeat
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            percentUsed = try c.decode(Double.self, forKey: .percentUsed)
            nextResetMs = try c.decode(Double?.self, forKey: .nextResetMs)
            isSandTrial = try c.decode(Bool.self, forKey: .isSandTrial)
            hasNonZeroIncludedLimit = try c.decode(Bool.self, forKey: .hasNonZeroIncludedLimit)
            isTeamSeat = try c.decodeIfPresent(Bool.self, forKey: .isTeamSeat)
        }
    }
}
