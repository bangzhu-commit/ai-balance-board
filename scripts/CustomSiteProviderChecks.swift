import Foundation
import BalanceCore

@main enum CustomSiteProviderChecks {
    @MainActor static func main() async throws {
        let origin = URL(string: "https://relay.example.com")!
        let allowed = ["https://relay.example.com/dashboard", "https://relay.example.com:443/login"]
        let denied = ["http://relay.example.com/dashboard", "https://other.example.com/dashboard",
                      "https://relay.example.com.evil.example/dashboard", "https://relay.example.com:8443/dashboard",
                      "https://name:secret@relay.example.com/dashboard", "file:///private/tmp/page.html",
                      "javascript:alert(1)", "data:text/html,test"]
        for raw in allowed {
            precondition(CustomSiteProvider.allowsNavigation(URL(string: raw)!, origin: origin, interactive: false))
        }
        for raw in denied {
            precondition(!CustomSiteProvider.allowsNavigation(URL(string: raw)!, origin: origin, interactive: false))
        }
        precondition(CustomSiteProvider.allowsNavigation(URL(string: "https://login.identity.example/auth")!, origin: origin, interactive: true))
        for raw in ["https://localhost/login", "https://127.0.0.1/login", "https://[::1]/login", "https://service.local/login", "https://service.internal/login", "https://service.lan/login", "https://service.home/login", "https://identity.example:8443/login", "file:///private/tmp/page.html"] {
            precondition(!CustomSiteProvider.allowsNavigation(URL(string: raw)!, origin: origin, interactive: true))
        }
        let config = CustomSiteConfig(name: "合成测试", origin: origin.absoluteString, loginPath: "/login", pagePath: "/dashboard",
                                      mode: .json, requestPath: "/api/balance", metrics: [
                                        CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance, value: "/balance")
                                      ])
        let request = try CustomSiteProvider.queryRequest(for: config)
        precondition(request.url == config.requestURL && request.url != config.pageURL)
        precondition(request.httpMethod == "GET" && request.httpBody == nil)
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        let endpoint = config.requestURL!
        func response(_ status: Int = 200, type: String = "application/json", length: String? = nil, url: URL? = nil) -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            if let length { headers["Content-Length"] = length }
            return HTTPURLResponse(url: url ?? endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        precondition(CustomSiteProvider.jsonResponseError(response(), expected: endpoint) == nil)
        precondition(CustomSiteProvider.jsonResponseError(response(type: "application/problem+json"), expected: endpoint) == nil)
        for code in [401, 403, 302] {
            precondition(CustomSiteProvider.jsonResponseError(response(code), expected: endpoint)?.connectionState == .authenticationRequired)
        }
        precondition(CustomSiteProvider.jsonResponseError(response(429), expected: endpoint)?.connectionState == .rateLimited)
        precondition(CustomSiteProvider.jsonResponseError(response(503), expected: endpoint)?.connectionState == .networkUnavailable)
        precondition(CustomSiteProvider.jsonResponseError(response(206), expected: endpoint)?.connectionState == .invalidResponse)
        precondition(CustomSiteProvider.jsonResponseError(response(type: "text/html"), expected: endpoint)?.connectionState == .authenticationRequired)
        precondition(CustomSiteProvider.jsonResponseError(response(length: "524289"), expected: endpoint)?.connectionState == .invalidResponse)
        precondition(CustomSiteProvider.jsonResponseError(response(url: URL(string: "https://relay.example.com/login")!), expected: endpoint)?.connectionState == .authenticationRequired)
        precondition(CustomSiteProvider.jsonResponseError(response(url: URL(string: "https://other.example.com/api/balance")!), expected: endpoint)?.connectionState == .authenticationRequired)
        let invalid = CustomSiteRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, config: config)
        let provider = CustomSiteProvider(record: invalid)
        do {
            _ = try await provider.fetch()
            preconditionFailure("A zero UUID must fail before WebKit is created")
        } catch is CustomSiteError { }
        provider.close()
        print("Custom site provider: 38 navigation/request/response checks passed; no WebView, account or network used")
    }
}
