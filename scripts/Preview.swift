import AppKit
import SwiftUI
import BalanceCore

/// Offscreen rendering with fictional data. Does not start providers or show a window.
@main
enum PreviewMain {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 3 else {
            print("Usage: Preview --setup|--connections|--dashboard|--preferences output.png")
            return
        }
        let mode = CommandLine.arguments[1]
        let suite = "local.outlier.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BalanceStore(defaults: defaults, cacheURL: URL(fileURLWithPath: "/nonexistent/preview-readings.json"))
        let now = Date()
        let sample = BalanceReading(service: .codex, metrics: [BalanceMetric(id: "week", label: "每周剩余", value: "75%", remainingFraction: 0.75)], fetchedAt: now, source: "虚构演示数据")
        let content: AnyView
        let size: NSSize
        if mode == "--dashboard" {
            content = AnyView(DashboardView(cards: [ServiceCard(id: .codex, title: "Codex", subtitle: "演示账户", reading: sample, status: "演示数据", needsConnection: false, connectionState: .ready)], isRefreshing: false, onRefresh: {}, onConnect: { _ in }, onHide: {}))
            size = NSSize(width: 340, height: 360)
        } else {
            if mode == "--connections" {
                for id in ServiceID.allCases { store.setEnabled(true, for: id) }
            }
            if mode == "--preferences" {
                store.setEnabled(true, for: .codex)
                store.cards = [ServiceCard(id: .codex, title: "Codex", subtitle: "演示账户", reading: sample, status: "演示数据", needsConnection: false, connectionState: .ready)]
            }
            content = AnyView(SetupView(store: store, initialStep: mode == "--preferences" ? 2 : (mode == "--connections" ? 1 : 0), onFinish: {}))
            size = NSSize(width: 660, height: 690)
        }
        let view = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("无法渲染预览") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("无法保存预览") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Preview rendered: \(mode)")
    }
}
