import AppKit
import SwiftUI
import BalanceCore
import Network

@MainActor
final class BalanceStore: ObservableObject {
    @Published var cards: [ServiceCard] = [
        ServiceCard(id: .foxcode, title: "FoxCode", subtitle: "中转服务", status: "登录后自动读取"),
        ServiceCard(id: .codex, title: "Codex", subtitle: "ChatGPT 套餐", status: "连接后读取本机账户"),
        ServiceCard(id: .grok, title: "Grok Bot", subtitle: "Chrome 当前 Cursor 账号", status: "等待 Chrome 额度连接")
    ]
    @Published var enabledServices: Set<ServiceID>
    @Published var setupCompleted: Bool
    @Published var isRefreshing = false
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
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Board/readings.json")
        let cached = (try? Data(contentsOf: self.cacheURL))
            .flatMap { try? JSONDecoder().decode([String: BalanceReading].self, from: $0) } ?? [:]
        preferences = BoardPreferences(defaults: defaults, hasLegacyReadings: !cached.isEmpty)
        enabledServices = preferences.enabledServices
        setupCompleted = preferences.setupCompleted
        for index in cards.indices {
            guard let reading = cached[cards[index].id.rawValue], reading.service == cards[index].id else { continue }
            if reading.service == .foxcode && reading.source != "FoxCode 仪表板接口" { continue }
            if reading.service == .grok && reading.source != "Grok Bot 服务器接口（Chrome）" { continue }
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
        guard enabledServices.contains(id) != enabled else { return }
        if enabled { enabledServices.insert(id) } else { enabledServices.remove(id) }
        coordinator.setEnabled(enabled, for: id, at: now)
        if !enabled {
            refreshTasks[id]?.cancel()
            if id == .foxcode { fox.cancelPendingRead() }
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
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
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
            do {
                let reading: BalanceReading
                switch id {
                case .foxcode: reading = try await self.fox.fetch()
                case .codex: reading = try await CodexProvider().fetch()
                case .grok: reading = try await self.grok.fetch()
                }
                if self.hasStarted, !Task.isCancelled, self.coordinator.accepts(ticket) { self.accept(reading) }
            } catch {
                if self.hasStarted, !Task.isCancelled, self.coordinator.accepts(ticket) {
                    retrySoon = self.acceptFailure(error, for: id)
                }
            }
            self.coordinator.finish(ticket, at: self.now, retrySoon: retrySoon)
            self.refreshTasks[id] = nil
            if let i = self.cards.firstIndex(where: { $0.id == id }) { self.cards[i].isRefreshing = false }
            self.updateRefreshingState()
            self.onChange?()
            self.driveScheduler()
        }
    }

    private func acceptFailure(_ error: Error, for id: ServiceID) -> Bool {
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
            cards[i].hasError = true
            cards[i].connectionState = state
            cards[i].needsConnection = state.needsConnection
        }
        return retrySoon
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
        guard enabledServices.contains(id) else { return }
        switch id {
        case .foxcode: fox.connect()
        case .codex:
            showInfo("连接 Codex", "看板使用本机 Codex CLI 的登录账户。请先在终端运行 codex login，选择 ChatGPT 登录；完成后点击刷新。看板不会自动发起登录或更改账户。")
        case .grok: grok.connect()
        }
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
}
