import AppKit
import WebKit
import BalanceCore

/// A deterministic reader for one user-approved site. Configuration contains data,
/// never executable JavaScript. Each record owns an isolated WebKit session.
@MainActor
final class CustomSiteProvider: NSObject, WKNavigationDelegate, NSWindowDelegate {
    let record: CustomSiteRecord
    var onConnectionAvailable: (() -> Void)?
    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var locationLabel: NSTextField?
    private var loginActive = false
    private var continuation: CheckedContinuation<BalanceReading, Error>?
    private var activeNavigation: WKNavigation?
    private var timeout: Task<Void, Never>?
    private var extraction: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(record: CustomSiteRecord) {
        self.record = record
        super.init()
    }

    private func browser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: record.id)
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    func fetch() async throws -> BalanceReading {
        try record.validate()
        try Task.checkCancellation()
        guard !loginActive else {
            throw BalanceError.authenticationRequired("请先完成登录并返回看板，再测试连接")
        }
        guard continuation == nil else { throw BalanceError.unavailable("该站点正在查询，请等待当前查询完成") }
        let request = try Self.queryRequest(for: record.config)
        generation &+= 1
        let queryGeneration = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(BalanceError.network("站点读取超时，稍后重试")), generation: queryGeneration)
                }
                activeNavigation = browser().load(request)
                if activeNavigation == nil {
                    finish(.failure(BalanceError.network("无法加载额度页面")), generation: queryGeneration)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.generation == queryGeneration else { return }
                self?.cancelPendingRead()
            }
        }
    }

    /// Called only by the user's login button. fetch() never creates a window.
    func connect() {
        guard (try? record.validate()) != nil else { return }
        cancelPendingRead()
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "登录 \(record.config.name) · AI 额度看板"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let container = NSView(frame: window.contentLayoutRect)
            let address = NSTextField(labelWithString: "当前网站：\(record.config.origin)")
            address.lineBreakMode = .byTruncatingMiddle
            let note = NSTextField(labelWithString: "请自行登录。完成后返回看板测试额度；关闭窗口不会被当作登录成功。")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            let done = NSButton(title: "返回看板测试", target: self, action: #selector(returnFromLogin))
            done.bezelStyle = .rounded
            let web = browser()
            for view in [address, note, done, web] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
            }
            NSLayoutConstraint.activate([
                address.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                address.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                address.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -12),
                done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                done.centerYAnchor.constraint(equalTo: address.centerYAnchor),
                note.leadingAnchor.constraint(equalTo: address.leadingAnchor),
                note.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 5),
                note.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
                web.topAnchor.constraint(equalTo: container.topAnchor, constant: 62),
                web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            window.contentView = container
            window.center()
            loginWindow = window
            locationLabel = address
        }
        loginActive = true
        browser().load(URLRequest(url: record.config.loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
        loginWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func returnFromLogin() {
        loginActive = false
        discardBrowser()
        onConnectionAvailable?()
    }

    func windowWillClose(_ notification: Notification) {
        guard loginActive else { return }
        loginActive = false
        discardBrowser()
        onConnectionAvailable?()
    }

    func cancelPendingRead() {
        let current = generation
        finish(.failure(CancellationError()), generation: current)
        generation &+= 1
        timeout?.cancel(); timeout = nil
        extraction?.cancel(); extraction = nil
        activeNavigation = nil
        if !loginActive { webView?.stopLoading() }
    }

    /// Cancels the reader and closes any user-opened window, retaining the session.
    func close() {
        loginActive = false
        cancelPendingRead()
        discardBrowser()
    }

    private func discardBrowser() {
        loginWindow?.delegate = nil
        loginWindow?.orderOut(nil)
        loginWindow?.contentView = nil
        loginWindow = nil
        locationLabel = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    /// Only for the user's explicit remove-site action; no other site's data is touched.
    func removeSession() async throws {
        let pendingExtraction = extraction
        close()
        await pendingExtraction?.value
        await cleanup?.value
        cleanup = nil
        try record.validate()
        try await WKWebsiteDataStore.remove(forIdentifier: record.id)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard !navigationAction.shouldPerformDownload,
              navigationAction.targetFrame != nil,
              let url = navigationAction.request.url,
              Self.allowsNavigation(url, origin: record.config.originURL, interactive: loginActive) else {
            decisionHandler(.cancel)
            if continuation != nil {
                finish(.failure(BalanceError.authenticationRequired("页面跳转到其他网站或登录页，请重新登录后测试")), generation: generation)
            }
            return
        }
        if !loginActive, record.config.mode == .json,
           !Self.matchesEndpoint(url, expected: record.config.requestURL!) {
            decisionHandler(.cancel)
            finish(.failure(BalanceError.authenticationRequired("额度接口发生跳转，请重新登录或检查接口地址")), generation: generation)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard navigationResponse.canShowMIMEType,
              let url = navigationResponse.response.url,
              Self.allowsNavigation(url, origin: record.config.originURL, interactive: loginActive) else {
            decisionHandler(.cancel)
            if continuation != nil {
                finish(.failure(BalanceError.invalidResponse("额度页面返回了不支持的内容")), generation: generation)
            }
            return
        }
        if !loginActive, navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            let error: BalanceError?
            if record.config.mode == .json {
                error = Self.jsonResponseError(response, expected: record.config.requestURL!)
            } else {
                switch response.statusCode {
                case 401, 403: error = .authenticationRequired("站点登录已失效，请重新登录")
                case 429: error = .rateLimited("站点限制查询频率，请稍后重试")
                case 400...599: error = .network("站点暂不可用，稍后重试")
                default: error = nil
                }
            }
            if let error {
                decisionHandler(.cancel)
                finish(.failure(error), generation: generation)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, continuation != nil, !loginActive, record.config.mode == .json else { return }
        finish(.failure(BalanceError.authenticationRequired("额度接口发生跳转，请重新登录或检查接口地址")), generation: generation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if loginActive, let url = webView.url {
            locationLabel?.stringValue = "当前网站：\(url.scheme ?? "https")://\(url.host ?? "")"
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, continuation != nil, !loginActive, navigation === activeNavigation else { return }
        let queryGeneration = generation
        extraction?.cancel()
        extraction = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.extract(generation: queryGeneration)
                guard !Task.isCancelled else { return }
                self.finish(.success(result), generation: queryGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(.failure(error), generation: queryGeneration)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        failed(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        failed(navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finish(.failure(BalanceError.network("站点读取进程已停止，请稍后重试")), generation: generation)
    }

    private func failed(_ navigation: WKNavigation?) {
        guard continuation != nil, navigation === activeNavigation else { return }
        finish(.failure(BalanceError.network("无法连接站点，请检查网络后重试")), generation: generation)
    }

    private func extract(generation queryGeneration: UInt64) async throws -> BalanceReading {
        let expectedURL = record.config.mode == .json ? record.config.requestURL! : record.config.pageURL
        guard let webView, let url = webView.url,
              Self.allowsNavigation(url, origin: record.config.originURL, interactive: false),
              url.path == expectedURL.path else {
            throw BalanceError.authenticationRequired("尚未进入配置的额度页面，请登录后测试")
        }
        let config = record.config
        let selectors = Array(Set(config.metrics.flatMap { [$0.value, $0.total].compactMap { $0 } })).sorted()
        let arguments: [String: Any] = [
            "expectedOrigin": config.originURL.absoluteString,
            "expectedPath": expectedURL.path,
            "mode": config.mode.rawValue,
            "selectors": config.mode == .dom ? selectors : []
        ]
        let raw: String
        do {
            guard let value = try await webView.callAsyncJavaScript(Self.extractionScript, arguments: arguments,
                                                                  in: nil, contentWorld: .defaultClient) as? String else {
                throw BalanceError.invalidResponse("站点返回格式无法识别，请检查接入配置")
            }
            raw = value
        } catch is CancellationError { throw CancellationError() }
        catch let error as BalanceError { throw error }
        catch { throw BalanceError.invalidResponse("站点读取规则未能执行，请检查配置或页面变化") }
        guard continuation != nil, generation == queryGeneration, !Task.isCancelled else { throw CancellationError() }
        guard let data = raw.data(using: .utf8), data.count <= 4_000_000,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = envelope["kind"] as? String else {
            throw BalanceError.invalidResponse("站点响应过大或格式错误")
        }
        switch kind {
        case "auth": throw BalanceError.authenticationRequired("站点登录已失效，请重新登录后测试")
        case "limited": throw BalanceError.rateLimited("站点限制查询频率，请稍后重试")
        case "network": throw BalanceError.network("站点读取超时或网络错误，稍后重试")
        case "ok":
            do {
                if config.mode == .json, let body = envelope["body"] as? String {
                    return try CustomSiteParser.parseJSON(data: Data(body.utf8), config: config, id: record.id)
                }
                if config.mode == .dom, let values = envelope["values"] as? [String: String] {
                    return try CustomSiteParser.parseDOM(values: values, config: config, id: record.id)
                }
            } catch {
                throw BalanceError.invalidResponse("额度字段或数值格式不匹配，请检查配置与网页显示")
            }
            fallthrough
        default: throw BalanceError.invalidResponse("找不到唯一且有效的额度字段，请检查配置或页面变化")
        }
    }

    private func finish(_ result: Result<BalanceReading, Error>, generation queryGeneration: UInt64) {
        guard continuation != nil, generation == queryGeneration else { return }
        timeout?.cancel(); timeout = nil
        extraction?.cancel(); extraction = nil
        activeNavigation = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
        // Release the page between polls so its own timers cannot keep querying.
        // The per-site website data store (and login session) persists.
        if !loginActive {
            if let view = webView {
                cleanup = Task {
                    _ = try? await view.callAsyncJavaScript("globalThis.__aiBalanceCancelled = true;",
                                                           arguments: [:], in: nil, contentWorld: .defaultClient)
                }
            }
            discardBrowser()
        }
    }

    static func allowsNavigation(_ url: URL, origin: URL, interactive: Bool) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if !interactive {
            return host == origin.host?.lowercased() && (url.port ?? 443) == (origin.port ?? 443)
        }
        // Interactive OAuth can leave the configured origin, but may not navigate
        // to local hosts, IP literals, or custom schemes from the login window.
        guard (url.port ?? 443) == 443, host.contains("."), !host.hasSuffix("."),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !["localhost", "local", "internal", "lan", "home", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? "") else { return false }
        return true
    }

    /// JSON mode navigates directly to the endpoint: no dashboard scripts and no
    /// second JavaScript fetch. WebKit supplies this site's isolated login session.
    static func queryRequest(for config: CustomSiteConfig) throws -> URLRequest {
        try config.validate()
        let url = config.mode == .json ? config.requestURL! : config.pageURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if config.mode == .json { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        return request
    }

    static func matchesEndpoint(_ url: URL, expected: URL) -> Bool {
        allowsNavigation(url, origin: expected, interactive: false) &&
        url.path == expected.path && url.query == nil && url.fragment == nil
    }

    static func jsonResponseError(_ response: HTTPURLResponse, expected: URL) -> BalanceError? {
        guard let url = response.url, matchesEndpoint(url, expected: expected) else {
            return .authenticationRequired("额度接口发生跳转，请重新登录或检查接口地址")
        }
        switch response.statusCode {
        case 401, 403: return .authenticationRequired("站点登录已失效，请重新登录")
        case 429: return .rateLimited("站点限制查询频率，请稍后重试")
        case 300...399: return .authenticationRequired("额度接口发生跳转，请重新登录或检查接口地址")
        case 400...599: return .network("站点暂不可用，稍后重试")
        case 200: break
        default: return .invalidResponse("额度接口没有返回完整 JSON 内容")
        }
        let mime = (response.mimeType ?? "").lowercased()
        guard mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")) else {
            return .authenticationRequired("额度接口返回了网页，请先登录或检查接口地址")
        }
        guard response.expectedContentLength <= Int64(CustomSiteParser.maxResponseBytes) else {
            return .invalidResponse("额度接口响应过大，请选择只返回额度的接口")
        }
        return nil
    }

    /// All variable content enters through callAsyncJavaScript arguments. Never
    /// concatenate imported selectors, paths or names into executable source.
    static let extractionScript = #"""
    const result = (kind, extra = {}) => JSON.stringify({kind, ...extra});
    globalThis.__aiBalanceCancelled = false;
    const origin = new URL(expectedOrigin).origin;
    if (location.origin !== origin || location.pathname !== expectedPath) return result('auth');
    if (mode === 'json') {
        const body = document.body?.textContent ?? document.documentElement?.textContent ?? '';
        if (!body || body.length > 524288 || new TextEncoder().encode(body).byteLength > 524288) return result('invalid');
        try { JSON.parse(body); } catch (_) { return result('invalid'); }
        return result('ok', {body});
    }
    if (mode !== 'dom' || !Array.isArray(selectors) || selectors.length === 0 || selectors.length > 12) return result('invalid');
    const deadline = Date.now() + 8000;
    do {
        if (globalThis.__aiBalanceCancelled) return result('invalid');
        if (location.origin !== origin || location.pathname !== expectedPath) return result('auth');
        const values = Object.create(null);
        let missing = false;
        for (const selector of selectors) {
            let nodes;
            try { nodes = document.querySelectorAll(selector); } catch (_) { return result('invalid'); }
            if (nodes.length > 1) return result('invalid');
            if (nodes.length === 0) { missing = true; continue; }
            const value = (nodes[0].textContent || '').trim();
            if (value.length > 4096) return result('invalid');
            if (value.length === 0) { missing = true; continue; }
            values[selector] = value;
        }
        if (!missing) return result('ok', {values});
        await new Promise(resolve => setTimeout(resolve, 250));
    } while (Date.now() < deadline);
    return result('invalid');
    """#
}
