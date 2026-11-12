import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BalanceCore

struct CustomSitesView: View {
    @ObservedObject var store: BalanceStore
    var showsCatalog = false
    var focus: CustomSiteFocus?
    var onSaved: (UUID) -> Void = { _ in }
    @StateObject private var state = CustomSitesState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsCatalog {
                toolCatalog
                websiteSection
            }
            savedConnections
        }
        .sheet(item: $state.editor, onDismiss: {
            // Changing the setup step before the sheet closes would remove its presenter.
            if let id = state.editorDismissed() { onSaved(id) }
        }) { request in
            CustomSiteEditor(store: store, record: request.record, seedName: request.seedName, kind: request.kind,
                             onSaved: state.editorSaved)
        }
        .onChange(of: focus, initial: true) { _, request in
            if let request { state.expandedSiteID = request.siteID }
        }
    }

    private var toolCatalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 工具").font(.headline)
                Spacer()
                Button("添加网站 / 中转站…") { state.editor = CustomSiteEditorRequest(record: nil, kind: .website) }
                    .controlSize(.small).disabled(store.customSites.count >= 12)
            }
            Text("选工具，再选接入方式。标有“需配置”的入口，需要导入规则并验证后才能查询。")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(AIToolCatalog.presets) { preset in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(preset.name).font(.headline)
                                Spacer(minLength: 4)
                                Text(preset.builtinService == nil ? "需配置" : "有内置连接")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).help(preset.detail)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                            HStack {
                                if let service = preset.builtinService {
                                    Toggle("内置连接", isOn: Binding(get: { store.enabledServices.contains(service) }, set: { store.setEnabled($0, for: service) }))
                                        .toggleStyle(.switch).controlSize(.mini).font(.caption)
                                    Spacer(minLength: 0)
                                }
                                Button("自定义接入…") {
                                    state.editor = CustomSiteEditorRequest(record: nil, seedName: preset.id == "other" ? "" : preset.name)
                                }.controlSize(.small).disabled(store.customSites.count >= 12)
                            }
                        }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("内置连接可在第 2 步连接账号；自定义接入不会自动识别额度，也不会代为登录。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var websiteSection: some View {
        GroupBox {
            DisclosureGroup("网站 / 中转站") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("不同站点的页面和接口不同。添加站点后，将接入任务交给具有 Computer Use 能力的 Agent，针对你的网站生成读取规则。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("添加站点…") { state.editor = CustomSiteEditorRequest(record: nil, kind: .website) }
                        .disabled(store.customSites.count >= 12)
                    DisclosureGroup("已有内置中转站连接") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("启用原有连接", isOn: Binding(get: { store.enabledServices.contains(.foxcode) }, set: { store.setEnabled($0, for: .foxcode) }))
                                .toggleStyle(.switch)
                            Text("仅适用于原有内置适配，不适用于任意网站。其他站点请使用上方“添加站点”。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }
                }.padding(.top, 8)
            }.padding(8)
        }
    }

    private var savedConnections: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("自定义连接").font(.headline)
                    Spacer()
                    if !showsCatalog {
                        Button("添加自定义连接…") { state.editor = CustomSiteEditorRequest(record: nil) }
                            .disabled(store.customSites.count >= 12)
                    }
                }
                Text("导入配置 → 登录 → 测试并核对 → 开启监控。日常查询不调用模型。")
                    .font(.callout).foregroundStyle(.secondary)
                if store.customSites.isEmpty {
                    Text("尚未添加。支持同站点的只读 JSON 接口或固定网页元素；不是所有工具都提供可接入的额度来源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.customSites, id: \.id) { record in
                    Divider()
                    CustomSiteRow(store: store, record: record,
                                  expanded: Binding(get: { state.expandedSiteID == record.id },
                                                    set: { state.expandedSiteID = $0 ? record.id : nil }),
                                  onEdit: { state.editor = CustomSiteEditorRequest(record: record) })
                        .id(record.id)
                        .background {
                            if let focus, focus.siteID == record.id, state.expandedSiteID == record.id {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: CustomSiteFocusPreferenceKey.self,
                                                           value: geometry.size.height > 0 ? focus : nil)
                                }
                            }
                        }
                }
                if store.customSites.count >= 12 {
                    Text("最多保存 12 个自定义连接，请先移除不再使用的连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = store.customSiteMessage, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.id("custom-connections")
    }
}

@MainActor
private final class CustomSiteRowState: ObservableObject {
    @Published var valuesMatch = false
    @Published var message = ""
    @Published var confirmRemoval = false
}

struct CustomSiteRow: View {
    @ObservedObject var store: BalanceStore
    let record: CustomSiteRecord
    @Binding var expanded: Bool
    let onEdit: () -> Void
    @StateObject private var state = CustomSiteRowState()

    private var id: ServiceID { .custom(record.id) }
    private var isTesting: Bool { store.customTesting.contains(record.id) }
    private var isEnabled: Bool { store.enabledServices.contains(id) }
    private var isConfirmed: Bool { store.isCustomSiteConfirmed(id: record.id) }
    private var testReading: BalanceReading? { store.customTestReadings[record.id] }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.config.origin).font(.caption.monospaced()).textSelection(.enabled)
                Text("登录窗口使用该站点独立会话，不能直接复用 Chrome 登录。请先登录，再测试读取结果。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("打开登录窗口") { store.connect(id) }
                    Button(isTesting ? "正在测试…" : "测试连接") {
                        state.valuesMatch = false; state.message = ""; store.testCustomSite(id: record.id)
                    }.disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                        Button("取消") { store.cancelCustomSiteTest(id: record.id); state.valuesMatch = false }
                    }
                    Spacer(minLength: 0)
                }
                if let error = store.customTestErrors[record.id] {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let reading = testReading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("测试读数").font(.callout.bold())
                        ForEach(reading.metrics) { metric in
                            HStack(alignment: .firstTextBaseline) {
                                Text(metric.label).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(metric.value).bold().textSelection(.enabled)
                            }.font(.callout)
                        }
                        Text("读取于 \(reading.fetchedAt.formatted(date: .omitted, time: .standard)) · 请在 5 分钟内完成核对")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("我已对照网页，数值、单位和已用 / 剩余含义一致", isOn: $state.valuesMatch)
                            .font(.callout).disabled(isTesting)
                        Button("确认并开启自动查询") {
                            do { try store.confirmCustomSite(id: record.id); state.message = "已确认，后台将按约 5 分钟刷新。" }
                            catch { state.message = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).disabled(!state.valuesMatch || isTesting)
                    }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if isConfirmed {
                    Toggle("后台自动查询", isOn: Binding(get: { isEnabled }, set: { store.setEnabled($0, for: id) }))
                        .toggleStyle(.switch).font(.callout)
                } else {
                    Text("配置已保存，尚未开启自动查询。下一步：打开登录窗口 → 测试连接 → 核对并开启监控。更换配置后需要重新测试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let card = store.card(for: id), isConfirmed {
                    Text(card.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("重新导入配置…", action: onEdit)
                    Button("移除连接…", role: .destructive) { state.confirmRemoval = true }
                    Spacer()
                }
                if !state.message.isEmpty { Text(state.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(.top, 8)
        } label: {
            HStack {
                Text(record.config.name).font(.callout.bold()).lineLimit(1)
                Spacer()
                Text(isTesting ? "正在测试" : (isEnabled ? "监控中" : (isConfirmed ? "已暂停" : "待测试与核对")))
                    .font(.caption).foregroundStyle(isEnabled ? Color.green : .secondary)
            }
        }
        .onChange(of: testReading?.fetchedAt) { _, _ in state.valuesMatch = false }
        .onChange(of: record.config) { _, _ in state.valuesMatch = false; state.message = "" }
        .confirmationDialog("移除这个连接？", isPresented: $state.confirmRemoval, titleVisibility: .visible) {
            Button("移除连接", role: .destructive) {
                do { try store.removeCustomSite(id: record.id) }
                catch { state.message = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除看板中的连接配置与读数，并停止查询。不退出网页账号，也不修改网站账户。")
        }
    }
}

struct CustomSiteEditor: View {
    @ObservedObject var store: BalanceStore
    let record: CustomSiteRecord?
    let kind: CustomConnectionKind
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: CustomSiteEditorModel

    init(store: BalanceStore, record: CustomSiteRecord?, seedName: String = "", kind: CustomConnectionKind = .aiTool, model: CustomSiteEditorModel? = nil, onSaved: @escaping (UUID) -> Void) {
        self.store = store; self.record = record; self.kind = model?.kind ?? kind; self.onSaved = onSaved
        _state = StateObject(wrappedValue: model ?? CustomSiteEditorModel(record: record, seedName: seedName, kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record == nil ? (kind == .aiTool ? "自定义接入 AI 工具" : "添加网站 / 中转站") : "更新连接配置").font(.title2.bold())
            Text("粘贴网址 → 请 Agent 准备配置 → 导入并测试")
                .font(.callout).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        targetSection
                        importSection
                        if let config = state.reviewedConfig {
                            reviewSection(config).id("site-source-review")
                        }
                        if !state.message.isEmpty {
                            Text(state.message).font(.callout).foregroundStyle(state.reviewedConfig == nil ? Color.secondary : Color.green).textSelection(.enabled)
                        }
                        advancedSection
                    }.padding(.vertical, 4)
                }
                .onChange(of: state.reviewedConfig) { previous, current in
                    // Do not scroll an existing connection on initial presentation.
                    if previous == nil, current != nil {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("site-source-review", anchor: .top)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("取消") { state.deactivate(); dismiss() }
                Spacer()
                Button(record == nil ? "保存，继续登录与测试" : "保存并重新验证") { save() }
                    .buttonStyle(.borderedProminent).disabled(!state.canSave)
            }
        }.padding(24).frame(width: 670, height: 720)
        .onAppear { state.activate() }
        .onDisappear { state.deactivate() }
    }

    private var targetSection: some View {
        GroupBox("1. 输入网址，交给 Agent 接入") {
            VStack(alignment: .leading, spacing: 10) {
                if kind == .aiTool {
                    TextField(record == nil ? "工具名称，例如：Claude" : "显示名称", text: Binding(get: { state.targetName }, set: state.setTargetName))
                }
                TextField(kind == .aiTool ? "粘贴额度网页链接（不知道可先留空）" : "粘贴站点网址，首页、登录页或仪表盘链接均可", text: Binding(get: { state.targetURL }, set: state.setTargetURL))
                    .textContentType(.URL)
                    .accessibilityLabel("站点网址")
                if let target = state.normalizedTarget {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text("将接入 \(target.origin)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("仅使用域名；页面路径、查询参数和片段不会复制给 Agent。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = state.targetError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else {
                    Text(kind == .aiTool ? "先填工具名也可以，请 Agent 核实产品、账号、套餐和额度来源。" : "无需填写名称或接口。也可直接在下方导入已有配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("复制给 Agent 的接入任务") {
                        guard let task = state.agentTask else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task, forType: .string)
                        state.report("任务已复制。发给具备 Computer Use 能力的 Agent，完成后把它生成的 .json 文件拖到下方。")
                    }.disabled(!state.canPrepareTask)
                    Button(state.showGuide ? "收起任务" : "查看任务") { state.showGuide.toggle() }.disabled(!state.canPrepareTask)
                }
                if state.showGuide, let task = state.agentTask {
                    Text(task).font(.caption).textSelection(.enabled)
                        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("让 Agent 生成可重复读取额度的配置，不是一次余额或截图。登录由你完成；首次配置消耗 Agent 额度，日常查询不调用模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var importSection: some View {
        GroupBox("2. 放入 Agent 生成的配置文件") {
            VStack(spacing: 10) {
                Image(systemName: state.isImporting ? "hourglass" : (state.reviewedConfig == nil ? "doc.badge.arrow.up" : "checkmark.circle.fill"))
                    .font(.title2).foregroundStyle(state.reviewedConfig == nil ? Color.secondary : Color.green)
                Text(state.isImporting ? "正在检查配置…" : (state.reviewedConfig == nil ? "将 .json 文件拖到这里" : "配置已检查，请核对下方来源"))
                    .font(.headline)
                Text(state.reviewedConfig == nil ? "或选择本机文件；读取后会自动检查来源和格式。" : "如需更换，可重新选择或拖入配置文件。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(state.reviewedConfig == nil ? "选择配置文件…" : "重新选择配置…", action: importFile).disabled(state.isImporting)
                Text("仅接受一个 64 KB 以内的本地配置文件，不会自动联网或开启监控。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(18)
                .background(state.dropTargeted ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(state.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5])))
                .contentShape(Rectangle())
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.dropTargeted, perform: state.acceptDrop)
        }
    }

    private func reviewSection(_ config: CustomSiteConfig) -> some View {
        GroupBox("3. 核对来源，继续登录与测试") {
            VStack(alignment: .leading, spacing: 8) {
                Text(config.name).font(.headline)
                Text(config.origin).font(.callout.monospaced()).textSelection(.enabled)
                ForEach(config.metrics, id: \.id) { metric in
                    Text("\(metric.label) · \(metric.unit) · \(meaning(metric.meaning))").font(.callout)
                    if metric.collection != nil { Text("汇总符合条件的多条额度").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("我确认这是要接入的站点，以上额度含义正确", isOn: $state.sourceConfirmed)
                    .font(.callout)
                Text(record == nil ? "保存后打开登录窗口，再测试真实读数并核对，最后开启监控。" : "保存将暂停这个连接，需要重新登录、测试真实读数并核对后才能监控。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("高级设置：名称与 JSON 配置", isExpanded: $state.showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("显示名称（留空使用配置中的名称）", text: Binding(get: { state.targetName }, set: state.setTargetName))
                Text("若 Agent 返回的是文本，可在这里粘贴 JSON，再点击检查。只接受读取规则，不接受脚本、密码、Cookie 或 API key。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { state.configurationText }, set: state.setConfigurationText))
                    .font(.system(.caption, design: .monospaced)).frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    .accessibilityLabel("高级 JSON 配置")
                Button("检查配置") { state.validate() }.disabled(state.configurationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isImporting)
            }.padding(.top, 8)
        }.font(.callout)
    }

    private func meaning(_ value: CustomMetricMeaning) -> String {
        switch value { case .balance: return "余额"; case .remaining: return "剩余"; case .used: return "已用" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 生成的配置文件"
        panel.message = "选择单个 .json 文件（64 KB 以内），看板会检查来源、格式和指标。"
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importURL(url)
    }

    private func save() {
        guard state.canSave, let config = state.reviewedConfig else { return }
        do {
            let id: UUID
            if let record { try store.updateCustomSite(id: record.id, config: config); id = record.id }
            else { id = try store.addCustomSite(config: config) }
            onSaved(id); state.deactivate(); dismiss()
        } catch { state.report(error.localizedDescription) }
    }
}
