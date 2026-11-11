# 安装、更新与移除

预览版仅支持 Apple Silicon 和 macOS 14+，尚无 Developer ID 签名/公证；不要关闭系统安全防护来运行。普通用户使用 app 内设置，无需终端或 Python。

## 下载与安装

从 [v0.4.0 Release](https://github.com/bangzhu-commit/ai-balance-board/releases/tag/v0.4.0) 下载 `AI-Balance-Board-0.4.0-macos-arm64.zip`。GitHub 自动生成的 “Source code” 是开发源码，不是可双击的应用。

解压后将 `AI 额度看板.app` 拖入“应用程序”再打开。若 macOS 阻止运行，请停止安装并报告系统提示；此预览版不要求关闭 Gatekeeper、移除安全属性或绕过系统检查。

## 校验下载文件

同时下载 Release 的 `SHA256SUMS.txt`。如需核验，在终端切换到应用 ZIP 所在目录并运行：

```sh
shasum -a 256 AI-Balance-Board-0.4.0-macos-arm64.zip
```

比较输出的 64 位摘要与 `SHA256SUMS.txt` 中对应文件名的一行，应完全一致。摘要不一致时不要安装，应重新下载或报告问题。SHA256 用于核验下载内容一致性，不替代开发者签名或公证。

## 注册与移动 app

先把 app 放入最终安装位置，再在设置中注册本机连接器和登录自启。登录自启采用用户级 LaunchAgent，命令为 `open -g <实际 app 路径>`，不设置 KeepAlive。加载启动项时系统可能尝试后台打开一次，已有实例由单实例锁处理。

注册桥接不替你启用 Chrome 扩展，仍需手动完成 README 中的加载步骤。移动 app 后原启动器路径会失效；应重新注册，遇到冲突先在原位置取消旧注册。不要手改 Chrome 配置。

## 更新

1. 在 Chrome 停用本看板扩展，避免桥接进程继续使用旧版本。
2. 菜单栏退出看板，保留旧 app 作为回滚副本。
3. 用新 app 替换同一路径的旧 app。
4. 启动新 app，重新安装本机连接器，再在 Chrome 重新加载并启用扩展。
5. 确认启用的服务都有新读数；旧数字本身不代表更新成功。

预览版尚无自动更新。首次设置可跳过服务连接，不要求先连接全部三个服务。

## 取消自启与卸载

先在设置取消登录自启，在 Chrome 停用扩展。在看板“检查与连接”的 Grok Bot 卡片中展开“移除连接组件”，移除本机组件后，在 Chrome 手动移除扩展、退出看板，把 app 移到废纸篓。开发者也可主动运行下方维护命令移除本机集成。

完整账号会话删除尚未做成一键操作。默认保留 `~/Library/Application Support/AI Balance Board` 中的最近读数与配对记录，以及系统管理的 WebKit 会话和看板偏好。设置里的清除读数只清除额度缓存，不等于退出账号；重置浏览器绑定前要先停用扩展。不要将这些用户数据随安装包分享。

## 开发者维护命令

以下命令行安装脚本需要 Apple Command Line Tools 提供的 Python 3，普通用户优先使用原生设置。路径为示例，请换成实际 app 的绝对路径。

```sh
APP="$HOME/Applications/AI 额度看板.app"
bash "$APP/Contents/Resources/scripts/install-login-item.sh" --register --app-path "$APP"
bash "$APP/Contents/Resources/scripts/install-browser-bridge.sh" --install --app-path "$APP"
bash "$APP/Contents/Resources/scripts/install-login-item.sh" --disable --app-path "$APP"
bash "$APP/Contents/Resources/scripts/uninstall.sh" --integrations --app-path "$APP"
```

`--register` 仅注册已安装 app，不替换应用。`uninstall.sh` 仅移除启动集成与桥接运行文件，不停止其他应用、不删除个人数据。源码开发者仍可运行 `bash scripts/install-login-item.sh --enable` 安装构建产物到用户 Applications 并保留一个上一版；它不会自动结束 UI 或 helper。
