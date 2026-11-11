# AI 额度看板

macOS 桌面悬浮看板，集中查看 AI 工具的最近额度。后台按约 5 分钟刷新，登录、唤醒和网络恢复后合并补查；查询不调用模型，不消耗模型推理 token。

**[下载 Mac 应用 v0.5.0](https://github.com/bangzhu-commit/ai-balance-board/releases/download/v0.5.0/AI-Balance-Board-0.5.0-macos-arm64.zip)** · [版本详情](https://github.com/bangzhu-commit/ai-balance-board/releases/tag/v0.5.0) · [SHA256 校验文件](https://github.com/bangzhu-commit/ai-balance-board/releases/download/v0.5.0/SHA256SUMS.txt)

**普通用户请选择上方应用 ZIP，不要下载 GitHub 的 “Source code”。** 仅支持 Apple Silicon（M 系列芯片）、macOS 14 或更新版本，不支持 Intel Mac。

v0.5.0 为预览版。应用使用 ad-hoc 签名，尚无 Developer ID 签名、公证或自动更新；macOS 可能阻止打开下载包。首次提示“无法验证开发者”时，确认下载来源及校验值后，可按[首次拦截处理步骤](docs/installation.md#首次打开被-macos-拦截)在系统设置中为这个 app 授权；若提示损坏或恶意软件，请停止安装。不要关闭 Gatekeeper 等系统防护。项目采用 [MIT License](LICENSE)。

## 新用户：下载与开始

1. 下载上方应用 ZIP，双击解压；需要核验文件时，按 [安装说明](docs/installation.md#校验下载文件) 比较 SHA256。
2. 将解压得到的 `AI 额度看板.app` 拖入“应用程序”文件夹，再双击打开；如被系统拦截，按[系统设置操作步骤](docs/installation.md#首次打开被-macos-拦截)处理。注册完成后尽量不要移动它。
3. 在首次设置中选择自己使用的服务，按提示连接。可以只启用一个服务，也可以点“稍后设置”。
4. 确认卡片出现**最新更新时间及读取成功状态**。如需登录后自启，在设置中开启相应开关。

之后可从看板右上角齿轮或菜单栏“服务与设置…”重新进入设置。

顶部图标、标题及标题右侧空白区域可拖动。右上角关闭按钮只是收起到菜单栏，后台继续刷新；要结束运行，请使用菜单栏的“退出”。普通 app 使用与应用内注册无需安装 Python 或 Node.js。

| 服务 | 当前接入范围 | 使用前准备 |
| --- | --- | --- |
| 中转站 | 内置适配，或导入自定义站点配置 | 在看板自己的登录窗口登录 |
| Codex | ChatGPT 套餐额度 | 安装并登录 Codex CLI；按设置页检测结果处理 |
| Grok Bot | 当前 Chrome Cursor 账号的 Grok Bot 额度 | Chrome 120+、登录对应 Cursor 账号、安装本机连接器 |

自定义站点可导入同源只读 JSON 接口或固定网页元素规则，需逐站测试与核对；不能只填网址就自动识别。WorkBuddy、千问办公、Qoder 及通用 Cursor 卡片**没有内置适配**，也不代表能用自定义规则接入所有服务。不同平台的额度单位分别显示。

## 自定义站点：添加、导入与测试

1. 在“服务与设置”的选择或连接页点击 **添加站点**，填写显示名称与 HTTPS 站点地址。
2. 点击 **复制给 Agent 的接入任务**，交给具有浏览器 / Computer Use 能力的 Codex、WorkBuddy 等 Agent；由你本人登录，Agent 按规范生成配置。已有配置可跳过这一步。
3. 粘贴或导入 JSON，点击 **检查配置**，核对域名和指标，再保存。保存不会自动查询。
4. 打开该站点的登录窗口并登录，点击 **测试连接**，把金额、单位、已用 / 剩余含义与网页对照。
5. 勾选核对确认，点击 **确认并开启自动查询**。后续约 5 分钟查询一次，不调用模型；唤醒、联网恢复后合并补查。

首次 Agent 分析与以后修复会使用所选 Agent 的额度。看板只执行固定读取规则，不在后台调用 Agent。每站点独立保存登录会话；改配置后必须重新测试。最多保存 12 个自定义站点。

[完整接入与配置规范](docs/custom-sites.md) · [给 Agent 的接入指引](docs/agent-site-onboarding.md) · [JSON 示例](examples/custom-sites/json-example.json) · [网页元素示例](examples/custom-sites/dom-example.json)

## Grok Bot：首次连接

1. 保持 Chrome 运行，并在 `https://cursor.com/dashboard` 登录需要监控的账号。
2. 在看板设置中点击安装本机连接器。安装器只注册本看板专用 Native Messaging host，并复制扩展运行文件。
3. 由你在 Chrome 打开 `chrome://extensions/`，开启开发者模式，点击“加载已解压的扩展程序”，选择 `~/Library/Application Support/AI Balance Board/Chrome Extension`。可从设置打开该文件夹。
4. 返回看板等待连接检查和首个成功读数。无需让 Chrome 处于前台；需要时扩展会在已有普通 Chrome 窗口内建立后台用量页，不自行启动 Chrome 或新建窗口。

这是预览版的手动扩展安装流程，尚未上架 Chrome Web Store。扩展仅在 Cursor dashboard 页面运行，申请 `nativeMessaging`、`storage`、`alarms`；不读取或导出 Cookie、密码，不接触聊天内容。登录会话由 Chrome 使用，额度字段只送到本机看板。首次绑定一个 Chrome 个人资料，其他资料不能覆盖连接；需要更换时先停用扩展，再使用设置中的重置绑定。多账号同时监控目前不支持。

## 遇到问题

- **显示旧额度**：查看更新时间和状态。离线、休眠或关闭 Chrome 时无法获得新数据，恢复后只查最新一次，不追补历史周期。
- **Grok Bot 未连接**：确认 Chrome 和普通窗口存在、扩展启用、账号已登录。查看扩展弹窗的本机连接状态；登录后可手动刷新。
- **Codex 找不到或未登录**：按设置中的安装路径和账号检查结果处理；看板不会代为登录，也不会读取账号 token。
- **中转站需登录**：重新打开看板登录窗口，完成后返回。已有 Chrome 登录不能直接替代独立 WebKit 会话。
- **界面变化后读不到**：中转站与 Grok Bot 使用官网自身调用的内部接口，兼容性没有公开承诺。错误时保留旧值并标明状态，不将失败填成零。
- **升级、取消自启、卸载**：见 [安装与维护](docs/installation.md)。

报告问题前查看 [隐私说明](docs/privacy.md)，不要提交账号、凭据、原始网页响应或个人额度截图。请使用 [GitHub 问题模板](https://github.com/bangzhu-commit/ai-balance-board/issues/new/choose)。

## 开发者：从源码构建

需要 macOS 14+ / Apple Silicon、Swift 6 工具链、Python 3，以及运行扩展测试所需的 Node.js 20+。当前脚本直接调用 `swiftc`，`Package.swift` 保留为标准 SwiftPM 描述；不依赖第三方 Swift 运行库。

```sh
./scripts/build.sh
./scripts/test.sh
node --test browser-extension/tests/extension.test.mjs
zsh scripts/test-custom-site-provider.sh
zsh scripts/test-custom-site-webkit.sh
python3 scripts/test-browser-bridge.py
python3 scripts/test-browser-client.py
bash scripts/check-login-item.sh
zsh scripts/test-codex-provider.sh
zsh scripts/test-setup-integration.sh
zsh scripts/test-store.sh
```

这些检查使用合成数据，不登录平台、不调用模型。构建输出在 `dist/AI 额度看板.app`。测试通过不能替代干净账户真实安装验收，参见 [发布验收表](docs/release-checklist.md)。

```sh
python3 scripts/package-preview.py
```

打包脚本从明确白名单导出独立源码与 app，并生成 SHA256，不上传任何文件。先运行构建；输出在 `release/`。发布前按验收表检查内容，签名完整性检查不等于 Developer ID 签名或 Apple 公证。

[版本说明](docs/CHANGELOG.md) · [支持与贡献](docs/CONTRIBUTING.md) · [安全问题报告](docs/SECURITY.md)
