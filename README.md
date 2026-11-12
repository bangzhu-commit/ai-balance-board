# AI 额度看板

macOS 桌面悬浮看板，集中查看 AI 工具的最近额度。后台按约 5 分钟刷新，登录、唤醒和网络恢复后合并补查；查询不调用模型，不消耗模型推理 token。

**[下载 Mac 应用 v0.7.2](https://github.com/bangzhu-commit/ai-balance-board/releases/download/v0.7.2/AI-Balance-Board-0.7.2-macos-arm64.zip)** · [版本详情](https://github.com/bangzhu-commit/ai-balance-board/releases/tag/v0.7.2) · [SHA256 校验文件](https://github.com/bangzhu-commit/ai-balance-board/releases/download/v0.7.2/SHA256SUMS.txt)

**普通用户请选择上方应用 ZIP，不要下载 GitHub 的 “Source code”。** 仅支持 Apple Silicon（M 系列芯片）、macOS 14 或更新版本，不支持 Intel Mac。

v0.7.2 为预览版。应用使用 ad-hoc 签名，尚无 Developer ID 签名、公证或自动更新；macOS 可能阻止打开下载包。首次提示“无法验证开发者”时，确认下载来源及校验值后，可按[首次拦截处理步骤](docs/installation.md#首次打开被-macos-拦截)在系统设置中为这个 app 授权；若提示损坏或恶意软件，请停止安装。不要关闭 Gatekeeper 等系统防护。项目采用 [MIT License](LICENSE)。

## 新用户：下载与开始

1. 下载上方应用 ZIP，双击解压；需要核验文件时，按 [安装说明](docs/installation.md#校验下载文件) 比较 SHA256。
2. 将解压得到的 `AI 额度看板.app` 拖入“应用程序”文件夹，再双击打开；如被系统拦截，按[系统设置操作步骤](docs/installation.md#首次打开被-macos-拦截)处理。注册完成后尽量不要移动它。
3. 在首次设置中选择自己使用的 **AI 工具**。Codex、Grok Bot 可使用现有内置连接；其他工具从“自定义接入”开始，也可以点“稍后设置”。网站和中转站在单独入口中添加。
4. 确认卡片出现**最新更新时间及读取成功状态**。如需登录后自启，在设置中开启相应开关。

之后可从看板右上角齿轮或菜单栏“服务与设置…”重新进入设置。

顶部图标、标题及标题旁空白区域有固定的原生拖动区域；拖动边缘或右下角可等比例缩放，文字、图标、卡片和间距一起变化；位置和比例会保存，额度刷新保持缩放比例。看板基准高度会适应卡片内容，缩放范围为 80%–160%（受屏幕可用空间限制），菜单栏“恢复默认大小”恢复 100%。连接较多时仍可滚动，缩小不会减少原本可见的逻辑区域。看板默认不置顶，可在菜单栏或“运行方式”开启“置顶显示”。找不到窗口时，选择菜单栏的“恢复看板位置与大小”。右上角关闭按钮只收起到菜单栏，后台继续刷新；完全停止请使用菜单栏“退出”。普通 app 使用与应用内注册无需安装 Python 或 Node.js。

## 先选择 AI 工具

| 工具入口 | 内置连接 | 自定义接入 |
| --- | --- | --- |
| Codex | 本机 Codex CLI 所登录的 ChatGPT 套餐额度 | 可另建自定义连接；不要把 API 账单当成 ChatGPT 套餐额度 |
| Claude | 暂无 | 先明确产品、账号与套餐，再核实可读取的额度来源 |
| WorkBuddy | 暂无 | 需生成配置、测试并核对 |
| 千问办公 | 暂无 | 需生成配置、测试并核对 |
| 豆包办公 | 暂无 | 需生成配置、测试并核对 |
| Grok Bot | 现有 Cursor 账号额度连接器 | 可另建自定义连接；该内置连接不是 xAI / Grok 官方通用额度接口 |
| Muse（Meta Personal Agent） | 暂无 | 需生成配置、测试并核对 |
| 其他 AI 工具 | 暂无 | 填写名称，用同一流程接入；也适用于希望尝试的 Qoder、Cursor 等工具 |

**有工具入口不等于已接通额度。** 自定义接入目前依赖工具提供可访问的 HTTPS 额度页、同源只读 JSON 接口或稳定网页元素；没有可靠来源时无法自动监控。名称不决定账号来源、额度单位或套餐周期，也不代表这些工具都提供 Computer Use。详见[工具选择与接入边界](docs/ai-tools.md)。

## 自定义连接：工具或网站都走同一流程

1. 在 AI 工具目录中点击 **自定义接入**。网站 / 中转站则展开对应入口，点击 **添加站点**；已有内置中转站连接仍保留在这里。
2. 网站入口先粘贴网址，可使用首页、登录页或仪表盘链接。看板仅保留 HTTPS 域名，去掉路径、查询参数和片段；默认名称由域名生成。点击 **复制给 Agent 的接入任务**，交给已启用 Computer Use 的 Agent；只有工具名称时，先请 Agent 核实产品及额度页。登录由你本人完成。
3. 把 Agent 生成的配置文件拖入向导，或点击选择文件。格式检查通过后，核对域名和指标，确认来源再保存。原始 JSON 编辑和名称修改收在“高级设置”；保存不会自动查询。
4. 打开该站点的登录窗口并登录，点击 **测试连接**，把金额、单位、已用 / 剩余含义与网页对照。
5. 勾选核对确认，点击 **确认并开启自动查询**。后续约 5 分钟查询一次，不调用模型；唤醒、联网恢复后合并补查。

首次 Agent 分析与以后修复会使用所选 Agent 的额度。看板只执行固定读取规则，不在后台调用 Agent。每条自定义连接独立保存登录会话；改配置后必须重新测试。工具和网站共用最多 12 条自定义连接。

[完整接入与配置规范](docs/custom-sites.md) · [给 Agent 的接入指引](docs/agent-site-onboarding.md) · [JSON 示例](examples/custom-sites/json-example.json) · [网页元素示例](examples/custom-sites/dom-example.json)

## Grok Bot：首次连接

1. 保持 Chrome 运行，并在 `https://cursor.com/dashboard` 登录需要监控的账号。
2. 在看板设置中点击安装本机连接器。安装器只注册本看板专用 Native Messaging host，并复制扩展运行文件。
3. 由你在 Chrome 打开 `chrome://extensions/`，开启开发者模式，点击“加载已解压的扩展程序”，选择 `~/Library/Application Support/AI Balance Board/Chrome Extension`。可从设置打开该文件夹。
4. 返回看板等待连接检查和首个成功读数。无需让 Chrome 处于前台；需要时扩展会在已有普通 Chrome 窗口内建立后台用量页，不自行启动 Chrome 或新建窗口。

这是预览版的手动扩展安装流程，尚未上架 Chrome Web Store。扩展仅在 Cursor dashboard 页面运行，申请 `nativeMessaging`、`storage`、`alarms`；不读取或导出 Cookie、密码，不接触聊天内容。登录会话由 Chrome 使用，额度字段只送到本机看板。首次绑定一个 Chrome 个人资料，其他资料不能覆盖连接；需要更换时先停用扩展，再使用设置中的重置绑定。多账号同时监控目前不支持。

## 遇到问题

- **为什么列表里有工具，却还不能看额度？** 除明确标注的内置连接外，其余是自定义接入入口。先生成配置、登录、测试，再核对后开启；配置可解析或保存成功都不等于连接成功。
- **配置检查失败**：按提示检查 HTTPS 域名、同源相对路径与字段。把脱敏错误交给原 Agent 修正，不向配置中加入脚本、Cookie、API key 或请求头来绕过限制。详见[测试失败排查](docs/custom-sites.md#测试失败时)。
- **测试没有读数或读数不对**：确认登录的是目标账号及套餐，核对数值、单位、已用 / 剩余含义。不要确认可疑结果；网站升级后可能需要重新生成读取规则。
- **显示旧额度**：查看更新时间和状态。离线、休眠或关闭 Chrome 时无法获得新数据，恢复后只查最新一次，不追补历史周期；关机期间不会查询，开机后需登录并让看板运行。
- **服务提示限流**：保留上次读数，当前运行期间至少等待 5 分钟；手动刷新、唤醒或开关连接不会提前绕过冷却。不要反复重启尝试。
- **Grok Bot 未连接**：确认 Chrome 和普通窗口存在、扩展启用、账号已登录。查看扩展弹窗的本机连接状态；登录后可手动刷新。
- **Codex 找不到或未登录**：按设置中的安装路径和账号检查结果处理；看板不会代为登录，也不会读取账号 token。
- **自定义连接或中转站需登录**：重新打开看板登录窗口，完成后返回。已有 Chrome 登录不能直接替代独立 WebKit 会话。自定义连接重新登录后需测试并核对，避免沿用其他账号的读数。
- **界面变化后读不到**：中转站与 Grok Bot 使用官网自身调用的内部接口，兼容性没有公开承诺。错误时保留旧值并标明状态，不将失败填成零。
- **能拖动吗，为什么不一直置顶？** 从顶部标题区域拖动；拖窗口边缘或右下角时，整个看板等比例缩放，达到下限后停止缩小。默认不置顶；需要覆盖其他窗口时开启“置顶显示”。窗口找不到或尺寸不合适时，用菜单栏“恢复看板位置与大小”。
- **“零 token”包括配置过程吗？** 不包括 Agent 分析和修复。看板日常执行已确认的固定查询规则，不调用模型；网站自身请求限制、登录有效期与流量仍然适用。
- **升级会丢配置吗？** 按[安装与维护](docs/installation.md)退出旧版后替换 app，保留看板的应用数据目录和设置。不要将卸载时的清理步骤用于升级；升级后核对账号、连接状态与第一笔新读数。无自动更新。

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
zsh scripts/test-panel.sh
zsh scripts/test-site-wizard.sh
zsh scripts/test-edit-menu.sh
```

这些检查使用合成数据，不登录平台、不调用模型。构建输出在 `dist/AI 额度看板.app`。测试通过不能替代干净账户真实安装验收，参见 [发布验收表](docs/release-checklist.md)。

```sh
python3 scripts/package-preview.py
```

打包脚本从明确白名单导出独立源码与 app，并生成 SHA256，不上传任何文件。先运行构建；输出在 `release/`。发布前按验收表检查内容，签名完整性检查不等于 Developer ID 签名或 Apple 公证。

[版本说明](docs/CHANGELOG.md) · [支持与贡献](docs/CONTRIBUTING.md) · [安全问题报告](docs/SECURITY.md)
