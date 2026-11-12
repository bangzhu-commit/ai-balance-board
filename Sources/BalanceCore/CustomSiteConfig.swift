import Foundation

public enum CustomSiteMode: String, Codable, Sendable { case json, dom }
public enum CustomMetricMeaning: String, Codable, Sendable { case balance, remaining, used }
public enum CustomMetricOperation: String, Codable, Sendable { case value, remaining }

public enum CustomSiteError: LocalizedError {
    case invalidConfiguration(String), invalidReading, storage
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return "配置不符合要求：" + reason
        case .invalidReading: return "未取得有效额度，请检查登录状态、字段规则和数值格式；已保留上次数据。"
        case .storage: return "自定义站点配置未能读取或保存，请检查本机文件权限。"
        }
    }
}

/// Only scalar success markers are permitted; no executable predicates.
public enum CustomJSONScalar: Codable, Equatable, Sendable {
    case bool(Bool), string(String), number(Double)
    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? box.decode(String.self), value.count <= 100 { self = .string(value) }
        else { throw CustomSiteError.invalidConfiguration("成功标记必须是简短字符串、有限数字或布尔值") }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self { case .bool(let v): try box.encode(v); case .string(let v): try box.encode(v); case .number(let v): try box.encode(v) }
    }
}

public struct CustomSiteSuccess: Codable, Equatable, Sendable {
    public var path: String
    public var equals: CustomJSONScalar
    public init(path: String, equals: CustomJSONScalar) { self.path = path; self.equals = equals }
    enum CodingKeys: String, CodingKey { case path, equals }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["path", "equals"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        path = try box.decode(String.self, forKey: .path); equals = try box.decode(CustomJSONScalar.self, forKey: .equals)
    }
}

/// A typed comparison over each array item; never an executable expression.
public struct CustomCollectionFilter: Codable, Equatable, Sendable {
    public var path: String
    public var equals: CustomJSONScalar
    public var negate: Bool
    public init(path: String, equals: CustomJSONScalar, negate: Bool = false) {
        self.path = path; self.equals = equals; self.negate = negate
    }
    enum CodingKeys: String, CodingKey { case path, equals, negate }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["path", "equals", "negate"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        path = try box.decode(String.self, forKey: .path)
        equals = try box.decode(CustomJSONScalar.self, forKey: .equals)
        negate = box.contains(.negate) ? try box.decode(Bool.self, forKey: .negate) : false
    }
}

/// Fixed JSON array summation. Metric value/total pointers are relative to each item.
public struct CustomMetricCollection: Codable, Equatable, Sendable {
    public static let maxItems = 1_000
    public var path: String
    public var filter: CustomCollectionFilter?
    public init(path: String, filter: CustomCollectionFilter? = nil) {
        self.path = path; self.filter = filter
    }
    enum CodingKeys: String, CodingKey { case path, filter }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["path", "filter"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        path = try box.decode(String.self, forKey: .path)
        filter = box.contains(.filter) ? try box.decode(CustomCollectionFilter.self, forKey: .filter) : nil
    }
}

public struct CustomSiteMetric: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var unit: String
    public var meaning: CustomMetricMeaning
    /// JSON Pointer in JSON mode, CSS selector in DOM mode.
    public var value: String
    public var total: String?
    public var operation: CustomMetricOperation
    public var multiplier: Double
    public var prefix: String
    public var suffix: String
    public var collection: CustomMetricCollection?

    public init(id: String, label: String, unit: String, meaning: CustomMetricMeaning, value: String,
                total: String? = nil, operation: CustomMetricOperation = .value, multiplier: Double = 1,
                prefix: String = "", suffix: String = "", collection: CustomMetricCollection? = nil) {
        self.id = id; self.label = label; self.unit = unit; self.meaning = meaning; self.value = value
        self.total = total; self.operation = operation; self.multiplier = multiplier; self.prefix = prefix; self.suffix = suffix
        self.collection = collection
    }
    enum CodingKeys: String, CodingKey { case id, label, unit, meaning, value, total, operation, multiplier, prefix, suffix, collection }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "label", "unit", "meaning", "value", "total", "operation", "multiplier", "prefix", "suffix", "collection"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id); label = try box.decode(String.self, forKey: .label)
        unit = try box.decode(String.self, forKey: .unit); meaning = try box.decode(CustomMetricMeaning.self, forKey: .meaning)
        value = try box.decode(String.self, forKey: .value); total = try box.decodeIfPresent(String.self, forKey: .total)
        operation = try box.decodeIfPresent(CustomMetricOperation.self, forKey: .operation) ?? .value
        multiplier = try box.decodeIfPresent(Double.self, forKey: .multiplier) ?? 1
        prefix = try box.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try box.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        collection = box.contains(.collection) ? try box.decode(CustomMetricCollection.self, forKey: .collection) : nil
    }
}

public struct CustomSiteConfig: Codable, Equatable, Sendable {
    public static let maxConfigBytes = 65_536
    public var schemaVersion: Int
    public var name: String
    public var origin: String
    public var loginPath: String
    public var pagePath: String
    public var mode: CustomSiteMode
    public var requestPath: String?
    public var success: CustomSiteSuccess?
    public var metrics: [CustomSiteMetric]

    public init(schemaVersion: Int = 1, name: String, origin: String, loginPath: String, pagePath: String,
                mode: CustomSiteMode, requestPath: String? = nil, success: CustomSiteSuccess? = nil,
                metrics: [CustomSiteMetric]) {
        self.schemaVersion = schemaVersion; self.name = name; self.origin = origin; self.loginPath = loginPath
        self.pagePath = pagePath; self.mode = mode; self.requestPath = requestPath; self.success = success; self.metrics = metrics
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, name, origin, loginPath, pagePath, mode, requestPath, success, metrics }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["schemaVersion", "name", "origin", "loginPath", "pagePath", "mode", "requestPath", "success", "metrics"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion); name = try box.decode(String.self, forKey: .name)
        origin = try box.decode(String.self, forKey: .origin); loginPath = try box.decode(String.self, forKey: .loginPath)
        pagePath = try box.decode(String.self, forKey: .pagePath); mode = try box.decode(CustomSiteMode.self, forKey: .mode)
        requestPath = try box.decodeIfPresent(String.self, forKey: .requestPath)
        success = try box.decodeIfPresent(CustomSiteSuccess.self, forKey: .success)
        metrics = try box.decode([CustomSiteMetric].self, forKey: .metrics)
        try validate()
    }

    public var originURL: URL { URL(string: origin)! }
    public var loginURL: URL { URL(string: loginPath, relativeTo: originURL)!.absoluteURL }
    public var pageURL: URL { URL(string: pagePath, relativeTo: originURL)!.absoluteURL }
    public var requestURL: URL? { requestPath.flatMap { URL(string: $0, relativeTo: originURL)?.absoluteURL } }

    /// The supported import boundary. Unknown fields are rejected instead of silently ignored.
    public static func decode(data: Data) throws -> CustomSiteConfig {
        guard data.count <= maxConfigBytes, !data.isEmpty else { throw CustomSiteError.invalidConfiguration("文件必须小于 64 KiB") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else { throw CustomSiteError.invalidConfiguration("需要一个 JSON 对象") }
            try strictKeys(root, allowed: ["schemaVersion", "name", "origin", "loginPath", "pagePath", "mode", "requestPath", "success", "metrics"])
            if let marker = root["success"], !(marker is NSNull) {
                guard let marker = marker as? [String: Any] else { throw CustomSiteError.invalidConfiguration("成功标记格式错误") }
                try strictKeys(marker, allowed: ["path", "equals"])
            }
            guard let rows = root["metrics"] as? [[String: Any]] else { throw CustomSiteError.invalidConfiguration("需要额度字段列表") }
            for row in rows {
                try strictKeys(row, allowed: ["id", "label", "unit", "meaning", "value", "total", "operation", "multiplier", "prefix", "suffix", "collection"])
            }
            let config = try JSONDecoder().decode(CustomSiteConfig.self, from: data)
            try config.validate()
            return config
        } catch let error as CustomSiteError { throw error }
        catch { throw CustomSiteError.invalidConfiguration("JSON 字段、版本或类型不正确") }
    }

    public func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw CustomSiteError.invalidConfiguration("不支持的配置版本") }
        guard Self.cleanText(name, max: 50), Self.cleanText(origin, max: 240),
              let url = URLComponents(string: origin), url.scheme == "https",
              let host = url.host, Self.publicHost(host), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, Self.supportedPort(in: origin, components: url),
              url.path.isEmpty || url.path == "/", !origin.contains("%"), !origin.contains("\\") else {
            throw CustomSiteError.invalidConfiguration("站点必须是公开 HTTPS 域名，不允许本机地址、端口、账号或查询参数")
        }
        try Self.validatePath(loginPath); try Self.validatePath(pagePath)
        if mode == .json {
            guard let requestPath else { throw CustomSiteError.invalidConfiguration("JSON 模式需要 requestPath") }
            try Self.validatePath(requestPath)
        } else if requestPath != nil || success != nil { throw CustomSiteError.invalidConfiguration("网页模式不能设置接口或成功标记") }
        if let success {
            try Self.validatePointer(success.path)
            switch success.equals {
            case .number(let number): guard number.isFinite else { throw CustomSiteError.invalidConfiguration("成功标记数字无效") }
            case .string(let value): guard Self.cleanText(value, max: 100, allowEmpty: true) else { throw CustomSiteError.invalidConfiguration("成功标记字符串无效") }
            case .bool: break
            }
        }
        guard !metrics.isEmpty, metrics.count <= 6, Set(metrics.map(\.id)).count == metrics.count else {
            throw CustomSiteError.invalidConfiguration("需要 1–6 个不重复的额度字段")
        }
        for metric in metrics {
            guard metric.id.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
                  Self.cleanText(metric.label, max: 40), Self.cleanText(metric.unit, max: 16),
                  Self.cleanText(metric.prefix, max: 20, allowEmpty: true), Self.cleanText(metric.suffix, max: 20, allowEmpty: true),
                  metric.multiplier.isFinite, (1e-9...1e9).contains(metric.multiplier) else {
                throw CustomSiteError.invalidConfiguration("额度名称、单位或换算倍率不正确")
            }
            if metric.operation == .remaining && (metric.total == nil || metric.meaning != .remaining) {
                throw CustomSiteError.invalidConfiguration("总额减已用需要 total，且 meaning 必须为 remaining")
            }
            if let collection = metric.collection {
                guard schemaVersion == 2, mode == .json, success != nil, metric.unit != "%" else {
                    throw CustomSiteError.invalidConfiguration("数组汇总需要版本 2、JSON 模式及成功标记，不能直接汇总百分比")
                }
                try Self.validatePointer(collection.path)
                if let filter = collection.filter {
                    try Self.validatePointer(filter.path)
                    switch filter.equals {
                    case .number(let number):
                        guard number.isFinite, abs(number) <= 9_007_199_254_740_991 else {
                            throw CustomSiteError.invalidConfiguration("数组筛选数字无效")
                        }
                    case .string(let value):
                        guard Self.cleanText(value, max: 100, allowEmpty: true) else {
                            throw CustomSiteError.invalidConfiguration("数组筛选字符串无效")
                        }
                    case .bool: break
                    }
                }
            }
            for locator in [metric.value, metric.total].compactMap({ $0 }) {
                if mode == .json { try Self.validatePointer(locator) }
                else {
                    guard Self.cleanText(locator, max: 300), !locator.contains("{"), !locator.contains("}"),
                          !locator.contains(";"), !locator.lowercased().contains("javascript:") else {
                        throw CustomSiteError.invalidConfiguration("网页字段需要简短 CSS 选择器，不能包含脚本")
                    }
                }
            }
        }
    }

    private static func strictKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw CustomSiteError.invalidConfiguration("包含不支持的字段；禁止导入脚本、请求头或凭据") }
    }
    private static func cleanText(_ text: String, max: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && text.count <= max &&
            !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func supportedPort(in origin: String, components: URLComponents) -> Bool {
        guard components.port == nil || components.port == 443,
              let separator = origin.range(of: "://") else { return false }
        let authority = origin[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Foundation returns nil for both an omitted port and some malformed
        // numeric ports. Only a truly absent port may use the HTTPS default.
        return !authority.contains(":") || components.port == 443
    }

    private static func publicHost(_ host: String) -> Bool {
        let host = host.lowercased()
        let forbidden = ["localhost", ".localhost", ".local", ".internal", ".lan", ".home", ".invalid"]
        guard !forbidden.contains(where: { host == $0 || host.hasSuffix($0) }), !host.contains(":"),
              host.range(of: "^[a-z0-9-]+(?:\\.[a-z0-9-]+)+$", options: .regularExpression) != nil else { return false }
        let labels = host.split(separator: ".")
        guard let last = labels.last, last.range(of: "^[a-z]{2,63}$", options: .regularExpression) != nil else { return false }
        return labels.allSatisfy { $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }
    private static func validatePath(_ path: String) throws {
        guard cleanText(path, max: 400), path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\"),
              !path.contains(" "), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CustomSiteError.invalidConfiguration("路径必须同源，以 / 开头且不含查询参数、转义或跳转")
        }
        let denied: Set<String> = ["chat", "completions", "responses", "messages", "embeddings", "images", "audio",
            "generate", "execute", "delete", "remove", "logout", "revoke", "reset", "purchase", "checkout",
            "pay", "payment", "topup", "recharge", "transfer", "create", "update", "cancel"]
        guard !path.lowercased().split(separator: "/").contains(where: { denied.contains(String($0)) }) else {
            throw CustomSiteError.invalidConfiguration("路径包含生成、支付或修改操作；仅允许额度读取")
        }
    }
    internal static func validatePointer(_ pointer: String) throws {
        guard pointer.hasPrefix("/"), cleanText(pointer, max: 300),
              !pointer.contains("~") || pointer.range(of: "~(?![01])", options: .regularExpression) == nil else {
            throw CustomSiteError.invalidConfiguration("JSON 字段必须使用有效 JSON Pointer，例如 /data/balance")
        }
    }
}

public struct CustomSiteRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var config: CustomSiteConfig
    public var serviceID: ServiceID { .custom(id) }
    public init(id: UUID = UUID(), config: CustomSiteConfig) { self.id = id; self.config = config }
    enum CodingKeys: String, CodingKey { case id, config }
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "config"])
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id); config = try box.decode(CustomSiteConfig.self, forKey: .config)
        try validate()
    }
    public func validate() throws {
        guard ServiceID(rawValue: "custom:" + id.uuidString) != nil else { throw CustomSiteError.invalidConfiguration("站点标识无效") }
        try config.validate()
    }
}

/// Stores only declarative extraction rules. Session cookies remain in WebKit.
public struct CustomSiteRepository {
    public static let maxSites = 12
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [CustomSiteRecord] {
        guard !isSymlink(url), !isSymlink(url.deletingLastPathComponent()) else { throw CustomSiteError.storage }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            guard !isSymlink(url), ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 1_048_576 else { throw CustomSiteError.storage }
            let data = try Data(contentsOf: url)
            let records = try JSONDecoder().decode([CustomSiteRecord].self, from: data)
            try validate(records)
            // Each stored config passes through exactly the same strict import boundary.
            for record in records { _ = try CustomSiteConfig.decode(data: JSONEncoder().encode(record.config)) }
            return records
        } catch let error as CustomSiteError { throw error }
        catch { throw CustomSiteError.storage }
    }
    public func save(_ records: [CustomSiteRecord]) throws {
        try validate(records)
        do {
            let directory = url.deletingLastPathComponent()
            guard !isSymlink(url), !isSymlink(directory) else { throw CustomSiteError.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw CustomSiteError.storage }
    }
    private func validate(_ records: [CustomSiteRecord]) throws {
        guard records.count <= Self.maxSites, Set(records.map(\.id)).count == records.count else {
            throw CustomSiteError.invalidConfiguration("最多保存 12 个独立站点，标识不能重复")
        }
        for record in records { try record.validate() }
    }
    private func isSymlink(_ path: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil }
}

private struct ArbitraryCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: ArbitraryCodingKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: allowed) else {
        throw CustomSiteError.invalidConfiguration("包含不支持的字段；禁止导入脚本、请求头或凭据")
    }
}
