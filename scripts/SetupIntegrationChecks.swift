import Foundation
import Darwin

// This executable does not include the app or launch any real system command.
enum BrowserBridgeConfiguration {
    static let origin = "chrome-extension://eghfefbgledejemklpphhpcfknmpbllf/"
}

@main
struct SetupIntegrationChecks {
    static var assertions = 0
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch is SetupIntegration.Failure { assertions += 1; return }
        throw Failure(message: "Unsafe operation was accepted")
    }
    static func put(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
    }
    static func fakeApp(_ url: URL, id: String = "local.outlier.ai-balance-board") throws {
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "AIBalanceBoard", "CFBundlePackageType": "APPL", "CFBundleVersion": "9"]
        try put(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), url.appendingPathComponent("Contents/Info.plist"))
        let executable = url.appendingPathComponent("Contents/MacOS/AIBalanceBoard")
        try put(Data("#!/bin/sh\nexit 0\n".utf8), executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for name in SetupIntegration.extensionFiles {
            let contents = name == "manifest.json" ? #"{"key":"offline-test-key"}"# : "offline fixture\n"
            try put(Data(contents.utf8), url.appendingPathComponent("Contents/Resources/browser-extension/\(name)"))
        }
    }
    static func heldLock(_ url: URL, operation: () throws -> Void) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure(message: "Cannot create test lock") }
        defer { flock(fd, LOCK_UN); close(fd) }
        try operation()
    }
    static func main() {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AIBalanceBoard-SetupTests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            var commands: [[String]] = []
            let context = SetupIntegration.Context(home: home) { path, arguments in
                commands.append([path] + arguments)
                return path == "/bin/launchctl" && arguments.first == "print" ? 1 : 0
            }
            let app = root.appendingPathComponent("AI '测试 app.app")
            try fakeApp(app)
            try SetupIntegration.registerBridge(app: app, context: context)
            for name in SetupIntegration.extensionFiles {
                try check(FileManager.default.fileExists(atPath: context.extensionFolder.appendingPathComponent(name).path), "Extension file missing")
            }
            let manifestData = try Data(contentsOf: context.hostManifest)
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
            try check(manifest["description"] as? String == "AI 额度看板：只接收 Cursor 额度查询结果", "Installer description mismatch")
            try check(manifest["path"] as? String == context.launcher.path, "Wrong native host path")
            try check(manifest["allowed_origins"] as? [String] == [BrowserBridgeConfiguration.origin], "Wrong extension origin")
            let launcher = try String(contentsOf: context.launcher, encoding: .utf8)
            try check(launcher.contains("'\"'\"'"), "Launcher quoting differs from shlex.quote")
            try check(launcher.hasSuffix(" --browser-bridge-host \"$@\"\n"), "Wrong launcher arguments")
            try check(commands.allSatisfy { $0.first == "/usr/bin/codesign" }, "Registration called a non-validation system command")

            let extra = context.extensionFolder.appendingPathComponent("keep-user-file.txt")
            try put(Data("keep".utf8), extra)
            let pairing = context.bridgeDirectory.appendingPathComponent("pairing.json")
            try put(Data("{}".utf8), pairing)
            try heldLock(context.bridgeDirectory.appendingPathComponent("bridge-host.lock")) {
                try rejected { try SetupIntegration.unregisterBridge(app: app, context: context) }
            }
            try check(FileManager.default.fileExists(atPath: context.hostManifest.path), "Active bridge was partially removed")
            try SetupIntegration.unregisterBridge(app: app, context: context)
            try check(!FileManager.default.fileExists(atPath: context.hostManifest.path), "Host manifest not removed")
            try check(!FileManager.default.fileExists(atPath: context.launcher.path), "Launcher not removed")
            try check(FileManager.default.fileExists(atPath: extra.path), "Unknown extension file was removed")
            try check(FileManager.default.fileExists(atPath: pairing.path), "Uninstall deleted pairing")

            for name in ["presence.json", "request.json", "result.json"] { try put(Data("{}".utf8), context.bridgeDirectory.appendingPathComponent(name)) }
            try heldLock(context.bridgeDirectory.appendingPathComponent("app-request.lock")) {
                try rejected { try SetupIntegration.resetBrowserPairing(context: context) }
            }
            try check(FileManager.default.fileExists(atPath: pairing.path), "Reset raced with active app query")
            try SetupIntegration.resetBrowserPairing(context: context)
            for name in ["pairing.json", "presence.json", "request.json", "result.json"] {
                try check(!FileManager.default.fileExists(atPath: context.bridgeDirectory.appendingPathComponent(name).path), "Pairing reset missed a known record")
            }

            try SetupIntegration.registerBridge(app: app, context: context)
            try put(Data("#!/bin/sh\nexit 0\n".utf8), context.launcher)
            try rejected { try SetupIntegration.unregisterBridge(app: app, context: context) }
            try check(FileManager.default.fileExists(atPath: context.hostManifest.path), "Wrong launcher was partially uninstalled")

            let foreign = root.appendingPathComponent("Other.app")
            try fakeApp(foreign, id: "example.other")
            let foreignPlist: [String: Any] = ["Label": SetupIntegration.label, "ProgramArguments": ["/usr/bin/open", "-g", foreign.path], "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
            let foreignData = try PropertyListSerialization.data(fromPropertyList: foreignPlist, format: .xml, options: 0)
            try put(foreignData, context.loginPlist)
            let before = commands.count
            try rejected { try SetupIntegration.setLoginEnabled(true, app: app, context: context) }
            let preservedLaunchItem = try Data(contentsOf: context.loginPlist)
            try check(preservedLaunchItem == foreignData, "Foreign launch item was overwritten")
            try check(commands.dropFirst(before).allSatisfy { $0.first != "/bin/launchctl" }, "Foreign launch item reached launchctl")
            try FileManager.default.removeItem(at: context.loginPlist)
            try SetupIntegration.setLoginEnabled(true, app: app, context: context)
            let installed = try PropertyListSerialization.propertyList(from: Data(contentsOf: context.loginPlist), format: nil) as! [String: Any]
            try check(installed["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", app.path], "Wrong login launch arguments")
            try check(installed["KeepAlive"] == nil, "Login item unexpectedly keeps app alive")
            try check(commands.contains { $0.first == "/bin/launchctl" && $0.dropFirst().first == "bootstrap" }, "Fake bootstrap was not requested")

            let unsafeHome = root.appendingPathComponent("unsafe-home")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: unsafeHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: unsafeHome.appendingPathComponent("Library"), withDestinationURL: outside)
            let unsafe = SetupIntegration.Context(home: unsafeHome, command: { _, _ in 0 })
            try rejected { try SetupIntegration.registerBridge(app: app, context: unsafe) }
            let outsideFiles = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            try check(outsideFiles.isEmpty, "Registration followed a parent symlink")
            print("Setup integration checks passed: \(assertions) assertions (temporary directories and fake system commands only).")
        } catch {
            FileHandle.standardError.write(Data(((error as? Failure)?.message ?? error.localizedDescription).utf8))
            exit(1)
        }
    }
}
