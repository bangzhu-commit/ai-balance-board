import Foundation

/// The only URL data handed to the setup UI and Agent task. Paths, query values,
/// and fragments deliberately never leave the input boundary.
public struct SiteOnboardingTarget: Equatable, Sendable {
    public let origin: String
    public let displayName: String

    public init(origin: String, displayName: String) {
        self.origin = origin
        self.displayName = displayName
    }
}

public enum SiteOnboardingError: LocalizedError, Equatable, Sendable {
    case emptyInput, tooLong, invalidURL, insecureScheme, credentials, unsupportedOrigin

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "请粘贴站点网址；首页、登录页或额度页链接都可以。"
        case .tooLong: return "网址过长，请只粘贴站点地址，不要粘贴网页内容。"
        case .invalidURL: return "无法识别这个网址。请粘贴一个完整的 HTTPS 链接，或直接填写域名。"
        case .insecureScheme: return "只支持 HTTPS 站点，请使用该网站的 HTTPS 地址。"
        case .credentials: return "网址不能包含账号或密码，请复制不含登录凭据的站点地址。"
        case .unsupportedOrigin: return "需要公开的 HTTPS 域名；不支持本机、内网、IP 地址或非标准端口。"
        }
    }
}

/// URL cleanup is local only: it neither visits a site nor infers a quota API.
/// Configuration imports still pass the unchanged CustomSiteConfig schema.
public enum SiteOnboarding {
    public static let maxInputBytes = 8_192

    public static func target(from input: String) throws -> SiteOnboardingTarget {
        guard input.utf8.count <= maxInputBytes else { throw SiteOnboardingError.tooLong }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SiteOnboardingError.emptyInput }
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"), !value.hasPrefix("//") else { throw SiteOnboardingError.invalidURL }

        let hasScheme = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        let candidate = hasScheme ? value : "https://" + value
        guard let parts = URLComponents(string: candidate), let scheme = parts.scheme else {
            throw SiteOnboardingError.invalidURL
        }
        guard scheme.lowercased() == "https" else { throw SiteOnboardingError.insecureScheme }
        guard parts.user == nil, parts.password == nil else { throw SiteOnboardingError.credentials }
        guard let host = parts.host?.lowercased(), !host.isEmpty else { throw SiteOnboardingError.invalidURL }
        guard parts.port == nil || parts.port == 443 else { throw SiteOnboardingError.unsupportedOrigin }

        // Foundation can decode escaped authority characters. Do not silently
        // turn a disguised hostname into a trusted origin for the prompt.
        guard let separator = candidate.range(of: "://") else { throw SiteOnboardingError.invalidURL }
        let authority = candidate[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("%"), parts.url != nil else { throw SiteOnboardingError.invalidURL }
        // An overflowing or empty numeric port may be reported as nil by
        // URLComponents. Nil is only the default when no port was written.
        if authority.contains(":"), parts.port != 443 { throw SiteOnboardingError.unsupportedOrigin }

        let origin = "https://" + host
        let probe = CustomSiteConfig(name: "站点", origin: origin, loginPath: "/login", pagePath: "/dashboard",
                                     mode: .json, requestPath: "/api/usage",
                                     metrics: [CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance, value: "/balance")])
        do { try probe.validate() }
        catch { throw SiteOnboardingError.unsupportedOrigin }

        let displayName = host.count <= 50 ? host : String(host.prefix(35)) + "…" + String(host.suffix(14))
        return SiteOnboardingTarget(origin: origin, displayName: displayName)
    }
}
