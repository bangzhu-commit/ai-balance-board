import BalanceCore
import Darwin
import Foundation

struct CodexProvider {
    private let customExecutablePath: String?
    private let requestTimeout: TimeInterval

    init(customExecutablePath: String? = nil, requestTimeout: TimeInterval = 20) {
        self.customExecutablePath = customExecutablePath
        self.requestTimeout = requestTimeout.isFinite ? min(20, max(0.1, requestTimeout)) : 20
    }

    func fetch() async throws -> BalanceReading {
        let probe = CodexQuotaProbe(customPath: customExecutablePath, timeout: requestTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try probe.fetch() })
                }
            }
        } onCancel: {
            probe.cancel()
        }
    }
}

/// Owns exactly one short-lived stdio process. No login, token access, or model turn.
private final class CodexQuotaProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let customPath: String?
    private let timeout: TimeInterval

    init(customPath: String?, timeout: TimeInterval) {
        self.customPath = customPath
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func fetch() throws -> BalanceReading {
        if isCancelled { throw CancellationError() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let diagnosis = CodexExecutableResolver.diagnose(customPath: customPath)
        guard let executable = diagnosis.executableURL else {
            throw BalanceError.dependencyMissing(diagnosis.message)
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = home
        // Preserve the current process's selected environment, adding known node
        // locations for GUI launches without sourcing shell/login configuration.
        process.environment = CodexExecutableResolver.launchEnvironment(for: executable)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do { try process.run() } catch {
            throw BalanceError.dependencyMissing("无法启动选定的 Codex CLI，请检查文件权限、安装完整性与系统兼容性。")
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let exitDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < exitDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        if isCancelled { throw CancellationError() }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw BalanceError.invalidResponse("无法建立 Codex CLI 额度读取通道。")
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        func send(_ message: [String: Any]) throws {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else {
                throw BalanceError.invalidResponse("无法构造 Codex CLI 额度查询请求。")
            }
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch {
                throw BalanceError.network("Codex 额度读取连接已中断，请稍后重试。")
            }
        }
        try send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "ai_balance_board", "title": "AI 额度看板", "version": "0.1.0"], "capabilities": NSNull()]
        ])

        var pending = Data()
        var initialized = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var totalRead = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if isCancelled { throw CancellationError() }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw BalanceError.network("Codex 额度读取连接异常，请稍后重试。")
            }
            if ready == 0 { continue }
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw BalanceError.network("Codex 额度读取连接异常，请稍后重试。")
            }
            totalRead += count
            guard totalRead <= 1_048_576 else {
                throw BalanceError.invalidResponse("Codex 额度响应超出预期，请检查 CLI 版本。")
            }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw BalanceError.invalidResponse("Codex CLI 返回了无法识别的协议数据，请检查可执行文件与版本。")
                }
                guard let identifier = object["id"] as? Int else {
                    if object["method"] is String { continue } // Unsolicited protocol notification.
                    throw BalanceError.invalidResponse("Codex CLI 返回了不完整的协议响应，请检查版本。")
                }
                if identifier == 1 && !initialized {
                    if let error = object["error"] as? [String: Any] {
                        throw classifyRPCError(error, initializing: true)
                    }
                    guard object["error"] == nil || object["error"] is NSNull,
                          object["result"] is [String: Any] else {
                        throw BalanceError.invalidResponse("Codex CLI 初始化不兼容，请更新 CLI 或重新选择可执行文件。")
                    }
                    initialized = true
                    try send(["method": "initialized", "params": [:]])
                    try send([
                        "id": 2, "method": "account/rateLimits/read",
                        "params": ["excludeResetCreditDetails": true]
                    ])
                } else if identifier == 2 && initialized {
                    if let error = object["error"] as? [String: Any] {
                        throw classifyRPCError(error, initializing: false)
                    }
                    do { return try CodexParser.parse(line) }
                    catch {
                        throw BalanceError.invalidResponse("Codex 未返回可识别的额度数据，请确认 CLI 版本后重试。")
                    }
                }
            }
        }
        if isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            throw BalanceError.network("Codex 额度读取超时，请检查网络后重试。")
        }
        if !process.isRunning && process.terminationStatus == 127 {
            throw BalanceError.dependencyMissing("Codex CLI 的运行依赖不可用，请检查 Node.js 或重新选择完整安装的 CLI。")
        }
        throw BalanceError.invalidResponse("Codex CLI 提前退出或未返回额度，请检查 CLI 版本与安装完整性。")
    }

    /// Inspect error categories locally, but never expose server text, request
    /// details, or authentication material in UI, diagnostics, or logs.
    private func classifyRPCError(_ error: [String: Any], initializing: Bool) -> BalanceError {
        let data = error["data"] as? [String: Any] ?? [:]
        let statusKeys = ["status", "statusCode", "status_code", "httpStatus", "http_status"]
        let status = statusKeys.compactMap { key -> Int? in
            let value = data[key] ?? error[key]
            if let number = value as? Int { return number }
            if let string = value as? String { return Int(string) }
            return nil
        }.first
        let message = String((error["message"] as? String ?? "").prefix(2048)).lowercased()
        let errorCode = String(describing: data["code"] ?? error["code"] ?? "").lowercased()
        let authentication = ["not logged in", "not signed in", "not authenticated", "sign in", "login required", "authentication",
                              "unauthenticated", "unauthorized", "auth is required", "auth required",
                              "invalid token", "expired token", "refresh token", "only available for chatgpt", "requires a chatgpt"]
        if status == 401 || status == 403 || authentication.contains(where: { message.contains($0) || errorCode.contains($0) }) {
            return .authenticationRequired("Codex 当前登录状态或账号权限无法读取额度，请在所选 CLI 中登录 ChatGPT 后重试。")
        }
        if status == 429 || message.contains("too many requests") || message.contains("rate limit") {
            return .rateLimited("Codex 额度接口请求受限，请稍后重试。")
        }
        let network = ["timed out", "timeout", "network", "connection", "dns", "error sending request", "failed to fetch"]
        if status == 408 || (status.map { (500...599).contains($0) } ?? false) || network.contains(where: { message.contains($0) }) {
            return .network("Codex 额度服务暂时无法连接，请稍后重试。")
        }
        if initializing {
            return .invalidResponse("Codex CLI 初始化不兼容，请更新 CLI 或重新选择可执行文件。")
        }
        return .invalidResponse("Codex 未能返回可识别的额度响应，请检查 CLI 版本后重试。")
    }
}
