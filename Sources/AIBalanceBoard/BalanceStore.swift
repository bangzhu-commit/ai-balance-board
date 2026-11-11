import AppKit
import SwiftUI
import BalanceCore
import Network
import CryptoKit

@MainActor
final class BalanceStore: ObservableObject {
    @Published var cards: [ServiceCard] = [
        ServiceCard(id: .foxcode, title: "中转站", subtitle: "内置适配", status: "登录后自动读取"),
        ServiceCard(id: .codex, title: "Codex", subtitle: "ChatGPT 套餐", status: "连接后读取本机账户"),
        ServiceCard(id: .grok, title: "Grok Bot", subtitle: "Chrome 当前 Cursor 账号", status: "等待 Chrome 额度连接")
    ]
    @Published var enabledServices: Set<ServiceID>
    @Published var setupCompleted: Bool
    @Published var isRefreshing = false
    @Published private(set) var customSites: [CustomSiteRecord] = []
    @Published var customSiteMessage: String?
    @Published private(set) var customTestReadings: [UUID: BalanceReading] = [:]
    @Published private(set) var customTestErrors: [UUID: String] = [:]
    @Published private(set) var customTesting: Set<UUID> = []
    var visibleCards: [ServiceCard] { cards.filter { enabledServices.contains($0.id) } }
    private let fox = FoxCodeProvider()
    private let grok = GrokProvider()
    private let cacheURL: URL
    private let defaults: UserDefaults
    private var preferences: BoardPreferences
    private var timer: Timer?
    private var browserConnectionTimer: Timer?
    private var browserGeneration: String?
    private var refreshTasks: [ServiceID: Task<Void, Never>] = [:]
    private var coordinator = ServiceRefreshCoordinator()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "local.outlier.ai-balance-board.network")
    private var wakeObserver: NSObjectProtocol?
    private var hasStarted = false
    private let customRepository: CustomSiteRepository
    private var customProviders: [UUID: CustomSiteProvider] = [:]
    private var customTestFingerprints: [UUID: String] = [:]
    private var customStorageFailed = false
    private let environmentMonitoring: Bool
    private let monotonicClock: () -> TimeInterval
    private static let confirmationsKey = "AIBalanceBoard.customSiteConfirmations"
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, customSitesURL: URL? = nil,
         environmentMonitoring: Bool = true,
         monotonicClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.environmentMonitoring = environmentMonitoring
        self.monotonicClock = monotonicClock
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Board/readings.json")
        customRepository = CustomSiteRepository(url: customSitesURL ?? self.cacheURL.deletingLastPathComponent().appendingPathComponent("custom-sites.json"))
        let cached = (try? Data(contentsOf: self.cacheURL))
            .flatMap { try? JSONDecoder().decode([String: BalanceReading].self, from: $0) } ?? [:]
        preferences = BoardPreferences(defaults: defaults, hasLegacyReadings: !cached.isEmpty)
        enabledServices = preferences.enabledServices
        setupCompleted = preferences.setupCompleted
        do { customSites = try customRepository.load() }
        catch {
            customStorageFailed = true
            customSiteMessage = "自定义站点配置无法读取，已暂停这些站点。请先备份并修复本机配置文件，再重新打开看板。"
        }
        for record in customSites {
            cards.append(customCard(record))
        }
        enabledServices = enabledServices.filter { id in
            guard let uuid = id.customUUID else { return true }
            return isCustomSiteConfirmed(id: uuid)
        }
        for index in cards.indices {
            guard let reading = cached[cards[index].id.rawValue], reading.service == cards[index].id else { continue }
            if reading.service == .foxcode && reading.source != "FoxCode 仪表板接口" { continue }
            if reading.service == .grok && reading.source != "Grok Bot 服务器接口（Chrome）" { continue }
            if let uuid = reading.service.customUUID {
                guard isCustomSiteConfirmed(id: uuid),
                      reading.source == "自定义站点（JSON）" || reading.source == "自定义站点（网页）" else { continue }
            }
            cards[index].reading = reading
            cards[index].status = "上次数据，待刷新"
            cards[index].hasError = true
            cards[index].needsConnection = false
            cards[index].connectionState = .temporaryFailure
        }
        for id in enabledServices { coordinator.setEnabled(true, for: id, at: now) }
        // Login is only a signal. Every accepted reading comes through a ticketed
        // fetch, so a late login callback cannot restore a disabled/cleared reading.
        fox.onReading = { [weak self] _ in
            guard let self, self.enabledServices.contains(.foxcode), !self.coordinator.isRunning(.foxcode) else { return }
            self.request(.connectionAvailable, for: .foxcode)
        }
    }

    func card(for id: ServiceID) -> ServiceCard? { cards.first { $0.id == id } }

    func setEnabled(_ enabled: Bool, for id: ServiceID) {
        if let uuid = id.customUUID {
            guard customSites.contains(where: { $0.id == uuid }) else { return }
            if enabled && !isCustomSiteConfirmed(id: uuid) {
                customSiteMessage = "请先登录、测试连接并核对额度，再启用监控。"
                return
            }
        }
        guard enabledServices.contains(id) != enabled else { return }
        if enabled { enabledServices.insert(id) } else { enabledServices.remove(id) }
        coordinator.setEnabled(enabled, for: id, at: now)
        if !enabled {
            refreshTasks[id]?.cancel()
            if id == .foxcode { fox.cancelPendingRead() }
            if let uuid = id.customUUID { customProviders[uuid]?.cancelPendingRead() }
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].isRefreshing = false }
        }
        if id == .grok { browserGeneration = nil }
        savePreferences()
        updateRefreshingState()
        onChange?()
        driveScheduler()
    }

    func completeSetup() {
        setupCompleted = true
        savePreferences()
        onChange?()
    }

    private func savePreferences() {
        preferences.enabledServices = enabledServices
        preferences.setupCompleted = setupCompleted
        preferences.save(to: defaults)
    }

    func clearReading(_ id: ServiceID) {
        coordinator.invalidate(id)
        refreshTasks[id]?.cancel()
        if id == .foxcode { fox.cancelPendingRead() }
        if let uuid = id.customUUID {
            customProviders[uuid]?.cancelPendingRead()
            customTesting.remove(uuid)
            customTestReadings[uuid] = nil
            customTestFingerprints[uuid] = nil
            if !enabledServices.contains(id) { coordinator.setEnabled(false, for: id, at: now) }
        }
        if let i = cards.firstIndex(where: { $0.id == id }) {
            cards[i].reading = nil
            cards[i].isRefreshing = false
            cards[i].status = "已清除上次读数，等待下次查询"
            cards[i].connectionState = .temporaryFailure
            cards[i].needsConnection = false
            cards[i].hasError = false
        }
        persist()
        updateRefreshingState()
        onChange?()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        browserGeneration = enabledServices.contains(.grok) ? grok.connectionGeneration() : nil
        coordinator.trigger(.startup, at: now)
        if !environmentMonitoring {
            coordinator.updateNetwork(.online, at: now)
            driveScheduler()
            return
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available) }
        }
        networkMonitor.start(queue: networkQueue)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.request(.wake) }
        }
        let browserTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.browserConnectionChanged() }
        }
        browserTimer.tolerance = 1
        RunLoop.main.add(browserTimer, forMode: .common)
        browserConnectionTimer = browserTimer
        driveScheduler()
    }

    func stop() {
        hasStarted = false
        timer?.invalidate(); timer = nil
        browserConnectionTimer?.invalidate(); browserConnectionTimer = nil
        networkMonitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        for task in refreshTasks.values { task.cancel() }
        fox.cancelPendingRead()
        for provider in customProviders.values { provider.close() }
    }

    private var now: TimeInterval { monotonicClock() }
    func refresh(_ id: ServiceID? = nil) { request(.manual, for: id) }

    private func browserConnectionChanged() {
        guard hasStarted, enabledServices.contains(.grok) else { return }
        let generation = grok.connectionGeneration()
        guard generation != browserGeneration else { return }
        browserGeneration = generation
        if generation != nil {
            request(.connectionAvailable, for: .grok)
        } else if let i = cards.firstIndex(where: { $0.id == .grok }) {
            cards[i].status = "Chrome 额度连接已离线，重新打开后自动补查"
            cards[i].hasError = true
            cards[i].connectionState = .connectionUnavailable
            cards[i].needsConnection = true
            onChange?()
        }
    }

    private func request(_ trigger: RefreshTrigger, for id: ServiceID? = nil) {
        guard hasStarted else { return }
        coordinator.trigger(trigger, for: id, at: now)
        driveScheduler()
    }

    private func networkChanged(_ available: Bool) {
        guard hasStarted else { return }
        coordinator.updateNetwork(available ? .online : .offline, at: now)
        if !available {
            for i in cards.indices where enabledServices.contains(cards[i].id) {
                cards[i].status = "网络不可用，恢复后自动补查"
                cards[i].hasError = true
                cards[i].connectionState = .networkUnavailable
                cards[i].needsConnection = false
            }
            onChange?()
        }
        driveScheduler()
    }

    private func driveScheduler() {
        timer?.invalidate(); timer = nil
        guard hasStarted else { return }
        for ticket in coordinator.beginDue(at: now) { performRefresh(ticket) }
        if let due = coordinator.nextDueAt {
            let next = Timer(timeInterval: max(0.1, due - now), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.driveScheduler() }
            }
            next.tolerance = min(1, max(0, (due - now) * 0.05))
            RunLoop.main.add(next, forMode: .common)
            timer = next
        }
    }

    private func performRefresh(_ ticket: ServiceRefreshTicket) {
        let id = ticket.service
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].isRefreshing = true }
        updateRefreshingState()
        onChange?()
        refreshTasks[id] = Task { [weak self] in
            guard let self else { return }
            var retrySoon = false
            var rateLimited = false
            do {
                let reading: BalanceReading
                switch id {
                case .foxcode: reading = try await self.fox.fetch()
                case .codex: reading = try await CodexProvider().fetch()
                case .grok: reading = try await self.grok.fetch()
                default:
                    guard let uuid = id.customUUID, let provider = self.customProvider(uuid) else {
                        throw BalanceError.invalidResponse("找不到该自定义站点配置")
                    }
                    reading = try await provider.fetch()
                }
                if self.hasStarted, !Task.isCancelled, self.coordinator.accepts(ticket) {
                    if let uuid = id.customUUID, self.customTesting.contains(uuid),
                       let record = self.customSites.first(where: { $0.id == uuid }) {
                        self.customTestReadings[uuid] = reading
                        self.customTestFingerprints[uuid] = self.fingerprint(record)
                        self.customTestErrors[uuid] = nil
                    } else { self.accept(reading) }
                }
            } catch {
                if self.hasStarted, !Task.isCancelled, self.coordinator.accepts(ticket) {
                    let failure = self.acceptFailure(error, for: id)
                    retrySoon = failure.retrySoon
                    rateLimited = failure.rateLimited
                    if let uuid = id.customUUID, self.customTesting.contains(uuid) {
                        self.customTestErrors[uuid] = error.localizedDescription
                    }
                }
            }
            let finishedTest = id.customUUID.flatMap { self.coordinator.accepts(ticket) && self.customTesting.contains($0) ? $0 : nil }
            self.coordinator.finish(ticket, at: self.now, retrySoon: retrySoon, rateLimited: rateLimited)
            if let uuid = finishedTest {
                self.customTesting.remove(uuid)
                self.coordinator.setEnabled(false, for: id, at: self.now)
            }
            self.refreshTasks[id] = nil
            if let i = self.cards.firstIndex(where: { $0.id == id }) { self.cards[i].isRefreshing = false }
            self.updateRefreshingState()
            self.onChange?()
            self.driveScheduler()
        }
    }

    private func acceptFailure(_ error: Error, for id: ServiceID) -> (retrySoon: Bool, rateLimited: Bool) {
        let state: ServiceConnectionState
        let retrySoon: Bool
        if let failure = error as? BalanceError {
            state = failure.connectionState
            retrySoon = failure.shouldRetrySoon
        } else if let failure = error as? BrowserBridgeFailure {
            switch failure {
            case .unavailable: state = .connectionUnavailable; retrySoon = false
            case .loginRequired: state = .authenticationRequired; retrySoon = false
            case .limited: state = .rateLimited; retrySoon = false
            case .invalid: state = .invalidResponse; retrySoon = false
            case .network, .timeout: state = .networkUnavailable; retrySoon = true
            case .changed: state = .temporaryFailure; retrySoon = true
            case .busy: state = .temporaryFailure; retrySoon = false
            }
        } else {
            state = .temporaryFailure
            retrySoon = false
        }
        if let i = cards.firstIndex(where: { $0.id == id }) {
            cards[i].status = (cards[i].reading == nil ? "" : "刷新失败，显示上次数据。") + error.localizedDescription
            if state == .rateLimited { cards[i].status += " 至少 5 分钟后再查，手动刷新也会等待。" }
            cards[i].hasError = true
            cards[i].connectionState = state
            cards[i].needsConnection = state.needsConnection
        }
        return (retrySoon, state == .rateLimited)
    }

    private func updateRefreshingState() {
        isRefreshing = cards.contains { enabledServices.contains($0.id) && $0.isRefreshing }
    }

    private func accept(_ reading: BalanceReading) {
        guard enabledServices.contains(reading.service), let i = cards.firstIndex(where: { $0.id == reading.service }) else { return }
        cards[i].reading = reading
        cards[i].status = reading.service == .grok ? "通过 Chrome 查询服务器" : "读取成功"
        cards[i].connectionState = .ready
        cards[i].needsConnection = false
        cards[i].hasError = false
        persist()
    }

    private func persist() {
        let readings = Dictionary(uniqueKeysWithValues: cards.compactMap { card in card.reading.map { (card.id.rawValue, $0) } })
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(readings)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* No account or raw service response is logged. */ }
    }

    func connect(_ id: ServiceID) {
        if let uuid = id.customUUID {
            guard let record = customSites.first(where: { $0.id == uuid }) else { return }
            // Opening login may switch accounts. A previous account's test or
            // cached reading must never authorize the new session.
            resetCustomSite(uuid)
            setCustomConfirmation(record, confirmed: false)
            if let index = cards.firstIndex(where: { $0.id == id }) { cards[index] = customCard(record) }
            persist()
            customSiteMessage = "登录可能更换账户，已暂停监控并清除旧测试；完成后请重新测试和核对。"
            onChange?()
            customProvider(uuid)?.connect()
            return
        }
        guard enabledServices.contains(id) else { return }
        switch id {
        case .foxcode: fox.connect()
        case .codex:
            showInfo("连接 Codex", "看板使用本机 Codex CLI 的登录账户。请先在终端运行 codex login，选择 ChatGPT 登录；完成后点击刷新。看板不会自动发起登录或更改账户。")
        case .grok: grok.connect()
        default: break
        }
    }

    private func customCard(_ record: CustomSiteRecord) -> ServiceCard {
        ServiceCard(id: record.serviceID, title: record.config.name, subtitle: "自定义连接", status: "登录并测试后启用")
    }

    private func fingerprint(_ record: CustomSiteRecord) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record.config) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isCustomSiteConfirmed(id: UUID) -> Bool {
        guard let record = customSites.first(where: { $0.id == id }) else { return false }
        let saved = defaults.dictionary(forKey: Self.confirmationsKey) as? [String: String] ?? [:]
        return saved[id.uuidString] == fingerprint(record)
    }

    private func setCustomConfirmation(_ record: CustomSiteRecord, confirmed: Bool) {
        var saved = defaults.dictionary(forKey: Self.confirmationsKey) as? [String: String] ?? [:]
        saved[record.id.uuidString] = confirmed ? fingerprint(record) : nil
        defaults.set(saved, forKey: Self.confirmationsKey)
    }

    private func saveCustomSites(_ records: [CustomSiteRecord]) throws {
        guard !customStorageFailed else {
            throw BalanceError.invalidResponse("原站点配置无法读取；为避免覆盖，请先备份并修复配置后重新打开看板。")
        }
        try customRepository.save(records)
    }

    @discardableResult
    func addCustomSite(config: CustomSiteConfig) throws -> UUID {
        try config.validate()
        let record = CustomSiteRecord(config: config)
        try saveCustomSites(customSites + [record])
        customSites.append(record)
        cards.append(customCard(record))
        customSiteMessage = "站点已添加。登录后测试连接，核对读数再启用监控。"
        onChange?()
        return record.id
    }

    func updateCustomSite(id: UUID, config: CustomSiteConfig) throws {
        try config.validate()
        guard let index = customSites.firstIndex(where: { $0.id == id }) else { return }
        let updated = CustomSiteRecord(id: id, config: config)
        var records = customSites; records[index] = updated
        try saveCustomSites(records)
        resetCustomSite(id)
        setCustomConfirmation(updated, confirmed: false)
        customSites = records
        if let index = cards.firstIndex(where: { $0.id == updated.serviceID }) { cards[index] = customCard(updated) }
        persist()
        customSiteMessage = "配置已更新，监控已暂停。请重新登录、测试并核对额度。"
        onChange?()
    }

    func removeCustomSite(id: UUID) throws {
        guard let record = customSites.first(where: { $0.id == id }) else { return }
        try saveCustomSites(customSites.filter { $0.id != id })
        resetCustomSite(id)
        setCustomConfirmation(record, confirmed: false)
        customSites.removeAll { $0.id == id }
        cards.removeAll { $0.id == record.serviceID }
        persist()
        customSiteMessage = "站点已移除，停止查询；该站点的本机 WebKit 登录会话保留。"
        onChange?()
    }

    private func resetCustomSite(_ uuid: UUID) {
        let id = ServiceID.custom(uuid)
        enabledServices.remove(id)
        coordinator.setEnabled(false, for: id, at: now)
        coordinator.invalidate(id)
        refreshTasks[id]?.cancel()
        customProviders.removeValue(forKey: uuid)?.close()
        customTesting.remove(uuid)
        customTestReadings[uuid] = nil
        customTestErrors[uuid] = nil
        customTestFingerprints[uuid] = nil
        savePreferences()
        updateRefreshingState()
    }

    private func customProvider(_ uuid: UUID) -> CustomSiteProvider? {
        if let existing = customProviders[uuid] { return existing }
        guard let record = customSites.first(where: { $0.id == uuid }) else { return nil }
        let provider = CustomSiteProvider(record: record)
        provider.onConnectionAvailable = { [weak self] in
            guard let self, self.enabledServices.contains(record.serviceID) else { return }
            self.request(.connectionAvailable, for: record.serviceID)
        }
        customProviders[uuid] = provider
        return provider
    }

    func testCustomSite(id uuid: UUID) {
        guard customSites.contains(where: { $0.id == uuid }), !customTesting.contains(uuid) else { return }
        guard hasStarted else { customSiteMessage = "看板尚未开始运行，请重新打开后测试。"; return }
        let id = ServiceID.custom(uuid)
        guard !coordinator.isRateLimited(id, at: now) else {
            customTestErrors[uuid] = "站点仍在限流冷却中，请在上次限流至少 5 分钟后重新测试。"
            return
        }
        // A test shares the same physical scheduler slot as monitoring, including
        // cancellation/generation guards. Never issue a second parallel request.
        if let record = customSites.first(where: { $0.id == uuid }) { setCustomConfirmation(record, confirmed: false) }
        enabledServices.remove(id)
        savePreferences()
        coordinator.setEnabled(false, for: id, at: now)
        refreshTasks[id]?.cancel()
        customProviders[uuid]?.cancelPendingRead()
        customTestReadings[uuid] = nil
        customTestErrors[uuid] = nil
        customTestFingerprints[uuid] = nil
        customTesting.insert(uuid)
        coordinator.setEnabled(true, for: id, at: now)
        coordinator.trigger(.manual, for: id, at: now)
        customSiteMessage = "正在测试；原监控已暂停。读数核对正确后再启用。"
        onChange?()
        driveScheduler()
    }

    func cancelCustomSiteTest(id uuid: UUID) {
        guard customTesting.remove(uuid) != nil else { return }
        let id = ServiceID.custom(uuid)
        coordinator.setEnabled(false, for: id, at: now)
        coordinator.invalidate(id)
        refreshTasks[id]?.cancel()
        customProviders[uuid]?.cancelPendingRead()
        customTestReadings[uuid] = nil
        customTestFingerprints[uuid] = nil
        customTestErrors[uuid] = "测试已取消，监控保持暂停。"
        if let index = cards.firstIndex(where: { $0.id == id }) { cards[index].isRefreshing = false }
        updateRefreshingState()
        onChange?()
        driveScheduler()
    }

    func confirmCustomSite(id uuid: UUID) throws {
        guard let record = customSites.first(where: { $0.id == uuid }),
              !customTesting.contains(uuid),
              let reading = customTestReadings[uuid],
              customTestFingerprints[uuid] == fingerprint(record),
              (0...300).contains(Date().timeIntervalSince(reading.fetchedAt)) else {
            throw BalanceError.invalidResponse("请先完成测试并核对读数；超过 5 分钟或配置已变化时需要重新测试。")
        }
        let readingAge = Date().timeIntervalSince(reading.fetchedAt)
        guard coordinator.enableWithFreshReading(for: record.serviceID, at: now - max(0, readingAge)) else {
            throw BalanceError.unavailable("上一次查询尚未结束，请稍后再确认。")
        }
        setCustomConfirmation(record, confirmed: true)
        enabledServices.insert(record.serviceID)
        savePreferences()
        accept(reading)
        customTestReadings[uuid] = nil
        customTestFingerprints[uuid] = nil
        customSiteMessage = "已启用后台监控，每约 5 分钟查询；日常不调用模型。"
        onChange?()
        driveScheduler()
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
}
