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

@MainActor final class CustomSiteProvider {
    let record: CustomSiteRecord
    var onConnectionAvailable: (() -> Void)?
    static var calls = 0
    static var pending: [(CustomSiteRecord, CheckedContinuation<BalanceReading, Error>)] = []
    init(record: CustomSiteRecord) { self.record = record }
    func fetch() async throws -> BalanceReading {
        Self.calls += 1
        return try await withCheckedThrowingContinuation { Self.pending.append((record, $0)) }
    }
    func connect() {}
    // Deliberately ignore cancellation to prove stale replies cannot be accepted.
    func cancelPendingRead() {}
    func close() {}
    static func finish(_ value: Double = 50, error: Error? = nil) {
        let (record, continuation) = pending.removeFirst()
        if let error { continuation.resume(throwing: error); return }
        let reading = try! CustomSiteParser.parseJSON(data: Data("{\"balance\":\(value)}".utf8), config: record.config, id: record.id)
        continuation.resume(returning: reading)
    }
}

@main enum StoreCheck {
    @MainActor static func main() async throws {
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
        var checks = 8
        func check(_ value: @autoclosure () -> Bool) { precondition(value()); checks += 1 }
        func settle(_ condition: @escaping @MainActor () -> Bool) async {
            for _ in 0..<2000 {
                if condition() { return }
                await Task.yield()
            }
            preconditionFailure("async fixture failed to settle")
        }
        defaults.removePersistentDomain(forName: name)
        try FileManager.default.removeItem(at: cache)
        var clock: TimeInterval = 0
        let store = BalanceStore(defaults: defaults, cacheURL: cache, environmentMonitoring: false, monotonicClock: { clock })
        let config = CustomSiteConfig(name: "测试站点", origin: "https://relay.example.com", loginPath: "/login", pagePath: "/dashboard",
                                      mode: .json, requestPath: "/api/usage",
                                      metrics: [CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance, value: "/balance")])
        let uuid = try store.addCustomSite(config: config)
        let id = ServiceID.custom(uuid)
        check(store.customSites.count == 1 && store.visibleCards.isEmpty && CustomSiteProvider.calls == 0)
        store.setEnabled(true, for: id)
        check(!store.enabledServices.contains(id))
        let persistedStore = BalanceStore(defaults: defaults, cacheURL: cache)
        check(persistedStore.customSites.count == 1 && !persistedStore.isCustomSiteConfirmed(id: uuid))
        store.start()
        store.testCustomSite(id: uuid)
        clock = 3; store.refresh(id)
        await settle { CustomSiteProvider.pending.count == 1 }
        store.testCustomSite(id: uuid)
        store.refresh(id)
        check(CustomSiteProvider.calls == 1)
        CustomSiteProvider.finish(51)
        await settle { !store.customTesting.contains(uuid) }
        check(store.customTestReadings[uuid]?.metrics.first?.value == "51 USD")
        check(!store.isCustomSiteConfirmed(id: uuid) && store.visibleCards.isEmpty)
        try store.confirmCustomSite(id: uuid)
        check(store.isCustomSiteConfirmed(id: uuid) && store.enabledServices.contains(id))
        check(store.card(for: id)?.reading?.metrics.first?.value == "51 USD")
        check(CustomSiteProvider.calls == 1)
        let confirmedReload = BalanceStore(defaults: defaults, cacheURL: cache)
        check(confirmedReload.isCustomSiteConfirmed(id: uuid) && confirmedReload.enabledServices.contains(id))
        store.setEnabled(false, for: id)
        check(store.isCustomSiteConfirmed(id: uuid) && !store.enabledServices.contains(id))
        store.setEnabled(true, for: id)
        clock = 6; store.refresh(id)
        await settle { CustomSiteProvider.pending.count == 1 }
        check(CustomSiteProvider.calls == 2)
        store.testCustomSite(id: uuid)
        check(!store.isCustomSiteConfirmed(id: uuid) && !store.enabledServices.contains(id))
        check(CustomSiteProvider.calls == 2)
        clock = 9
        CustomSiteProvider.finish(100)
        await settle { CustomSiteProvider.calls == 3 }
        check(store.customTestReadings[uuid] == nil)
        var changed = config; changed.name = "更新后的站点"
        try store.updateCustomSite(id: uuid, config: changed)
        CustomSiteProvider.finish(55)
        await settle { !store.isRefreshing }
        for _ in 0..<10 { await Task.yield() }
        check(store.customTestReadings[uuid] == nil && store.card(for: id)?.reading == nil)
        check(!store.isCustomSiteConfirmed(id: uuid) && store.card(for: id)?.title == changed.name)
        store.testCustomSite(id: uuid)
        clock = 12; store.refresh(id)
        await settle { CustomSiteProvider.pending.count == 1 }
        store.cancelCustomSiteTest(id: uuid)
        CustomSiteProvider.finish()
        for _ in 0..<20 { await Task.yield() }
        check(store.customTestReadings[uuid] == nil && !store.customTesting.contains(uuid))
        store.testCustomSite(id: uuid)
        clock = 15; store.refresh(id)
        await settle { CustomSiteProvider.pending.count == 1 }
        try store.removeCustomSite(id: uuid)
        CustomSiteProvider.finish()
        for _ in 0..<20 { await Task.yield() }
        check(store.customSites.isEmpty && store.card(for: id) == nil && store.customTestReadings[uuid] == nil)
        let second = try store.addCustomSite(config: config)
        store.testCustomSite(id: second)
        clock = 18; store.refresh(.custom(second))
        await settle { CustomSiteProvider.pending.count == 1 }
        CustomSiteProvider.finish(60)
        await settle { !store.customTesting.contains(second) }
        check(store.customTestReadings[second] != nil)
        store.connect(.custom(second))
        check(store.customTestReadings[second] == nil && !store.isCustomSiteConfirmed(id: second))
        do { try store.confirmCustomSite(id: second); preconditionFailure("new login must invalidate old account test") }
        catch { checks += 1 }
        try store.removeCustomSite(id: second)
        store.stop()
        let repository = CustomSiteRepository(url: directory.appendingPathComponent("custom-sites.json"))
        let finalRecords = try repository.load(); check(finalRecords.isEmpty)
        try Data("invalid config".utf8).write(to: repository.url)
        let invalidStorage = BalanceStore(defaults: defaults, cacheURL: cache)
        check(invalidStorage.customSiteMessage != nil)
        do { _ = try invalidStorage.addCustomSite(config: config); preconditionFailure("must preserve corrupt configuration") }
        catch { checks += 1 }
        let preservedConfig = try String(contentsOf: repository.url); check(preservedConfig == "invalid config")
        print("Store integration: \(checks) checks passed; fake providers only, no accounts/network requests")
    }
}
