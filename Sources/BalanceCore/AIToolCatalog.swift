/// A starting point for setup, not a claim that every listed product has a quota adapter.
/// Custom connections always require a verified configuration and a successful test.
public struct AIToolPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let builtinService: ServiceID?

    public init(id: String, name: String, detail: String, builtinService: ServiceID? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.builtinService = builtinService
    }
}

public enum AIToolCatalog {
    public static let presets: [AIToolPreset] = [
        AIToolPreset(id: "codex", name: "Codex",
                     detail: "内置读取本机 Codex CLI 的 ChatGPT 套餐额度，也可自定义接入。",
                     builtinService: .codex),
        AIToolPreset(id: "claude", name: "Claude",
                     detail: "自定义接入；先确认要查询的套餐或 API 额度来源。"),
        AIToolPreset(id: "workbuddy", name: "WorkBuddy",
                     detail: "自定义接入；需确认账户是否提供可读取的额度页面。"),
        AIToolPreset(id: "qianwen", name: "千问办公",
                     detail: "自定义接入；需确认账户是否提供可读取的额度页面。"),
        AIToolPreset(id: "doubao", name: "豆包办公",
                     detail: "自定义接入；需确认账户是否提供可读取的额度页面。"),
        AIToolPreset(id: "grok-bot", name: "Grok Bot",
                     detail: "当前内置连接读取 Chrome 中的 Cursor 账号额度；其他来源可自定义。",
                     builtinService: .grok),
        AIToolPreset(id: "muse", name: "Muse",
                     detail: "Meta Personal Agent；自定义接入，需先核实额度来源。"),
        AIToolPreset(id: "other", name: "其他 AI 工具",
                     detail: "填写工具名称，请具备 Computer Use 能力的 Agent 帮助生成读取配置。")
    ]
}
