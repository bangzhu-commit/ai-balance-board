import Foundation
import Darwin
import BalanceCore

enum BrowserBridgeConfiguration {
    static let extensionID = "eghfefbgledejemklpphhpcfknmpbllf"
    static let origin = "chrome-extension://\(extensionID)/"
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Balance Board/browser-bridge", isDirectory: true)
    }
}

enum BrowserBridgeFailure: LocalizedError {
    case unavailable, loginRequired, busy, network, limited, changed, invalid, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Chrome 额度连接未就绪，请打开 Chrome 并启用看板连接扩展"
        case .loginRequired: return "请在 Chrome 登录 Grok Bot 对应的 Cursor 账号"
        case .busy: return "Chrome 额度查询正在进行，请稍后刷新"
        case .network: return "Chrome 额度查询网络失败，保留上次数据"
        case .limited: return "Cursor 暂时限制查询频率，请稍后刷新"
        case .changed: return "Chrome 连接已重建，下一轮将重新查询"
        case .invalid: return "Chrome 额度连接数据无效，请重新连接"
        case .timeout: return "Chrome 额度查询超时，保留上次数据"
        }
    }
    var shouldRetry: Bool {
        switch self {
        case .unavailable, .loginRequired, .busy, .limited: return false
        default: return true
        }
    }
}

struct BrowserBridgeClient {
    let directory: URL
    init(directory: URL = BrowserBridgeConfiguration.directory) { self.directory = directory }

    func connectedGeneration() -> String? {
        guard Self.safeDirectory(directory),
              let presence = try? Self.readJSON(directory.appendingPathComponent("presence.json")) else { return nil }
        return Self.freshGeneration(presence)
    }

    func fetch() async throws -> BalanceReading {
        let job = Task.detached(priority: .utility) { try await fetchDetached() }
        return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
    }

    private func fetchDetached() async throws -> BalanceReading {
        guard Self.safeDirectory(directory) else { throw BrowserBridgeFailure.unavailable }
        let lockPath = directory.appendingPathComponent("app-request.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BrowserBridgeFailure.unavailable }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw BrowserBridgeFailure.busy }
        guard let presence = try? Self.readJSON(directory.appendingPathComponent("presence.json")),
              let generation = Self.freshGeneration(presence) else { throw BrowserBridgeFailure.unavailable }
        let id = UUID().uuidString
        let created = Date().timeIntervalSince1970 * 1000
        try Self.writeJSON(["version": 1, "id": id, "generation": generation, "createdAt": created],
                           to: directory.appendingPathComponent("request.json"))
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let current = try? Self.readJSON(directory.appendingPathComponent("presence.json")),
                  let currentGeneration = Self.freshGeneration(current) else { throw BrowserBridgeFailure.unavailable }
            guard generation == currentGeneration else { throw BrowserBridgeFailure.changed }
            if let result = try? Self.readJSON(directory.appendingPathComponent("result.json")),
               result["id"] as? String == id, result["generation"] as? String == generation {
                guard result["version"] as? Int == 1,
                      let received = result["receivedAt"] as? Double,
                      received.isFinite, received >= created,
                      received <= Date().timeIntervalSince1970 * 1000 + 5000,
                      let kind = result["kind"] as? String else { throw BrowserBridgeFailure.invalid }
                switch kind {
                case "ok":
                    guard let quota = result["data"] as? [String: Any] else { throw BrowserBridgeFailure.invalid }
                    // 读取时间来自本次 Native Messaging 回应，绝不沿用客户端缓存时间。
                    var reading = try GrokServerParser.parse(data: JSONSerialization.data(withJSONObject: quota),
                                                            now: Date(timeIntervalSince1970: received / 1000))
                    reading.source = "Grok Bot 服务器接口（Chrome）"
                    return reading
                case "loginRequired": throw BrowserBridgeFailure.loginRequired
                case "rateLimited": throw BrowserBridgeFailure.limited
                case "browserUnavailable", "pageUnavailable": throw BrowserBridgeFailure.unavailable
                case "timeout": throw BrowserBridgeFailure.timeout
                case "networkError", "httpError": throw BrowserBridgeFailure.network
                default: throw BrowserBridgeFailure.invalid
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BrowserBridgeFailure.timeout
    }

    private static func freshGeneration(_ data: [String: Any]) -> String? {
        guard data["version"] as? Int == 1, data["connected"] as? Bool == true,
              let seen = data["lastSeenAt"] as? Double, seen.isFinite,
              let generation = data["generation"] as? String, UUID(uuidString: generation) != nil else { return nil }
        let age = Date().timeIntervalSince1970 * 1000 - seen
        return age >= -5000 && age <= 25000 ? generation : nil
    }

    private static func safeDirectory(_ url: URL) -> Bool {
        // 专用目录及其应用父目录必须是当前用户的真实目录。
        for target in [url.deletingLastPathComponent(), url] {
            var info = stat()
            guard lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { return false }
        }
        return true
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserBridgeFailure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0, info.st_size > 0, info.st_size <= 65536,
              let bytes = try handle.read(upToCount: 65537), bytes.count <= 65536,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw BrowserBridgeFailure.invalid }
        return value
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".request-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrowserBridgeFailure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw BrowserBridgeFailure.invalid }
    }
}
