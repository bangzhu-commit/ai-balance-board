import CoreFoundation
import Darwin
import Foundation

/// Chrome native-messaging entry point. It never initializes AppKit or accesses the network.
enum BrowserBridgeHost {
    static func run(expectedOrigin: String, directory: URL? = nil) -> Never {
        exit(execute(expectedOrigin: expectedOrigin, directory: directory))
    }

    private static func execute(expectedOrigin: String, directory: URL?) -> Int32 {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.count >= 3, arguments[1] == "--browser-bridge-host",
                  arguments[2] == expectedOrigin,
                  expectedOrigin.range(of: #"^chrome-extension://[a-p]{32}/$"#, options: .regularExpression) != nil else {
                throw BridgeFailure.origin
            }
            let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AI Balance Board/browser-bridge", isDirectory: true)
            let host = try Host(directory: base)
            defer { host.shutdown() }
            try host.loop()
            return 0
        } catch let error as BridgeFailure {
            let message: String
            switch error {
            case .origin: message = "bridge: origin rejected\n"
            case .locked: message = "bridge: already connected\n"
            case .pairing: message = "bridge: pairing rejected\n"
            case .protocolViolation: message = "bridge: invalid message\n"
            case .io: message = "bridge: local I/O unavailable\n"
            }
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("bridge: local operation failed\n".utf8))
            return 1
        }
    }
}

private enum BridgeFailure: Error { case origin, locked, pairing, protocolViolation, io }

private final class BridgeDirectory {
    let descriptor: Int32

    init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw BridgeFailure.io }
        // Walk every component with O_NOFOLLOW, not just the final directory.
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw BridgeFailure.io }
        do {
            for component in url.path.split(separator: "/") {
                let part = String(component)
                guard part != ".", part != ".." else { throw BridgeFailure.io }
                var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(current, part, 0o700) == 0 || errno == EEXIST else { throw BridgeFailure.io }
                    next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw BridgeFailure.io }
                Darwin.close(current)
                current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == geteuid(),
                  fchmod(current, 0o700) == 0 else { throw BridgeFailure.io }
            descriptor = current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func lock() throws -> Int32 {
        let fd = openat(descriptor, "bridge-host.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeFailure.io }
        do {
            try checkRegular(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw BridgeFailure.locked }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func read(_ name: String) throws -> [String: Any]? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw BridgeFailure.io }
        defer { Darwin.close(fd) }
        try checkRegular(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 65_536 else { throw BridgeFailure.io }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BridgeFailure.io
            }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 65_536 else { throw BridgeFailure.io }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeFailure.io }
        return object
    }

    func write(_ name: String, _ object: [String: Any]) throws {
        // Reject an existing symbolic link or hard link before the atomic replacement.
        let previous = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if previous >= 0 {
            defer { Darwin.close(previous) }
            try checkRegular(previous)
        } else if errno != ENOENT { throw BridgeFailure.io }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 65_536 else { throw BridgeFailure.io }
        let temporary = ".bridge-\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeFailure.io }
        defer { Darwin.close(fd); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeFailure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0 else { throw BridgeFailure.io }
    }

    private func checkRegular(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { throw BridgeFailure.io }
    }
}

private final class Host {
    private struct Query { let id: UUID; let startedAt: TimeInterval }
    private let directory: BridgeDirectory
    private let lockDescriptor: Int32
    private var generation: UUID?
    private var active: Query?
    private var seenIDs: [UUID] = []
    private var input = Data()
    private var lastTick: TimeInterval = -.infinity
    private var lastHeartbeat: TimeInterval = -.infinity
    private var closed = false
    private let allowedKinds: Set<String> = ["ok", "loginRequired", "httpError", "pageUnavailable", "networkError", "browserUnavailable", "timeout", "rateLimited"]

    init(directory url: URL) throws {
        let directory = try BridgeDirectory(url: url)
        self.directory = directory
        lockDescriptor = try directory.lock()
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                Darwin.close(lockDescriptor)
                throw BridgeFailure.io
            }
        }
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
    }

    func loop() throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try tick()
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw BridgeFailure.io
            }
            if ready == 0 { continue }
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 {
                guard input.isEmpty else { throw BridgeFailure.protocolViolation }
                return
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw BridgeFailure.io
            }
            input.append(contentsOf: bytes.prefix(count))
            while input.count >= 4 {
                let header = Array(input.prefix(4))
                let length = Int(UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
                guard length > 0, length <= 65_536 else { throw BridgeFailure.protocolViolation }
                guard input.count >= length + 4 else { break }
                let message = Data(input.dropFirst(4).prefix(length))
                input.removeFirst(length + 4)
                guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                    throw BridgeFailure.protocolViolation
                }
                try receive(object)
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        if generation != nil {
            if let query = active { try? complete(query, kind: "browserUnavailable", data: nil) }
            try? presence(connected: false)
        }
        flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
    }

    private func receive(_ object: [String: Any]) throws {
        guard let generation else {
            guard object["type"] as? String == "hello", number(object["version"]) == 1,
                  let clientID = uuid(object["clientID"]) else { throw BridgeFailure.protocolViolation }
            if let pairing = try directory.read("pairing.json") {
                guard number(pairing["version"]) == 1, uuid(pairing["clientID"]) == clientID else { throw BridgeFailure.pairing }
            } else {
                try directory.write("pairing.json", ["version": 1, "clientID": clientID.uuidString])
            }
            let freshGeneration = UUID()
            self.generation = freshGeneration
            try presence(connected: true)
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            try send(["type": "ready", "version": 1, "generation": freshGeneration.uuidString])
            return
        }
        guard object["type"] as? String == "result", number(object["version"]) == 1,
              uuid(object["generation"]) == generation,
              let query = active, uuid(object["id"]) == query.id,
              let kind = object["kind"] as? String, allowedKinds.contains(kind) else { return }
        guard ProcessInfo.processInfo.systemUptime - query.startedAt < 30 else {
            try complete(query, kind: "timeout", data: nil)
            return
        }
        var filtered: [String: Any]?
        if kind == "ok" {
            guard let raw = object["data"] as? [String: Any], let clean = filter(raw) else { return }
            filtered = clean
        }
        try complete(query, kind: kind, data: filtered)
    }

    private func tick() throws {
        guard let generation else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastHeartbeat >= 10 {
            try presence(connected: true)
            lastHeartbeat = uptime
        }
        if let query = active, uptime - query.startedAt >= 30 {
            try complete(query, kind: "timeout", data: nil)
        }
        guard uptime - lastTick >= 0.5 else { return }
        lastTick = uptime
        guard active == nil, let request = try directory.read("request.json"),
              number(request["version"]) == 1, uuid(request["generation"]) == generation,
              let id = uuid(request["id"]), !seenIDs.contains(id),
              let createdAt = number(request["createdAt"]) else { return }
        let age = milliseconds - createdAt
        guard age >= -5_000, age <= 60_000 else { return }
        active = Query(id: id, startedAt: uptime)
        seenIDs.append(id)
        if seenIDs.count > 256 { seenIDs.removeFirst(seenIDs.count - 256) }
        try send(["type": "query", "version": 1, "id": id.uuidString, "generation": generation.uuidString])
    }

    private func complete(_ query: Query, kind: String, data: [String: Any]?) throws {
        guard let generation else { return }
        var result: [String: Any] = ["version": 1, "id": query.id.uuidString, "generation": generation.uuidString,
                                     "kind": kind, "receivedAt": milliseconds]
        if let data { result["data"] = data }
        try directory.write("result.json", result)
        active = nil
    }

    private func presence(connected: Bool) throws {
        guard let generation else { return }
        try directory.write("presence.json", ["version": 1, "generation": generation.uuidString,
                                               "connected": connected, "lastSeenAt": milliseconds])
    }

    private var milliseconds: Double { Date().timeIntervalSince1970 * 1000 }
    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func filter(_ raw: [String: Any]) -> [String: Any]? {
        let booleanFields = ["hasNonZeroIncludedLimit", "isTeamSeat", "usesPooledEnterpriseAllowance", "isUnified"]
        var output: [String: Any] = [:]
        for key in booleanFields {
            guard let value = raw[key] else { continue }
            guard value is NSNull || (value as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else { return nil }
            output[key] = value
        }
        if let value = raw["usagePercent"] {
            if value is NSNull { output["usagePercent"] = value }
            else if let numeric = number(value) { output["usagePercent"] = numeric }
            else if let string = value as? String, string.utf8.count <= 128,
                    string.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
                    let numeric = Double(string), numeric.isFinite { output["usagePercent"] = string }
            else { return nil }
        }
        for key in ["nextResetTimestampUtc", "sandTrialExpiresAt"] {
            guard let value = raw[key] else { continue }
            if value is NSNull { output[key] = value }
            else if let string = value as? String, string.utf8.count <= 64,
                    string.range(of: #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?([Zz]|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil {
                output[key] = string
            } else { return nil }
        }
        return output
    }

    private func send(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= 65_536 else { throw BridgeFailure.protocolViolation }
        let length = UInt32(body.count)
        var frame = Data([UInt8(length & 255), UInt8((length >> 8) & 255), UInt8((length >> 16) & 255), UInt8((length >> 24) & 255)])
        frame.append(body)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeFailure.io }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw BridgeFailure.io }
                if ready == 0 { continue }
                let count = Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw BridgeFailure.io }
                offset += count
            }
        }
    }
}
