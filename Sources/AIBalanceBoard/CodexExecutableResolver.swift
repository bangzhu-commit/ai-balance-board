import Foundation

struct CodexExecutableCandidate: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case custom, processPATH, homebrew, npm, desktopApp
        var label: String {
            switch self {
            case .custom: return "用户指定"
            case .processPATH: return "进程 PATH"
            case .homebrew: return "Homebrew 常见位置"
            case .npm: return "npm 常见位置"
            case .desktopApp: return "Codex / ChatGPT 应用内置"
            }
        }
    }
    enum Validation: String, Codable, Sendable {
        case executable, missing, notRegularFile, notExecutable, invalidPath
        var message: String {
            switch self {
            case .executable: return "可执行文件；兼容性将在查询时验证"
            case .missing: return "未找到文件或无法访问"
            case .notRegularFile: return "不是普通可执行文件"
            case .notExecutable: return "文件没有执行权限"
            case .invalidPath: return "请选择绝对文件路径或以 ~/ 开头的路径"
            }
        }
    }
    let path: String
    let source: Source
    let validation: Validation
    var explanation: String { "\(source.label)：\(validation.message)" }
}

struct CodexExecutableDiagnosis: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case found, notFound, invalidCustomPath }
    let status: Status
    let selectedPath: String?
    let candidates: [CodexExecutableCandidate]
    let message: String
    var executableURL: URL? { selectedPath.map { URL(fileURLWithPath: $0) } }
}

/// Discovers executable files only. It never runs a shell, reads account files,
/// searches login credentials, installs software, or launches authentication.
enum CodexExecutableResolver {
    static let preferenceKey = "AIBalanceBoard.codexExecutablePath"

    struct Location: Sendable {
        let path: String
        let source: CodexExecutableCandidate.Source
    }

    static func resolve(customPath: String? = nil) -> URL? {
        diagnose(customPath: customPath).executableURL
    }

    static func diagnose(customPath: String? = nil) -> CodexExecutableDiagnosis {
        diagnose(
            configuredPath: customPath ?? UserDefaults.standard.string(forKey: preferenceKey),
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Settings UI should use this variant, keeping filesystem work off its actor.
    static func diagnoseAsync(customPath: String? = nil) async -> CodexExecutableDiagnosis {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: diagnose(customPath: customPath))
            }
        }
    }

    // The explicit context makes discovery testable without touching the user's
    // defaults, actual installations, home directory, or login state.
    static func diagnose(
        configuredPath: String?,
        environment: [String: String],
        homeDirectory: URL,
        standardCandidates: [Location]? = nil
    ) -> CodexExecutableDiagnosis {
        if let configuredPath {
            let candidate = inspect(Location(path: configuredPath, source: .custom), homeDirectory: homeDirectory)
            if candidate.validation == .executable {
                return result(selected: candidate, candidates: [candidate])
            }
            return CodexExecutableDiagnosis(
                status: .invalidCustomPath, selectedPath: nil, candidates: [candidate],
                message: "指定的 Codex 文件不可用，请重新选择或恢复自动查找；不会改用其他安装。"
            )
        }

        let pathCandidates = absolutePATHDirectories(environment["PATH"] ?? "").map {
            Location(path: URL(fileURLWithPath: $0).appendingPathComponent("codex").path, source: .processPATH)
        }
        let locations = pathCandidates + (standardCandidates ?? commonLocations(homeDirectory: homeDirectory))
        var seen = Set<String>()
        var candidates: [CodexExecutableCandidate] = []
        for location in locations {
            let candidate = inspect(location, homeDirectory: homeDirectory)
            guard seen.insert(candidate.path).inserted else { continue }
            candidates.append(candidate)
        }
        if let selected = candidates.first(where: { $0.validation == .executable }) {
            return result(selected: selected, candidates: candidates)
        }
        return CodexExecutableDiagnosis(
            status: .notFound, selectedPath: nil, candidates: candidates,
            message: "未找到可执行的 Codex CLI。请安装 Codex，或在设置中选择已有的 codex 可执行文件。"
        )
    }

    static func launchEnvironment(for executableURL: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [executableURL.deletingLastPathComponent().path]
            + absolutePATHDirectories(inherited["PATH"] ?? "")
            + [home.appendingPathComponent(".npm-global/bin").path,
               home.appendingPathComponent(".local/bin").path,
               home.appendingPathComponent(".volta/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    private static func result(selected: CodexExecutableCandidate, candidates: [CodexExecutableCandidate]) -> CodexExecutableDiagnosis {
        CodexExecutableDiagnosis(
            status: .found, selectedPath: selected.path, candidates: candidates,
            message: "已找到 Codex 可执行文件；查询时会验证兼容性与登录状态。"
        )
    }

    private static func absolutePATHDirectories(_ path: String) -> [String] {
        // Empty/relative PATH entries would resolve against an unrelated working
        // directory. Ignore them instead of executing a nearby lookalike binary.
        path.split(separator: ":", omittingEmptySubsequences: true).prefix(64).compactMap { item in
            let value = String(item)
            guard value.hasPrefix("/"), value.utf8.count <= 4096,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
    }

    private static func commonLocations(homeDirectory home: URL) -> [Location] {
        let npm = [".npm-global/bin/codex", ".local/bin/codex", ".local/share/npm/bin/codex", ".volta/bin/codex"]
            .map { Location(path: home.appendingPathComponent($0).path, source: .npm) }
        let homebrew = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .map { Location(path: $0, source: .homebrew) }
        let appRoots = ["/Applications", home.appendingPathComponent("Applications").path]
        let desktop = appRoots.flatMap { directory in
            ["Codex.app", "ChatGPT.app"].map {
                Location(path: URL(fileURLWithPath: directory).appendingPathComponent("\($0)/Contents/Resources/codex").path, source: .desktopApp)
            }
        }
        return npm + homebrew + desktop
    }

    private static func inspect(_ location: Location, homeDirectory: URL) -> CodexExecutableCandidate {
        let raw = location.path
        let expanded: String
        if raw.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
        } else { expanded = raw }
        guard expanded.hasPrefix("/"), expanded.utf8.count <= 4096,
              expanded.rangeOfCharacter(from: .controlCharacters) == nil else {
            return CodexExecutableCandidate(path: raw, source: location.source, validation: .invalidPath)
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let manager = FileManager.default
        let validation: CodexExecutableCandidate.Validation
        if let attributes = try? manager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) {
            if attributes[.type] as? FileAttributeType != .typeRegular { validation = .notRegularFile }
            else if !manager.isExecutableFile(atPath: url.path) { validation = .notExecutable }
            else { validation = .executable }
        } else { validation = .missing }
        return CodexExecutableCandidate(path: url.path, source: location.source, validation: validation)
    }
}
