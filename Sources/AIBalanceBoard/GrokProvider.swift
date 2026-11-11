import AppKit
import BalanceCore

/// Chrome 扩展只回传服务器额度；登录会话始终留在 Chrome。
@MainActor
final class GrokProvider {
    private let bridge = BrowserBridgeClient()
    private var retryable = true
    // 沿用 Store 的退避判断；缺少浏览器或需登录时等待下一次正常刷新。
    var isConnected: Bool { retryable }
    func connectionGeneration() -> String? { bridge.connectedGeneration() }

    func fetch() async throws -> BalanceReading {
        do {
            let reading = try await bridge.fetch()
            retryable = true
            return reading
        } catch let error as BrowserBridgeFailure {
            retryable = error.shouldRetry
            throw error
        }
    }

    func connect() {
        // 只由用户点击触发；后台刷新不打开浏览器、不抢焦点。
        let alert = NSAlert()
        alert.messageText = "通过 Chrome 连接 Grok Bot 额度"
        alert.informativeText = "请在 Chrome 启用“AI 额度看板连接”扩展，并使用 Grok Bot 对应的 Cursor 账号登录。看板读取 Chrome 当前网页登录账号的额度；每轮仅向官方服务器查询一次，不调用模型。Chrome 关闭时保留上次读数，恢复后自动补查。"
        alert.addButton(withTitle: "在 Chrome 打开账户页")
        alert.addButton(withTitle: "返回看板")
        guard alert.runModal() == .alertFirstButtonReturn,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(string: "https://cursor.com/dashboard")!], withApplicationAt: chrome,
                                configuration: configuration, completionHandler: nil)
    }
}
