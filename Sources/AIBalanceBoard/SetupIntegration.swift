import AppKit
import Foundation
import Darwin

/// User-initiated local setup only. No browser configuration, credentials or model calls.
enum SetupIntegration {
    static let label = "local.outlier.ai-balance-board.login"
    static let hostName = "local.outlier.ai_balance_board"
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Balance Board")
    static let extensionFolder = support.appendingPathComponent("Chrome Extension")
    static let hostManifest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json")
    static let loginPlist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let extensionFiles = ["manifest.json", "background.js", "content.js", "protocol.js", "popup.html", "popup.js", "popup.css"]

    /// Tests use a private temporary root and a fake command runner. No production
    /// action takes its installation home from an environment variable.
    struct Context {
        let home: URL
        let command: (String, [String]) throws -> Int32
        static var live: Context { Context(home: FileManager.default.homeDirectoryForCurrentUser, command: SetupIntegration.run) }
        var support: URL { home.appendingPathComponent("Library/Application Support/AI Balance Board") }
        var extensionFolder: URL { support.appendingPathComponent("Chrome Extension") }
        var launcher: URL { support.appendingPathComponent("browser-bridge-host.sh") }
        var bridgeDirectory: URL { support.appendingPathComponent("browser-bridge") }
        var hostManifest: URL { home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json") }
        var loginPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func bridgeRegistered(context: Context = .live) -> Bool {
        let hostManifest = context.hostManifest, support = context.support
        do { try checkParents(context: context); try safeFile(hostManifest); try safeFile(context.launcher) }
        catch { return false }
        guard let data = try? Data(contentsOf: hostManifest),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["name"] as? String == hostName,
              value["type"] as? String == "stdio",
              value["allowed_origins"] as? [String] == [BrowserBridgeConfiguration.origin],
              value["path"] as? String == support.appendingPathComponent("browser-bridge-host.sh").path else { return false }
        return FileManager.default.isExecutableFile(atPath: support.appendingPathComponent("browser-bridge-host.sh").path)
    }

    static func registerBridge(app: URL, context: Context = .live) throws {
        try validateApp(app, context: context)
        let support = context.support, extensionFolder = context.extensionFolder, hostManifest = context.hostManifest
        let resources = app.appendingPathComponent("Contents/Resources/browser-extension")
        for name in extensionFiles {
            guard FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path) else {
                throw Failure(message: "安装包缺少 Chrome 连接器，请重新下载完整安装包。")
            }
        }
        try checkParents(context: context)
        try ensureDirectory(support, privateMode: true)
        try ensureDirectory(extensionFolder, privateMode: true)
        try ensureDirectory(hostManifest.deletingLastPathComponent())
        try safeFile(hostManifest)
        if FileManager.default.fileExists(atPath: hostManifest.path) {
            try safeFile(hostManifest)
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: hostManifest)) as? [String: Any],
                  value["name"] as? String == hostName,
                  value["type"] as? String == "stdio",
                  value["path"] as? String == context.launcher.path,
                  value["allowed_origins"] as? [String] == [BrowserBridgeConfiguration.origin] else {
                throw Failure(message: "发现不同的本机连接配置，未覆盖。请先检查已有安装。")
            }
        }
        try safeFile(context.launcher)
        for name in extensionFiles { try safeFile(extensionFolder.appendingPathComponent(name)) }
        for name in extensionFiles {
            try write(Data(contentsOf: resources.appendingPathComponent(name)), to: extensionFolder.appendingPathComponent(name))
        }
        let launcher = support.appendingPathComponent("browser-bridge-host.sh")
        try write(launcherData(app: app), to: launcher, mode: 0o700)
        let manifest: [String: Any] = ["name": hostName, "description": "AI 额度看板：只接收 Cursor 额度查询结果", "path": launcher.path, "type": "stdio", "allowed_origins": [BrowserBridgeConfiguration.origin]]
        try write(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), to: hostManifest)
    }

    static func unregisterBridge(app: URL, context: Context = .live) throws {
        try validateApp(app, context: context)
        try checkParents(context: context)
        let manifest = context.hostManifest, launcher = context.launcher, folder = context.extensionFolder
        try safeFile(manifest); try safeFile(launcher)
        let hasManifest = FileManager.default.fileExists(atPath: manifest.path)
        let hasLauncher = FileManager.default.fileExists(atPath: launcher.path)
        let hasFolder = FileManager.default.fileExists(atPath: folder.path)
        guard hasManifest || hasLauncher || hasFolder else { return }
        if hasManifest {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
                  value["name"] as? String == hostName, value["type"] as? String == "stdio",
                  value["path"] as? String == launcher.path,
                  value["allowed_origins"] as? [String] == [BrowserBridgeConfiguration.origin] else {
                throw Failure(message: "本机通信配置不属于本看板，未移除。")
            }
        }
        if hasLauncher, try Data(contentsOf: launcher) != launcherData(app: app) {
            throw Failure(message: "本机启动器对应其他应用路径，未移除。请从原安装位置操作。")
        }
        let extensionManifest = folder.appendingPathComponent("manifest.json")
        try safeFile(extensionManifest)
        if FileManager.default.fileExists(atPath: extensionManifest.path) {
            let sourceURL = app.appendingPathComponent("Contents/Resources/browser-extension/manifest.json")
            guard let source = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any],
                  let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: extensionManifest)) as? [String: Any],
                  let key = source["key"] as? String, !key.isEmpty, installed["key"] as? String == key else {
                throw Failure(message: "扩展目录不属于本看板，未移除。")
            }
        } else if !hasManifest && !hasLauncher {
            throw Failure(message: "扩展目录缺少可验证的本看板标识，未移除。")
        }
        let targets = extensionFiles.map { folder.appendingPathComponent($0) } + [launcher, manifest]
        for file in targets { try safeFile(file) }
        try ensureDirectory(context.bridgeDirectory, privateMode: true)
        let lockURL = context.bridgeDirectory.appendingPathComponent("bridge-host.lock")
        try safeFile(lockURL)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "无法打开本机连接锁。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        try checkLock(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "Chrome 连接器仍在运行。请先停用扩展，再移除本机组件。")
        }
        for file in targets where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        if hasFolder, try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty {
            try FileManager.default.removeItem(at: folder)
        }
        // Browser profile pairing and quota records are deliberately retained.
    }

    static func loginEnabled(context: Context = .live) -> Bool {
        do { try checkParents(context: context); try safeFile(context.loginPlist) }
        catch { return false }
        guard let data = try? Data(contentsOf: context.loginPlist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Label"] as? String == label,
              let args = value["ProgramArguments"] as? [String], args.count == 3,
              args[0] == "/usr/bin/open", args[1] == "-g",
              Bundle(url: URL(fileURLWithPath: args[2]))?.bundleIdentifier == "local.outlier.ai-balance-board" else { return false }
        return (try? context.command("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])) == 0
    }

    static func setLoginEnabled(_ enabled: Bool, app: URL, context: Context = .live) throws {
        try validateApp(app, context: context)
        try checkParents(context: context)
        let loginPlist = context.loginPlist
        try ensureDirectory(loginPlist.deletingLastPathComponent())
        try safeFile(loginPlist)
        if FileManager.default.fileExists(atPath: loginPlist.path) {
            try safeFile(loginPlist)
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: loginPlist), format: nil) as? [String: Any],
                  value["Label"] as? String == label,
                  let args = value["ProgramArguments"] as? [String], args.count == 3,
                  args[0] == "/usr/bin/open", args[1] == "-g",
                  args[2].hasPrefix("/"),
                  Bundle(url: URL(fileURLWithPath: args[2]))?.bundleIdentifier == "local.outlier.ai-balance-board",
                  value["RunAtLoad"] as? Bool == true,
                  value["LimitLoadToSessionType"] as? String == "Aqua",
                  Set(value.keys) == Set(["Label", "ProgramArguments", "RunAtLoad", "LimitLoadToSessionType"]) else {
                throw Failure(message: "已有启动项不属于本看板的标准配置，未修改。")
            }
        }
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        if !enabled {
            guard try context.command("/bin/launchctl", ["disable", service]) == 0 else { throw Failure(message: "无法停用登录启动项。") }
            if loginEnabled(context: context), try context.command("/bin/launchctl", ["bootout", service]) != 0 { throw Failure(message: "启动项未能卸载，请重试。") }
            return
        }
        let value: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", app.path], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try write(data, to: loginPlist)
        guard try context.command("/bin/launchctl", ["enable", service]) == 0 else { throw Failure(message: "无法启用登录启动项。") }
        if loginEnabled(context: context), try context.command("/bin/launchctl", ["bootout", service]) != 0 { throw Failure(message: "现有启动项未能卸载，未重复加载，请重试。") }
        guard try context.command("/bin/launchctl", ["bootstrap", domain, loginPlist.path]) == 0 else { throw Failure(message: "启动项已保存，但系统未能加载，请稍后重试。") }
    }

    static func resetBrowserPairing(context: Context = .live) throws {
        try checkParents(context: context)
        let directory = context.bridgeDirectory
        try ensureDirectory(directory, privateMode: true)
        let lockURL = directory.appendingPathComponent("bridge-host.lock")
        try safeFile(lockURL)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "无法打开本机连接锁。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        try checkLock(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "Chrome 连接器仍在运行。请先停用扩展，再重置绑定。")
        }
        let requestLock = directory.appendingPathComponent("app-request.lock")
        try safeFile(requestLock)
        let requestFD = open(requestLock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard requestFD >= 0 else { throw Failure(message: "无法打开额度查询锁。") }
        defer { flock(requestFD, LOCK_UN); close(requestFD) }
        try checkLock(requestFD)
        guard flock(requestFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure(message: "看板正在读取额度，请稍后重试。") }
        for name in ["pairing.json", "presence.json", "request.json", "result.json"] {
            try safeFile(directory.appendingPathComponent(name))
        }
        for name in ["pairing.json", "presence.json", "request.json", "result.json"] {
            let file = directory.appendingPathComponent(name)
            try safeFile(file)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    private static func validateApp(_ app: URL, context: Context = .live) throws {
        var info = stat()
        guard app.isFileURL, app.pathExtension == "app", lstat(app.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "local.outlier.ai-balance-board",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "AIBalanceBoard",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/AIBalanceBoard").path),
              try context.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw Failure(message: "请从完整的 AI 额度看板.app 打开设置。")
        }
    }

    private static func launcherData(app: URL) -> Data {
        let executable = app.appendingPathComponent("Contents/MacOS/AIBalanceBoard").path
        let safe = executable.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil
        let quoted = safe ? executable : "'" + executable.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return Data(("#!/bin/sh\nexec " + quoted + " --browser-bridge-host \"$@\"\n").utf8)
    }

    private static func checkLock(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw Failure(message: "本机连接锁文件异常，未修改。")
        }
    }

    private static func checkParents(context: Context) throws {
        for target in [context.extensionFolder, context.hostManifest.deletingLastPathComponent(), context.loginPlist.deletingLastPathComponent(), context.bridgeDirectory] {
            var cursor = target
            while true {
                var info = stat()
                if lstat(cursor.path, &info) == 0 {
                    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                        throw Failure(message: "设置路径包含符号链接或非当前用户的目录，未修改。")
                    }
                } else if errno != ENOENT { throw Failure(message: "无法检查设置目录。") }
                if cursor.standardizedFileURL.path == context.home.standardizedFileURL.path { break }
                let parent = cursor.deletingLastPathComponent()
                guard parent.path != cursor.path, cursor.path.hasPrefix(context.home.path + "/") else {
                    throw Failure(message: "设置路径超出当前用户目录，未修改。")
                }
                cursor = parent
            }
        }
    }

    private static func ensureDirectory(_ url: URL, privateMode: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw Failure(message: "安装目录不是当前用户拥有的真实目录，未修改。")
            }
        } else {
            let parent = url.deletingLastPathComponent()
            if parent.path != url.path { try ensureDirectory(parent) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if privateMode { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }

    private static func safeFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                throw Failure(message: "目标文件不是当前用户的普通文件，未修改。")
            }
        } else if errno != ENOENT { throw Failure(message: "无法检查安装文件。") }
    }

    private static func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        try safeFile(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure(message: "系统操作超时，请稍后重试。")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
