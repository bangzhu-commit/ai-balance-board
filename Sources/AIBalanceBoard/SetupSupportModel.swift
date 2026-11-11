import AppKit
import SwiftUI
import BalanceCore

@MainActor
final class SetupSupportModel: ObservableObject {
    @Published var chromeInstalled = false
    @Published var bridgeRegistered = false
    @Published var bridgeConnected = false
    @Published var codexPath: String?
    @Published var loginEnabled = false
    @Published var busy = false
    @Published var message = ""
    private var checking = false

    func inspect() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        chromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        bridgeConnected = BrowserBridgeClient().connectedGeneration() != nil
        let local = await Task.detached {
            (SetupIntegration.bridgeRegistered(), CodexExecutableResolver.resolve()?.path, SetupIntegration.loginEnabled())
        }.value
        bridgeRegistered = local.0
        codexPath = local.1
        loginEnabled = local.2
    }

    func installBridge() {
        let alert = NSAlert()
        alert.messageText = "安装 Chrome 额度连接组件？"
        alert.informativeText = "将把连接器保存到本机并注册浏览器通信。扩展仅在 Cursor 用量页查询额度，只把额度字段传给本机看板，不读取或导出 Cookie、密码，不调用模型。扩展需要由你在 Chrome 中手动加载。"
        alert.addButton(withTitle: "安装本机组件")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let app = Bundle.main.bundleURL
        perform(success: "本机组件已安装。下一步在 Chrome 加载连接器文件夹。") {
            try SetupIntegration.registerBridge(app: app)
        }
    }

    func setLogin(_ enabled: Bool) {
        let app = Bundle.main.bundleURL
        perform(success: enabled ? "已启用登录后自动启动。" : "已关闭登录后自动启动。") {
            try SetupIntegration.setLoginEnabled(enabled, app: app)
        }
    }

    func resetPairing(onSuccess: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "重置 Chrome 配置文件绑定？"
        alert.informativeText = "请先在 Chrome 停用本看板扩展。重置会删除本机绑定和旧额度通信记录，不会退出你的网页账号。之后在需要的 Chrome 配置文件中重新启用扩展。"
        alert.addButton(withTitle: "重置绑定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(success: "绑定已清除。请在所需 Chrome 配置文件中启用扩展。", onSuccess: onSuccess) {
            try SetupIntegration.resetBrowserPairing()
        }
    }

    func removeBridge(onSuccess: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "移除本机 Chrome 连接组件？"
        alert.informativeText = "请先在 Chrome 停用本看板扩展。仅移除本机通信注册和连接器文件；网页账号及配置文件绑定记录保留。完成后请在 Chrome 手动移除扩展。"
        alert.addButton(withTitle: "移除本机组件")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let app = Bundle.main.bundleURL
        perform(success: "本机组件已移除。请在 Chrome 手动移除扩展；网页账号与绑定记录保留。", onSuccess: onSuccess) {
            try SetupIntegration.unregisterBridge(app: app)
        }
    }

    func chooseCodex(onChange: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"
        panel.message = "仅选择你已安装并信任的 Codex 程序；看板会运行它的额度查询功能。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let diagnosis = await CodexExecutableResolver.diagnoseAsync(customPath: url.path)
            guard diagnosis.executableURL != nil else { message = diagnosis.message; return }
            UserDefaults.standard.set(url.path, forKey: CodexExecutableResolver.preferenceKey)
            onChange()
            await inspect()
        }
    }

    func automaticCodex(onChange: () -> Void) {
        UserDefaults.standard.removeObject(forKey: CodexExecutableResolver.preferenceKey)
        onChange()
        Task { await inspect() }
    }

    func openCursor() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            message = "尚未安装 Google Chrome。请先安装，再重新检测。"
            return
        }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.open([URL(string: "https://cursor.com/dashboard")!], withApplicationAt: chrome, configuration: config)
    }

    func revealExtension() {
        guard FileManager.default.fileExists(atPath: SetupIntegration.extensionFolder.path) else {
            message = "请先安装本机连接组件。"; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([SetupIntegration.extensionFolder])
    }

    func exportDiagnostics(store: BalanceStore) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let serviceLines = store.cards.map { card in
            "\(card.id.rawValue): enabled=\(store.enabledServices.contains(card.id)), state=\(card.connectionState.rawValue), hasReading=\(card.reading != nil)"
        }
        let report = (["AI Balance Board \(version)", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "Chrome installed: \(chromeInstalled)", "Native bridge registered: \(bridgeRegistered)", "Extension connected: \(bridgeConnected)", "Codex found: \(codexPath != nil)", "Login item enabled: \(loginEnabled)", "No account identifiers, balances, paths, cookies or tokens are included."] + serviceLines).joined(separator: "\n") + "\n"
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ai-balance-board-diagnostics.txt"
        panel.title = "导出脱敏诊断"
        panel.message = "只包含版本和连接状态，不包含账号、余额、路径、Cookie 或 token。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8); message = "诊断已导出，可先检查内容再分享。" }
        catch { message = "无法保存诊断，请选择其他位置。" }
    }

    private func perform(success: String, onSuccess: (() -> Void)? = nil, operation: @escaping @Sendable () throws -> Void) {
        guard !busy else { return }
        busy = true; message = "正在处理…"
        Task {
            let result = await Task.detached { Result { try operation() } }.value
            switch result {
            case .success: message = success; onSuccess?()
            case .failure(let error): message = (error as? SetupIntegration.Failure)?.message ?? "本机设置未完成，请检查安装权限后重试。"
            }
            await inspect()
            busy = false
        }
    }
}
