import BalanceCore
import Foundation

@main
struct CodexProviderChecks {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }

    static func writeExecutable(_ url: URL, _ text: String, permissions: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func fakeCLI(at url: URL, quota: String, initialization: String = #"{"id":1,"result":{"userAgent":"offline-test"}}"#,
                        trace: URL? = nil, args: URL? = nil) throws {
        let argumentLog = args.map { "printf '%s\\n' \"$@\" > \(quote($0.path))" } ?? ":"
        let requestLog = trace.map { "printf '%s\\n' \"$line\" >> \(quote($0.path))" } ?? ":"
        let script = """
        #!/bin/sh
        \(argumentLog)
        while IFS= read -r line; do
          \(requestLog)
          case "$line" in
            *'"method":"initialize"'*) printf '%s\\n' \(quote(initialization)) ;;
            *'rateLimits'*) printf '%s\\n' \(quote(quota)) ;;
          esac
        done
        """
        try writeExecutable(url, script)
    }

    static func expectError(_ kind: String, path: String, timeout: TimeInterval = 1) async throws {
        do {
            _ = try await CodexProvider(customExecutablePath: path, requestTimeout: timeout).fetch()
            throw Failure(message: "Expected \(kind), received success")
        } catch let error as BalanceError {
            let actual: String
            switch error {
            case .dependencyMissing: actual = "dependencyMissing"
            case .authenticationRequired: actual = "authenticationRequired"
            case .network: actual = "network"
            case .rateLimited: actual = "rateLimited"
            case .invalidResponse: actual = "invalidResponse"
            default: actual = "other"
            }
            try expect(actual == kind, "Expected \(kind), received \(actual)")
            try expect(!error.localizedDescription.contains("SUPER_SECRET_RAW_PAYLOAD"), "Server response leaked into error")
        }
    }

    static func main() async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AIBalanceBoard-CodexTests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try discoveryChecks(root: temporary)
            try await probeChecks(root: temporary)
            print("Codex executable/provider checks passed: \(assertions) assertions (offline fake CLIs only).")
        } catch {
            // Test fixtures contain no account details; still print only our fixed failure labels.
            let message = (error as? Failure)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    static func discoveryChecks(root: URL) throws {
        let home = root.appendingPathComponent("fake home")
        let bin = root.appendingPathComponent("test bin")
        let pathCLI = bin.appendingPathComponent("codex")
        let npmCLI = home.appendingPathComponent(".npm-global/bin/codex")
        let marker = root.appendingPathComponent("must-not-run")
        try writeExecutable(pathCLI, "#!/bin/sh\ntouch \(quote(marker.path))\n")
        try writeExecutable(npmCLI, "#!/bin/sh\nexit 0\n")

        let empty = CodexExecutableResolver.diagnose(configuredPath: nil, environment: ["PATH": ":./bin:../tools"],
                                                    homeDirectory: home, standardCandidates: [])
        try expect(empty.status == .notFound && empty.selectedPath == nil, "No-CLI diagnosis must be explicit")
        try expect(empty.candidates.isEmpty, "Relative PATH entries must not be probed")

        let found = CodexExecutableResolver.diagnose(configuredPath: nil, environment: ["PATH": ":./bin:\(bin.path):\(bin.path)"],
                                                    homeDirectory: home, standardCandidates: [])
        try expect(found.status == .found && found.selectedPath == pathCLI.path, "Absolute PATH executable discovery failed")
        try expect(found.candidates.count == 1, "PATH duplicates should be removed")
        try expect(!FileManager.default.fileExists(atPath: marker.path), "Discovery executed a candidate")

        for invalid in ["", "   ", "codex", "~/missing-codex", root.appendingPathComponent("missing").path] {
            let result = CodexExecutableResolver.diagnose(configuredPath: invalid, environment: ["PATH": bin.path],
                                                         homeDirectory: home, standardCandidates: [])
            try expect(result.status == .invalidCustomPath && result.selectedPath == nil, "Invalid custom path silently fell back")
            try expect(result.candidates.count == 1 && result.candidates[0].source == .custom, "Custom path must be authoritative")
        }

        let chosen = CodexExecutableResolver.diagnose(configuredPath: "~/.npm-global/bin/codex", environment: ["PATH": bin.path],
                                                     homeDirectory: home, standardCandidates: [])
        try expect(chosen.selectedPath == npmCLI.path, "Custom home expansion or precedence failed")
        let noExecute = root.appendingPathComponent("no-execute")
        try writeExecutable(noExecute, "#!/bin/sh\nexit 0\n", permissions: 0o644)
        let forbidden = CodexExecutableResolver.diagnose(configuredPath: noExecute.path, environment: ["PATH": bin.path],
                                                        homeDirectory: home, standardCandidates: [])
        try expect(forbidden.candidates[0].validation == .notExecutable, "Executable permission validation failed")
        let directory = CodexExecutableResolver.diagnose(configuredPath: bin.path, environment: [:], homeDirectory: home, standardCandidates: [])
        try expect(directory.candidates[0].validation == .notRegularFile, "Directories must not be selected as CLIs")

        let link = root.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pathCLI)
        let linked = CodexExecutableResolver.diagnose(configuredPath: link.path, environment: [:], homeDirectory: home, standardCandidates: [])
        try expect(linked.selectedPath == link.path, "Executable npm/Homebrew symlink should be accepted")
        let common = CodexExecutableResolver.diagnose(configuredPath: nil, environment: [:], homeDirectory: home)
        try expect(common.selectedPath == npmCLI.path, "Common npm location was not discovered")
        for suffix in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
                       "/Applications/ChatGPT.app/Contents/Resources/codex", home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path] {
            try expect(common.candidates.contains(where: { $0.path == suffix }), "Missing expected common CLI candidate")
        }
        let decoded = try JSONDecoder().decode(CodexExecutableDiagnosis.self, from: JSONEncoder().encode(found))
        try expect(decoded == found, "Diagnostic Codable round-trip failed")
        let env = CodexExecutableResolver.launchEnvironment(for: pathCLI, inherited: ["PATH": ":./bin:/usr/bin", "TEST_PRESERVE": "yes"])
        try expect(env["TEST_PRESERVE"] == "yes", "Launch environment must preserve existing values")
        try expect(env["PATH"]?.hasPrefix(bin.path + ":") == true, "Selected executable directory must be on launch PATH")
        try expect(!(env["PATH"] ?? "").contains("./bin"), "Launch PATH must not include relative directories")
        try expect(CodexExecutableResolver.preferenceKey == "AIBalanceBoard.codexExecutablePath", "Preference key drift")
    }

    static func probeChecks(root: URL) async throws {
        let cli = root.appendingPathComponent("fake-codex")
        let trace = root.appendingPathComponent("protocol.jsonl")
        let args = root.appendingPathComponent("args.txt")
        let valid = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":4102444800}}}}"#
        try fakeCLI(at: cli, quota: valid, trace: trace, args: args)
        let reading = try await CodexProvider(customExecutablePath: cli.path).fetch()
        try expect(reading.service == .codex && reading.metrics.first?.remainingFraction == 0.75, "Fake quota query failed")
        let lines = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        let methods = try lines.map { line -> String in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["method"] as? String ?? ""
        }
        try expect(methods == ["initialize", "initialized", "account/rateLimits/read"], "Probe invoked an unexpected protocol operation")
        let arguments = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        try expect(arguments == ["app-server", "--listen", "stdio://"], "Probe attempted a login or model command")

        try await expectError("dependencyMissing", path: root.appendingPathComponent("missing-custom-cli").path)
        try fakeCLI(at: cli, quota: valid, initialization: #"{"id":1,"error":{"code":-32601,"message":"SUPER_SECRET_RAW_PAYLOAD"}}"#)
        try await expectError("invalidResponse", path: cli.path)
        try fakeCLI(at: cli, quota: #"{"id":2,"error":{"code":-32000,"message":"Not authenticated: SUPER_SECRET_RAW_PAYLOAD"}}"#)
        try await expectError("authenticationRequired", path: cli.path)
        try fakeCLI(at: cli, quota: #"{"id":2,"error":{"code":-32000,"message":"SUPER_SECRET_RAW_PAYLOAD","data":{"statusCode":401}}}"#)
        try await expectError("authenticationRequired", path: cli.path)
        try fakeCLI(at: cli, quota: #"{"id":2,"error":{"code":-32000,"message":"network timeout: SUPER_SECRET_RAW_PAYLOAD"}}"#)
        try await expectError("network", path: cli.path)
        try fakeCLI(at: cli, quota: #"{"id":2,"error":{"code":-32000,"message":"SUPER_SECRET_RAW_PAYLOAD","data":{"status":429}}}"#)
        try await expectError("rateLimited", path: cli.path)
        try fakeCLI(at: cli, quota: #"{"id":2,"result":{"unexpected":"SUPER_SECRET_RAW_PAYLOAD"}}"#)
        try await expectError("invalidResponse", path: cli.path)
        try fakeCLI(at: cli, quota: "not-json SUPER_SECRET_RAW_PAYLOAD")
        try await expectError("invalidResponse", path: cli.path)
        try writeExecutable(cli, "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
        try await expectError("network", path: cli.path, timeout: 0.15)
        let task = Task { try await CodexProvider(customExecutablePath: cli.path).fetch() }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "Cancelled query returned success") }
        catch is CancellationError { try expect(true, "Cancellation is propagated") }
    }
}
