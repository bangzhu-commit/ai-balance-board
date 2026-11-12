import Foundation
import BalanceCore

struct SiteOnboardingTests {
    func testPageLinksNormalizeToTheSameOrigin() throws {
        let expected = SiteOnboardingTarget(origin: "https://relay.example.com", displayName: "relay.example.com")
        for input in [
            "https://relay.example.com", "https://relay.example.com/", "https://relay.example.com/login",
            "https://relay.example.com/dashboard/usage", " HTTPS://RELAY.EXAMPLE.COM:443/dashboard \n",
            "relay.example.com", "relay.example.com/login", "relay.example.com:443/dashboard",
            "relay.example.com/login?redirect=https://other.example.com/",
            "https://relay.example.com/dashboard/%E9%A2%9D%E5%BA%A6"
        ] {
            expectEqual(try SiteOnboarding.target(from: input), expected)
        }
    }

    func testSensitiveComponentsAreDiscardedWithoutEcho() throws {
        let marker = "synthetic-secret-123"
        let target = try SiteOnboarding.target(from: "https://relay.example.com/account/\(marker)?token=\(marker)&redirect=https://other.example.com#\(marker)")
        expectEqual(target.origin, "https://relay.example.com")
        expectEqual(target.displayName, "relay.example.com")
        expectFalse(String(describing: target).contains(marker))
        expectFalse(target.origin.contains("?"))
        expectFalse(target.origin.contains("#"))
        for input in ["https://person:\(marker)@relay.example.com/", "https://127.0.0.1/?token=\(marker)", "http://relay.example.com/\(marker)"] {
            do {
                _ = try SiteOnboarding.target(from: input)
                expectTrue(false)
            } catch {
                expectFalse(error.localizedDescription.contains(marker))
                expectFalse(String(describing: error).contains(marker))
            }
        }
    }

    func testUnsupportedAndAmbiguousAddressesAreRejected() {
        for input in [
            "http://relay.example.com", "ftp://relay.example.com", "file:///tmp/config.json", "javascript:alert(1)",
            "https:relay.example.com", "//relay.example.com", "person@relay.example.com", "https://person@relay.example.com",
            "https://person:password@relay.example.com", "https://localhost", "https://service.localhost",
            "https://router.local", "https://service.internal", "https://router.lan", "https://router.home",
            "https://192.168.1.1", "https://127.0.0.1", "https://[::1]", "https://[2001:db8::1]",
            "https://2130706433", "https://relay.example.com:8443", "relay.example.com:80", "https://-bad.example.com",
            "https://relay.example.com:999999999999999999999999", "https://relay.example.com:", "https://relay.example.com:443x",
            "https://relay.example.com.", "https://%72elay.example.com", "https://relay.example.com\\@other.example.com",
            "https://relay.example.com\nhttps://other.example.com", "this is not a URL", "<https://relay.example.com>",
            "https://", "", " \n\t"
        ] {
            expectThrowsError(try SiteOnboarding.target(from: input))
        }
        expectThrowsError(try SiteOnboarding.target(from: String(repeating: "x", count: SiteOnboarding.maxInputBytes + 1)))
        expectThrowsError(try SiteOnboarding.target(from: String(repeating: "站", count: SiteOnboarding.maxInputBytes / 2)))
    }

    func testDefaultNameRemainsWithinConfigLimits() throws {
        let host = String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 40) + ".example.com"
        let target = try SiteOnboarding.target(from: "https://" + host + "/dashboard")
        expectEqual(target.origin, "https://" + host)
        expectEqual(target.displayName.count, 50)
        expectTrue(target.displayName.hasSuffix("example.com"))
        let config = CustomSiteConfig(name: target.displayName, origin: target.origin, loginPath: "/login", pagePath: "/dashboard",
                                      mode: .json, requestPath: "/api/usage",
                                      metrics: [CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance, value: "/balance")])
        try config.validate()
        expectTrue(true)
    }
}
