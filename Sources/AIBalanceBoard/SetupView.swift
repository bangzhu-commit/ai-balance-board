import AppKit
import SwiftUI
import BalanceCore

@MainActor
private final class SetupNavigation: ObservableObject {
    @Published var step: Int
    init(step: Int) { self.step = step }
}

struct SetupView: View {
    @ObservedObject var store: BalanceStore
    @StateObject private var support = SetupSupportModel()
    @StateObject private var navigation: SetupNavigation
    let onFinish: () -> Void

    init(store: BalanceStore, initialStep: Int? = nil, onFinish: @escaping () -> Void) {
        self.store = store; self.onFinish = onFinish
        _navigation = StateObject(wrappedValue: SetupNavigation(step: initialStep ?? (store.setupCompleted ? 1 : 0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.setupCompleted ? "服务与设置" : "开始使用 AI 额度看板")
                    .font(.title2.bold())
                Text("选择你使用的服务，连接后查看第一笔真实额度。监控不调用 AI 模型。")
                    .foregroundStyle(.secondary)
            }
            Picker("设置步骤", selection: $navigation.step) {
                Text("1 选择服务").tag(0)
                Text("2 检查与连接").tag(1)
                Text("3 运行方式").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if navigation.step == 0 { serviceSelection }
                    else if navigation.step == 1 { connections }
                    else { preferences }
                    if !support.message.isEmpty {
                        Text(support.message).font(.callout).foregroundStyle(.secondary)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button("稍后设置") { store.completeSetup(); onFinish() }
                Spacer()
                if navigation.step > 0 { Button("上一步") { navigation.step -= 1 } }
                if navigation.step < 2 {
                    Button("下一步") { navigation.step += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button("完成并查看看板") { store.completeSetup(); onFinish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasReadyService)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 600, idealHeight: 690)
        .task {
            while !Task.isCancelled {
                // Hidden settings must not keep launching local diagnostic processes.
                if NSApp.windows.contains(where: { $0.identifier?.rawValue == "AIBalanceBoard.setup" && $0.isVisible }) {
                    await support.inspect()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var hasReadyService: Bool {
        store.visibleCards.contains { $0.connectionState == .ready && !$0.isStale }
    }

    private var serviceSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("只查询已开启的服务；以后可以随时增减。").foregroundStyle(.secondary)
            ForEach(ServiceID.allCases, id: \.self) { id in
                GroupBox {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title(id)).font(.headline)
                            Text(explanation(id)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Toggle(title(id), isOn: Binding(get: { store.enabledServices.contains(id) }, set: { store.setEnabled($0, for: id) }))
                            .labelsHidden().toggleStyle(.switch).accessibilityLabel(title(id))
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("以上为内置连接。其他网站可在下方导入经过适配的读取配置；需要逐站测试，不能保证任意平台都可自动查询。")
                .font(.footnote).foregroundStyle(.secondary)
            CustomSitesView(store: store)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.enabledServices.isEmpty && store.customSites.isEmpty {
                Text("还没有选择服务。回到第 1 步开启一项，或选择“稍后设置”。")
            }
            ForEach(store.visibleCards.filter { ServiceID.allCases.contains($0.id) }) { card in
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(card.title).font(.headline)
                            Spacer()
                            if card.isRefreshing { ProgressView().controlSize(.small) }
                            Text(stateLabel(card)).font(.caption).foregroundStyle(card.connectionState == .ready ? .green : .secondary)
                        }
                        if card.id == .foxcode { foxConnection }
                        else if card.id == .codex { codexConnection }
                        else { grokConnection }
                        Divider()
                        Text(card.status).font(.callout).textSelection(.enabled)
                        if let reading = card.reading {
                            HStack {
                                Text(reading.metrics.map { "\($0.label) \($0.value)" }.joined(separator: " · ")).font(.callout.bold())
                                Spacer()
                                Text(reading.fetchedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("检查最新额度") { store.refresh(card.id) }.disabled(card.isRefreshing)
                            Button("清除上次读数") { store.clearReading(card.id) }.disabled(card.isRefreshing || card.reading == nil)
                        }
                    }.padding(8)
                }
            }
            CustomSitesView(store: store)
        }
    }

    private var foxConnection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在看板的独立登录窗口中登录内置适配的中转站。登录成功并读取到额度后，点击“返回看板”。")
                .font(.callout).foregroundStyle(.secondary)
            Button("打开中转站登录") { store.connect(.foxcode) }
        }
    }

    private var codexConnection: some View {
        VStack(alignment: .leading, spacing: 8) {
            checkRow("Codex 程序", value: support.codexPath == nil ? "未找到或自选路径无效" : "已找到", ready: support.codexPath != nil)
            if let path = support.codexPath { Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
            Text("使用本机 Codex CLI 的 ChatGPT 登录账户，可能与桌面应用不同。首次安装或登录请按官方说明完成，再检查额度。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择 Codex 程序…") { support.chooseCodex { store.clearReading(.codex); store.refresh(.codex) } }
                Button("恢复自动检测") { support.automaticCodex { store.clearReading(.codex); store.refresh(.codex) } }
                Link("官方安装与登录说明", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
            }
        }
    }

    private var grokConnection: some View {
        VStack(alignment: .leading, spacing: 8) {
            checkRow("Google Chrome", value: support.chromeInstalled ? "已安装" : "未安装", ready: support.chromeInstalled)
            checkRow("本机连接组件", value: support.bridgeRegistered ? "已注册" : "待安装", ready: support.bridgeRegistered)
            checkRow("Chrome 扩展", value: support.bridgeConnected ? "已连接" : "等待连接（可能未加载、已停用或 Chrome 已关闭）", ready: support.bridgeConnected)
            Text("1. 点击“安装本机组件”。\n2. 在 Chrome 打开 chrome://extensions/，开启“开发者模式”，点击“加载已解压的扩展程序”，选择下方文件夹。\n3. 登录对应 Cursor 账号，再点击“检查最新额度”。")
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button(support.bridgeRegistered ? "重新注册组件" : "安装本机组件") { support.installBridge() }.disabled(support.busy)
                Button("显示连接器文件夹") { support.revealExtension() }.disabled(!support.bridgeRegistered)
                Button("打开 Cursor 登录") { support.openCursor() }
            }
            Text("~/Library/Application Support/AI Balance Board/Chrome Extension").font(.caption.monospaced()).textSelection(.enabled)
            Text("只需加载一次；Chrome 可在后台运行。无法读取时不代表额度为零。此预览版扩展尚未上架商店。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("更换 Chrome 配置文件 / 重装扩展") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("先停用看板扩展，再重置绑定，最后在所需配置文件重新启用。当前每项服务只支持一个账号；换账号时请清除旧读数后重新查询。")
                    Button("重置 Chrome 绑定…") { support.resetPairing { store.clearReading(.grok) } }.disabled(support.busy)
                }.font(.callout).padding(.top, 6)
            }
            DisclosureGroup("移除连接组件") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("先在 Chrome 停用扩展，再移除本机组件；最后在 Chrome 删除该扩展。不会退出网页账号或删除其他应用的数据。")
                    Button("移除本机连接组件…") {
                        support.removeBridge { store.setEnabled(false, for: .grok); store.clearReading(.grok) }
                    }.disabled(support.busy)
                }.font(.callout).padding(.top, 6)
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("后台运行") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录 Mac 后自动启动", isOn: Binding(get: { support.loginEnabled }, set: { support.setLogin($0) }))
                        .disabled(support.busy)
                    Text("每约 5 分钟查一次。唤醒、联网恢复后合并补查，不追赶关机期间的历史次数。")
                    Text("按住顶部图标或标题拖动；× 只收起小窗。完全停止监控请从菜单栏退出。")
                    Text("Grok Bot 需要 Chrome 运行且已登录。不同服务的额度单位与周期分别显示，不相加。")
                }.font(.callout).padding(8)
            }
            GroupBox("首次连接结果") {
                VStack(alignment: .leading, spacing: 8) {
                    if store.visibleCards.isEmpty { Text("尚未选择服务，可稍后设置。") }
                    ForEach(store.visibleCards) { card in
                        checkRow(card.title, value: stateLabel(card), ready: card.connectionState == .ready && !card.isStale)
                    }
                    Text(hasReadyService ? "已有服务取得有效读数。其他服务可以稍后连接。" : "取得至少一项有效额度后可完成；现在也可以选择“稍后设置”。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button("重新检测环境") { Task { await support.inspect() } }
                Button("导出脱敏诊断…") { support.exportDiagnostics(store: store) }
            }
            Text("诊断不包含账号、余额、Cookie、token 或本机路径。不会自动上传。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkRow(_ name: String, value: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ready ? Color.green : Color.secondary)
            Text(name).frame(width: 112, alignment: .leading)
            Text(value).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.font(.callout)
    }

    private func title(_ id: ServiceID) -> String {
        switch id {
        case .foxcode: return "中转站"
        case .codex: return "Codex"
        case .grok: return "Grok Bot"
        default: return store.card(for: id)?.title ?? "自定义站点"
        }
    }
    private func explanation(_ id: ServiceID) -> String {
        switch id {
        case .foxcode: return "连接当前内置适配的服务，分别显示按量和月卡额度。"
        case .codex: return "需要本机 Codex 程序和 ChatGPT 登录。"
        case .grok: return "通过 Chrome 中的 Cursor 登录查询服务器额度，需要本地扩展。"
        default: return "通过已验证的配置读取站点额度。"
        }
    }
    private func stateLabel(_ card: ServiceCard) -> String {
        if card.isRefreshing { return "正在查询" }
        switch card.connectionState {
        case .notConfigured: return "待连接"
        case .ready: return card.isStale ? "上次数据" : "已取得额度"
        case .authenticationRequired: return "需要登录"
        case .dependencyMissing: return "缺少程序"
        case .networkUnavailable: return "等待联网"
        case .rateLimited: return "稍后重试"
        case .invalidResponse: return "接口不兼容"
        case .connectionUnavailable: return "连接未就绪"
        case .temporaryFailure: return "临时读取失败"
        }
    }
}

@MainActor
final class SetupWindowController: NSWindowController {
    init(store: BalanceStore, onFinish: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "服务与设置 · AI 额度看板"
        window.identifier = NSUserInterfaceItemIdentifier("AIBalanceBoard.setup")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 600)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SetupView(store: store, onFinish: { [weak self] in self?.window?.orderOut(nil); onFinish() }))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(activate: Bool = true) {
        window?.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate(ignoringOtherApps: true) }
    }
}
