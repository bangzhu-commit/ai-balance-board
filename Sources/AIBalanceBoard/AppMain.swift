import AppKit
import SwiftUI
import BalanceCore

@main
enum AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--browser-bridge-host") {
            BrowserBridgeHost.run(expectedOrigin: BrowserBridgeConfiguration.origin)
        }
        if CommandLine.arguments.contains("--probe") {
            NSApplication.shared.setActivationPolicy(.accessory)
            Task {
                var results: [String: BalanceReading] = [:]
                do { results["codex"] = try await CodexProvider().fetch() }
                catch { print("Codex: \(error.localizedDescription)") }
                do { results["grok"] = try await GrokProvider().fetch() }
                catch { print("Grok Bot: \(error.localizedDescription)") }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(results), let string = String(data: data, encoding: .utf8) { print(string) }
                exit(results.isEmpty ? 1 : 0)
            }
            RunLoop.main.run()
            return
        }
        let instanceLock = SingleInstanceLock()
        guard instanceLock.acquire() else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((delegate, instanceLock)) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: BalanceStore!
    private var panel: PanelController!
    private var item: NSStatusItem!
    private var setup: SetupWindowController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = BalanceStore()
        panel = PanelController(content: dashboard())
        setup = SetupWindowController(store: store, onFinish: { [weak self] in self?.panel.show() })
        store.onChange = { [weak self] in
            guard let self else { return }
            self.panel.update(content: self.dashboard())
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AI 额度看板")
        let menu = NSMenu()
        for (title, action, key) in [("显示看板", #selector(showPanel), ""), ("隐藏看板", #selector(hidePanel), ""), ("服务与设置…", #selector(showSettings), ","), ("刷新额度", #selector(refresh), "r")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AI 额度看板", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let close = NSMenuItem(title: "关闭登录窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(close)
        let settings = NSMenuItem(title: "服务与设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        let mainQuit = NSMenuItem(title: "退出 AI 额度看板", action: #selector(quitApp), keyEquivalent: "q")
        mainQuit.target = self; appMenu.addItem(mainQuit)
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        panel.show()
        store.start()
        if !store.setupCompleted { setup.show() }
    }
    private func dashboard() -> AnyView {
        AnyView(DashboardView(cards: store.visibleCards, isRefreshing: store.isRefreshing,
                             onRefresh: { [weak self] in self?.store.refresh() },
                             onConnect: { [weak self] id in
                                 if id == .foxcode || id.customUUID != nil { self?.store.connect(id) } else { self?.setup.show() }
                             },
                             onHide: { [weak self] in self?.panel.hide() },
                             onSettings: { [weak self] in self?.setup.show() }))
    }
    @objc private func showPanel() { panel.show() }
    @objc private func hidePanel() { panel.hide() }
    @objc private func refresh() { store.refresh() }
    @objc private func showSettings() { setup.show() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store.setupCompleted { panel.show() } else { setup.show() }
        return false
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { store?.stop() }
}
