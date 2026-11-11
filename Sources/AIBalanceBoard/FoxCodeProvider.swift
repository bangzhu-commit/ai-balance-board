import AppKit
import WebKit
import BalanceCore

/// 使用看板自己的 WebKit 登录会话；不读取 Chrome Cookie 或 API 密钥。
@MainActor
final class FoxCodeProvider: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var continuation: CheckedContinuation<BalanceReading, Error>?
    private var timeout: Task<Void, Never>?
    private var observing: Task<Void, Never>?
    private var loginPoller: Task<Void, Never>?
    private var isExtracting = false
    private var generation = 0
    private var loginActive = false
    private var activeNavigation: WKNavigation?
    var onReading: ((BalanceReading) -> Void)?
    private let dashboard = URL(string: "https://foxcode.rjj.cc/dashboard")!

    private func browser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // 系统默认可暂停不可见 WebView 的 JavaScript；看板需要后台只读请求继续完成。
        configuration.preferences.inactiveSchedulingPolicy = .none
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func fetch() async throws -> BalanceReading {
        if loginWindow?.isVisible == true {
            // 用户输入期间绝不重载或跳转网页。
            return try await extract()
        }
        guard UserDefaults.standard.bool(forKey: "foxcodeConnected") else {
            throw BalanceError.authenticationRequired("首次使用需登录 FoxCode")
        }
        guard continuation == nil else { throw BalanceError.unavailable("FoxCode 正在刷新") }
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            activeNavigation = browser().load(URLRequest(url: dashboard, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(BalanceError.network("FoxCode 读取超时，稍后自动重试")))
            }
        }
    }

    func connect() {
        // 仅由用户点击“连接”触发；刷新流程永不显示或激活窗口。
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "登录 FoxCode · AI 额度看板"
            window.isReleasedWhenClosed = false
            let container = NSView(frame: window.contentLayoutRect)
            let note = NSTextField(labelWithString: "登录成功后，点击右侧按钮返回悬浮看板")
            let done = NSButton(title: "返回看板", target: self, action: #selector(closeLoginWindow))
            done.bezelStyle = .rounded
            let web = browser()
            for view in [note, done, web] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
            }
            NSLayoutConstraint.activate([
                note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                note.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
                done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                done.centerYAnchor.constraint(equalTo: note.centerYAnchor),
                web.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
                web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            window.contentView = container
            window.center()
            loginWindow = window
        }
        cancelPendingRead()
        loginActive = true
        let loginGeneration = generation
        activeNavigation = browser().load(URLRequest(url: dashboard))
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginPoller?.cancel()
        loginPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.loginWindow?.isVisible == true else { return }
                if let reading = try? await self.extract() {
                    guard !Task.isCancelled, self.generation == loginGeneration else { return }
                    UserDefaults.standard.set(true, forKey: "foxcodeConnected")
                    self.onReading?(reading)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func cancelPendingRead() {
        generation += 1
        loginActive = false
        timeout?.cancel(); timeout = nil
        observing?.cancel(); observing = nil
        loginPoller?.cancel(); loginPoller = nil
        webView?.stopLoading()
        activeNavigation = nil
        isExtracting = false
        finish(.failure(CancellationError()))
    }

    @objc private func closeLoginWindow() {
        cancelPendingRead()
        loginWindow?.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loginActive || (continuation != nil && navigation === activeNavigation) else { return }
        let navigationGeneration = generation
        observing?.cancel()
        observing = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            do {
                let reading = try await self.extract()
                guard !Task.isCancelled, self.generation == navigationGeneration else { return }
                UserDefaults.standard.set(true, forKey: "foxcodeConnected")
                if self.loginActive { self.onReading?(reading) }
                self.finish(.success(reading))
            } catch {
                if !Task.isCancelled, self.generation == navigationGeneration, self.continuation != nil { self.finish(.failure(error)) }
            }
        }
    }

    private func extract() async throws -> BalanceReading {
        guard let webView, webView.url?.host == "foxcode.rjj.cc", webView.url?.path == "/dashboard" else {
            throw BalanceError.authenticationRequired("请登录 FoxCode")
        }
        guard !isExtracting else { throw BalanceError.unavailable("FoxCode 正在读取") }
        isExtracting = true
        let extractionGeneration = generation
        defer { if generation == extractionGeneration { isExtracting = false } }
        // 与网站自己的 dashboard 请求相同，只读 GET，浏览器自行附带同源会话。
        // 不读取或导出 Cookie/token；向原生层只返回三个额度字段。
        let script = #"""
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
            const response = await fetch('/api/user/dashboard', {
                method: 'GET', credentials: 'same-origin', cache: 'no-store',
                headers: {'Content-Type': 'application/json'}, signal: controller.signal
            });
            if (response.status === 401 || response.status === 403) return JSON.stringify({kind: 'auth'});
            if (response.status === 429) return JSON.stringify({kind: 'limited'});
            if (!response.ok) return JSON.stringify({kind: 'network'});
            if (!(response.headers.get('content-type') || '').includes('json')) return JSON.stringify({kind: 'auth'});
            const body = await response.json();
            const active = body?.data?.subscription?.active;
            if (body?.success !== true || !Array.isArray(active) || active.length > 10000) return JSON.stringify({kind: 'invalid'});
            return JSON.stringify({success: true, subscriptions: active.map(item => ({
                quotaUsed: item?.quotaUsed,
                plan: {quotaLimit: item?.plan?.quotaLimit, resetType: item?.plan?.resetType}
            }))});
        } finally { clearTimeout(timer); }
        """#
        do {
            guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String else {
                throw BalanceError.invalidResponse("FoxCode 返回格式不符合预期，请检查适配器更新")
            }
            guard !Task.isCancelled, generation == extractionGeneration else { throw CancellationError() }
            let data = Data(json.utf8)
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch envelope?["kind"] as? String {
            case "auth": throw BalanceError.authenticationRequired("FoxCode 登录已过期，请重新登录")
            case "limited": throw BalanceError.rateLimited("FoxCode 暂时限制查询频率，请稍后再试")
            case "network": throw BalanceError.network("FoxCode 服务暂不可用，稍后自动重试")
            case "invalid": throw BalanceError.invalidResponse("FoxCode 返回格式已变化，请检查适配器更新")
            default: break
            }
            do { return try FoxCodeParser.parse(data: data) }
            catch { throw BalanceError.invalidResponse("FoxCode 额度格式无法识别，请检查适配器更新") }
        } catch is CancellationError { throw CancellationError() }
        catch let error as BalanceError { throw error }
        catch { throw BalanceError.network("FoxCode 网络读取失败，稍后自动重试") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if continuation != nil, navigation === activeNavigation { failed() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if continuation != nil, navigation === activeNavigation { failed() }
    }
    private func failed() { finish(.failure(BalanceError.network("FoxCode 网络连接失败"))) }

    private func finish(_ result: Result<BalanceReading, Error>) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
