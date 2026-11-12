import Foundation
import BalanceCore

struct CustomSiteTests {
    private let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    private func config(mode: CustomSiteMode = .json) -> CustomSiteConfig {
        CustomSiteConfig(name: "我的额度", origin: "https://relay.example.com", loginPath: "/login", pagePath: "/dashboard",
                         mode: mode, requestPath: mode == .json ? "/api/usage" : nil,
                         success: mode == .json ? CustomSiteSuccess(path: "/success", equals: .bool(true)) : nil,
                         metrics: [CustomSiteMetric(id: "balance", label: "余额", unit: "USD", meaning: .balance,
                                                    value: mode == .json ? "/data/balance" : "#balance")])
    }

    func testStrictSchemaAndDefaults() throws {
        let json = """
        {"schemaVersion":1,"name":"我的额度","origin":"https://relay.example.com","loginPath":"/login","pagePath":"/dashboard","mode":"json","requestPath":"/api/usage","success":{"path":"/success","equals":true},"metrics":[{"id":"balance","label":"余额","unit":"USD","meaning":"balance","value":"/data/balance"}]}
        """
        let decoded = try CustomSiteConfig.decode(data: Data(json.utf8))
        expectEqual(decoded, config())
        expectEqual(decoded.loginURL.absoluteString, "https://relay.example.com/login")
        expectEqual(decoded.requestURL?.absoluteString, "https://relay.example.com/api/usage")
        for field in ["headers", "cookie", "token", "script", "method", "body", "account"] {
            var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            object[field] = "synthetic"
            expectThrowsError(try CustomSiteConfig.decode(data: JSONSerialization.data(withJSONObject: object)))
            expectThrowsError(try JSONDecoder().decode(CustomSiteConfig.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var metrics = object["metrics"] as! [[String: Any]]
        metrics[0]["expression"] = "value * 2"; object["metrics"] = metrics
        expectThrowsError(try CustomSiteConfig.decode(data: JSONSerialization.data(withJSONObject: object)))
        expectThrowsError(try CustomSiteConfig.decode(data: Data(repeating: 32, count: 65_537)))
        expectThrowsError(try CustomSiteConfig.decode(data: Data("{}".utf8)))
        expectThrowsError(try CustomSiteConfig.decode(data: Data("[]".utf8)))
        var invalid = config(); invalid.schemaVersion = 99
        expectThrowsError(try invalid.validate())
        invalid = config(); invalid.metrics += invalid.metrics
        expectThrowsError(try invalid.validate())
        invalid = config(); invalid.metrics[0].multiplier = .infinity
        expectThrowsError(try invalid.validate())
    }

    func testRestrictedOriginsPathsAndSelectors() throws {
        let origins = ["http://relay.example.com", "https://localhost", "https://foo.local", "https://host.internal",
                       "https://127.0.0.1", "https://2130706433", "https://[::1]", "https://a:b@relay.example.com",
                       "https://relay.example.com:8443", "https://relay.example.com:999999999999999999999999",
                       "https://relay.example.com:", "https://relay.example.com:443x",
                       "https://relay.example.com/path", "https://relay.example.com?q=1",
                       "https://relay.example.com#x", "https://relay.example.com\\evil", "https://-a.example.com"]
        for origin in origins {
            var c = config(); c.origin = origin
            expectThrowsError(try c.validate())
            expectThrowsError(try CustomSiteConfig.decode(data: JSONEncoder().encode(c)))
        }
        for origin in ["https://relay.example.com", "https://relay.example.com:443", "https://relay.example.com:443/"] {
            var c = config(); c.origin = origin
            try c.validate()
            expectEqual(try CustomSiteConfig.decode(data: JSONEncoder().encode(c)).origin, origin)
        }
        let paths = ["https://other.example.com/quota", "//other.example.com/quota", "/api?token=secret", "/api#x",
                     "/api/../quota", "/api/%2e%2e/quota", "/v1/chat/completions", "/v1/responses",
                     "/api/payment", "/api/recharge", "/api/delete", "/api/logout", "/bad path"]
        for path in paths { var c = config(); c.requestPath = path; expectThrowsError(try c.validate()) }
        var c = config(mode: .dom); c.requestPath = "/api/usage"
        expectThrowsError(try c.validate())
        c = config(mode: .dom); c.metrics[0].value = "body; fetch('bad')"
        expectThrowsError(try c.validate())
        c = config(); c.metrics[0].value = "/bad~3pointer"
        expectThrowsError(try c.validate())
        c = config(); c.metrics[0].value = "data.balance"
        expectThrowsError(try c.validate())
        c = config(); c.metrics[0].total = "/data/total"; c.metrics[0].operation = .remaining
        expectThrowsError(try c.validate()) // operation must explicitly declare remaining semantics
    }

    func testJSONValuesUnitsAndRemaining() throws {
        let date = Date(timeIntervalSince1970: 100)
        let reading = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"balance":"1,234.50"}}"#.utf8), config: config(), id: id, at: date)
        expectEqual(reading.service, .custom(id)); expectEqual(reading.fetchedAt, date)
        expectEqual(reading.metrics[0].value, "1,234.5 USD"); expectNil(reading.metrics[0].remainingFraction)
        expectEqual(reading.source, "自定义站点（JSON）")
        var c = config()
        c.metrics = [CustomSiteMetric(id: "left", label: "剩余", unit: "token", meaning: .remaining,
                                      value: "/data/used", total: "/data/total", operation: .remaining, multiplier: 1000)]
        let remaining = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"used":25,"total":100}}"#.utf8), config: c, id: id)
        expectEqual(remaining.metrics[0].value, "75,000 token")
        expectEqual(remaining.metrics[0].remainingFraction, 0.75)
        let overage = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"used":110,"total":100}}"#.utf8), config: c, id: id)
        expectEqual(overage.metrics[0].value, "-10,000 token"); expectEqual(overage.metrics[0].remainingFraction, 0)
        c.metrics = [CustomSiteMetric(id: "week", label: "每周剩余", unit: "%", meaning: .remaining, value: "/data/ratio", multiplier: 100)]
        let percentage = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"ratio":0.87}}"#.utf8), config: c, id: id)
        expectEqual(percentage.metrics[0].value, "87%"); expectEqual(percentage.metrics[0].remainingFraction, 0.87)
        c.metrics[0].value = "/data/a~1b/~0key/0"
        let escaped = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"a/b":{"~key":[0.5]}}}"#.utf8), config: c, id: id)
        expectEqual(escaped.metrics[0].value, "50%")
    }

    func testInvalidDataNeverBecomesZero() throws {
        for json in [#"{"success":false,"data":{"balance":0}}"#, #"{"success":1,"data":{"balance":0}}"#,
                     #"{"success":"true","data":{"balance":0}}"#, #"{"success":true,"data":{}}"#,
                     #"{"success":true,"data":{"balance":null}}"#, #"{"success":true,"data":{"balance":true}}"#,
                     #"{"success":true,"data":{"balance":""}}"#, #"{"success":true,"data":{"balance":"unlimited"}}"#,
                     #"{"success":true,"data":{"balance":"1,23"}}"#, #"{"success":true,"data":{"balance":"1e999"}}"#,
                     #"{"success":true,"data":{"balance":9007199254740992}}"#, #"{"success":true,"data":{"balance":"123 days 45 USD"}}"#] {
            expectThrowsError(try CustomSiteParser.parseJSON(data: Data(json.utf8), config: config(), id: id))
        }
        expectThrowsError(try CustomSiteParser.parseJSON(data: Data(repeating: 32, count: CustomSiteParser.maxResponseBytes + 1), config: config(), id: id))
        let zero = try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"balance":0}}"#.utf8), config: config(), id: id)
        expectEqual(zero.metrics[0].value, "0 USD")
        var c = config(); c.metrics[0].total = "/data/total"
        expectThrowsError(try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"data":{"balance":0,"total":0}}"#.utf8), config: c, id: id))
    }

    func testPercentSemanticsPreserveOverage() throws {
        var c = config()
        c.metrics = [CustomSiteMetric(id: "week", label: "每周剩余", unit: "%", meaning: .remaining, value: "/data/balance")]
        func json(_ value: Double) -> Data { Data("{\"success\":true,\"data\":{\"balance\":\(value)}}".utf8) }
        expectThrowsError(try CustomSiteParser.parseJSON(data: json(187), config: c, id: id))
        expectEqual(try CustomSiteParser.parseJSON(data: json(100), config: c, id: id).metrics[0].value, "100%")
        let overage = try CustomSiteParser.parseJSON(data: json(-10), config: c, id: id)
        expectEqual(overage.metrics[0].value, "-10%"); expectEqual(overage.metrics[0].remainingFraction, 0)
        c.metrics[0].multiplier = 100
        expectThrowsError(try CustomSiteParser.parseJSON(data: json(1.01), config: c, id: id))
        c.metrics[0].multiplier = 1; c.metrics[0].meaning = .used; c.metrics[0].label = "已用"
        expectThrowsError(try CustomSiteParser.parseJSON(data: json(-0.1), config: c, id: id))
        let used = try CustomSiteParser.parseJSON(data: json(110), config: c, id: id)
        expectEqual(used.metrics[0].value, "110%"); expectNil(used.metrics[0].remainingFraction)
        expectEqual(try CustomSiteParser.parseJSON(data: json(0), config: c, id: id).metrics[0].value, "0%")
    }

    func testDOMRequiresExactNumericText() throws {
        var c = config(mode: .dom); c.metrics[0].prefix = "$"
        let reading = try CustomSiteParser.parseDOM(values: ["#balance": "  $1,234.50  "], config: c, id: id)
        expectEqual(reading.metrics[0].value, "1,234.5 USD")
        expectEqual(reading.source, "自定义站点（网页）")
        for text in ["loading", "123", "-$12", "$12 / 200", "$NaN", "$--", String(repeating: "0", count: 4097)] {
            expectThrowsError(try CustomSiteParser.parseDOM(values: ["#balance": text], config: c, id: id))
        }
        expectThrowsError(try CustomSiteParser.parseDOM(values: [:], config: c, id: id))
        expectThrowsError(try CustomSiteParser.parseDOM(values: ["#balance": "1"], config: config(), id: id))
        c.metrics[0].prefix = ""; c.metrics[0].suffix = "USD"
        expectEqual(try CustomSiteParser.parseDOM(values: ["#balance": "12.5 USD"], config: c, id: id).metrics[0].value, "12.5 USD")
    }

    func testServiceIdentifierCompatibility() throws {
        for service in ServiceID.allCases {
            expectEqual(try JSONDecoder().decode(ServiceID.self, from: Data("\"\(service.rawValue)\"".utf8)), service)
            expectEqual(String(data: try JSONEncoder().encode(service), encoding: .utf8), "\"\(service.rawValue)\"")
        }
        let custom = ServiceID.custom(id)
        expectEqual(custom.customUUID, id)
        expectEqual(ServiceID(rawValue: "custom:" + id.uuidString), custom)
        expectEqual(try JSONDecoder().decode(ServiceID.self, from: JSONEncoder().encode(custom)), custom)
        expectNil(ServiceID(rawValue: "unknown")); expectNil(ServiceID(rawValue: "custom:bad"))
        expectNil(ServiceID(rawValue: "custom:00000000-0000-0000-0000-000000000000"))
        expectThrowsError(try JSONDecoder().decode(ServiceID.self, from: Data(#""other""#.utf8)))
        expectEqual(ServiceID.allCases.count, 3)
    }

    func testRepositoryPersistenceAndErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-custom-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CustomSiteRepository(url: directory.appendingPathComponent("sites.json"))
        expectEqual(try repository.load(), [])
        let record = CustomSiteRecord(id: id, config: config())
        try repository.save([record])
        expectEqual(try repository.load(), [record])
        let mode = try FileManager.default.attributesOfItem(atPath: repository.url.path)[.posixPermissions] as? NSNumber
        expectEqual(mode?.intValue, 0o600)
        expectThrowsError(try repository.save([record, record]))
        expectEqual(try repository.load(), [record])
        expectThrowsError(try repository.save((0...12).map { _ in CustomSiteRecord(config: config()) }))
        try Data("broken".utf8).write(to: repository.url)
        expectThrowsError(try repository.load())
        let poisoned = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        var object = poisoned; var configObject = object["config"] as! [String: Any]
        configObject["script"] = "synthetic"; object["config"] = configObject
        try JSONSerialization.data(withJSONObject: [object]).write(to: repository.url)
        expectThrowsError(try repository.load())
        try FileManager.default.removeItem(at: repository.url)
        let target = directory.appendingPathComponent("target.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: repository.url, withDestinationURL: target)
        expectThrowsError(try repository.save([record])); expectThrowsError(try repository.load())
        expectEqual(try String(contentsOf: target), "untouched")
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        expectThrowsError(try CustomSiteRecord(id: zero, config: config()).validate())
    }

    func testDynamicSchedulesAndFreshTestAdoption() throws {
        var coordinator = ServiceRefreshCoordinator()
        let custom = ServiceID.custom(id)
        coordinator.updateNetwork(.online, at: 0)
        coordinator.setEnabled(true, for: custom, at: 0)
        let first = coordinator.beginDue(at: 2)
        expectEqual(first.map(\.service), [custom])
        coordinator.trigger(.manual, at: 2)
        expectTrue(coordinator.beginDue(at: 2).isEmpty)
        expectFalse(coordinator.enableWithFreshReading(for: custom, at: 2))
        coordinator.finish(first[0], at: 3, retrySoon: false)
        coordinator.trigger(.wake, at: 10)
        coordinator.trigger(.connectionAvailable, at: 11)
        expectTrue(coordinator.beginDue(at: 12).isEmpty)
        let afterWake = coordinator.beginDue(at: 13)
        expectEqual(afterWake.map(\.service), [custom])
        coordinator.finish(afterWake[0], at: 14, retrySoon: false)
        coordinator.updateNetwork(.offline, at: 20)
        coordinator.trigger(.wake, at: 21)
        expectTrue(coordinator.beginDue(at: 100).isEmpty)
        coordinator.updateNetwork(.online, at: 100)
        let recovery = coordinator.beginDue(at: 102)
        expectEqual(recovery.map(\.service), [custom])
        coordinator.finish(recovery[0], at: 103, retrySoon: false)
        coordinator.setEnabled(false, for: custom, at: 104)
        expectTrue(coordinator.enableWithFreshReading(for: custom, at: 105))
        expectTrue(coordinator.beginDue(at: 105).isEmpty)
        coordinator.trigger(.startup, at: 106)
        expectTrue(coordinator.beginDue(at: 106).isEmpty)
        expectEqual(coordinator.nextDueAt, 405)
        expectTrue(coordinator.enableWithFreshReading(for: custom, at: 107))
        expectTrue(coordinator.beginDue(at: 107).isEmpty)
        expectEqual(coordinator.nextDueAt, 407)
        let periodic = coordinator.beginDue(at: 407)
        expectEqual(periodic.map(\.service), [custom])
        coordinator.setEnabled(false, for: custom, at: 408)
        expectFalse(coordinator.accepts(periodic[0]))
    }
}
