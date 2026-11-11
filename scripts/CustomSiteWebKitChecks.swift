import AppKit
import WebKit
import BalanceCore

private enum FixtureError: Error { case timeout, failed, invalid }

/// A real WebKit JSON document, loaded from memory. No window is ever created,
/// no HTTP server is started, and no URL is requested from a remote service.
@MainActor
private final class FixtureLoader: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    func load(_ data: Data, mime: String, url: URL, in view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            view.navigationDelegate = self
            timeout = Task { [weak self, weak view] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                view?.stopLoading()
                self?.finish(.failure(FixtureError.timeout))
            }
            view.load(data, mimeType: mime, characterEncodingName: "utf-8", baseURL: url)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(FixtureError.failed)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(FixtureError.failed)) }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
}

@main enum CustomSiteWebKitChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loader = FixtureLoader()
        let origin = "https://fixture.example.com"
        let endpoint = URL(string: origin + "/api/balance")!
        let config = CustomSiteConfig(name: "合成测试", origin: origin, loginPath: "/login", pagePath: "/dashboard",
                                      mode: .json, requestPath: "/api/balance", metrics: [
                                        CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance, value: "/balance")
                                      ])
        let body = "{\n\"balance\":12.5,\"note\":\"中文<script>globalThis.bad=true</script>\"\n}"
        try await loader.load(Data(body.utf8), mime: "application/json", url: endpoint, in: view)
        let args: [String: Any] = ["expectedOrigin": origin, "expectedPath": "/api/balance", "mode": "json", "selectors": []]
        guard let raw = try await view.callAsyncJavaScript(CustomSiteProvider.extractionScript, arguments: args, in: nil, contentWorld: .defaultClient) as? String,
              let envelope = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              envelope["kind"] as? String == "ok", let extracted = envelope["body"] as? String else {
            throw FixtureError.invalid
        }
        precondition(extracted.trimmingCharacters(in: .whitespacesAndNewlines) == body.trimmingCharacters(in: .whitespacesAndNewlines))
        let reading = try CustomSiteParser.parseJSON(data: Data(extracted.utf8), config: config, id: UUID())
        precondition(reading.metrics.first?.value.contains("12.5") == true)
        let executed = try await view.callAsyncJavaScript("return globalThis.bad === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        precondition(executed == false)
        try await loader.load(Data("not json".utf8), mime: "application/json", url: endpoint, in: view)
        let invalid = try await view.callAsyncJavaScript(CustomSiteProvider.extractionScript, arguments: args, in: nil, contentWorld: .defaultClient) as? String
        precondition(invalid == "{\"kind\":\"invalid\"}")
        let dashboard = URL(string: origin + "/dashboard")!
        let domConfig = CustomSiteConfig(name: "网页合成测试", origin: origin, loginPath: "/login", pagePath: "/dashboard",
                                         mode: .dom, metrics: [
                                            CustomSiteMetric(id: "remaining", label: "剩余", unit: "%", meaning: .remaining,
                                                             value: "#remaining", suffix: "%")
                                         ])
        let domArgs: [String: Any] = ["expectedOrigin": origin, "expectedPath": "/dashboard", "mode": "dom", "selectors": ["#remaining"]]
        try await loader.load(Data("<!doctype html><html><body><span id='remaining'>87%</span></body></html>".utf8),
                              mime: "text/html", url: dashboard, in: view)
        guard let domRaw = try await view.callAsyncJavaScript(CustomSiteProvider.extractionScript, arguments: domArgs, in: nil, contentWorld: .defaultClient) as? String,
              let domEnvelope = try JSONSerialization.jsonObject(with: Data(domRaw.utf8)) as? [String: Any],
              domEnvelope["kind"] as? String == "ok", let values = domEnvelope["values"] as? [String: String] else {
            throw FixtureError.invalid
        }
        precondition(values == ["#remaining": "87%"])
        let domReading = try CustomSiteParser.parseDOM(values: values, config: domConfig, id: UUID())
        precondition(domReading.metrics.first?.value == "87%")
        precondition(domReading.metrics.first?.remainingFraction == 0.87)
        try await loader.load(Data("<!doctype html><html><body><span id='remaining'>87%</span><span id='remaining'>43%</span></body></html>".utf8),
                              mime: "text/html", url: dashboard, in: view)
        let ambiguous = try await view.callAsyncJavaScript(CustomSiteProvider.extractionScript, arguments: domArgs, in: nil, contentWorld: .defaultClient) as? String
        precondition(ambiguous == "{\"kind\":\"invalid\"}")
        view.stopLoading(); view.navigationDelegate = nil
        precondition(NSApplication.shared.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow })
        precondition(!NSApplication.shared.isActive)
        print("Custom site WebKit: 10 real offscreen JSON/DOM checks passed; memory fixtures only, no visible windows, activation or accounts")
    }
}
