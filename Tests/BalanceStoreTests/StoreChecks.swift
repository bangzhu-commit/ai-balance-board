import AppKit
import Foundation
import BalanceCore

@MainActor final class FoxCodeProvider {
    var onReading: ((BalanceReading) -> Void)?
    func fetch() async throws -> BalanceReading { fatalError("fixture must never query") }
    func connect() {}
    func cancelPendingRead() {}
}
@MainActor final class GrokProvider {
    func connectionGeneration() -> String? { nil }
    func fetch() async throws -> BalanceReading { fatalError("fixture must never query") }
    func connect() {}
}
struct CodexProvider {
    func fetch() async throws -> BalanceReading { fatalError("fixture must never query") }
}
enum BrowserBridgeFailure: Error { case unavailable, loginRequired, busy, network, limited, changed, invalid, timeout }

@main enum StoreCheck {
    @MainActor static func main() throws {
        let name = "local.outlier.ai-balance-board.store-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("readings.json")
        let fresh = BalanceStore(defaults: defaults, cacheURL: cache)
        precondition(fresh.visibleCards.isEmpty && !fresh.setupCompleted)
        fresh.setEnabled(true, for: .codex)
        precondition(fresh.visibleCards.map(\.id) == [.codex])
        fresh.completeSetup()
        let reload = BalanceStore(defaults: defaults, cacheURL: cache)
        precondition(reload.setupCompleted && reload.enabledServices == [.codex])
        reload.setEnabled(false, for: .codex)
        precondition(reload.visibleCards.isEmpty)
        defaults.removePersistentDomain(forName: name)
        let reading = BalanceReading(service: .codex, metrics: [BalanceMetric(id: "week", label: "剩余", value: "75%")], source: "fixture")
        try JSONEncoder().encode(["codex": reading]).write(to: cache)
        let legacy = BalanceStore(defaults: defaults, cacheURL: cache)
        precondition(legacy.enabledServices == Set(ServiceID.allCases) && legacy.setupCompleted)
        precondition(legacy.card(for: .codex)?.reading == reading)
        legacy.clearReading(.codex)
        precondition(legacy.card(for: .codex)?.reading == nil)
        let persisted = try JSONDecoder().decode([String: BalanceReading].self, from: Data(contentsOf: cache))
        precondition(persisted["codex"] == nil)
        print("Store integration: 8 checks passed; fake providers made no requests")
    }
}
