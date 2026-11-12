import Foundation
import BalanceCore

struct CustomCollectionTests {
    private let id = UUID(uuidString: "55555555-1234-1234-1234-123456789abc")!

    private func config() -> CustomSiteConfig {
        let base = CustomMetricCollection(path: "/data/items", filter: CustomCollectionFilter(path: "/plan/reset", equals: .string("NEVER")))
        let monthly = CustomMetricCollection(path: "/data/items", filter: CustomCollectionFilter(path: "/plan/reset", equals: .string("NEVER"), negate: true))
        return CustomSiteConfig(schemaVersion: 2, name: "订阅额度", origin: "https://quota.example.com",
            loginPath: "/login", pagePath: "/dashboard", mode: .json, requestPath: "/api/usage",
            success: CustomSiteSuccess(path: "/success", equals: .bool(true)), metrics: [
                CustomSiteMetric(id: "payg", label: "按量剩余", unit: "额度", meaning: .remaining,
                    value: "/used", total: "/plan/limit", operation: .remaining, collection: base),
                CustomSiteMetric(id: "monthly", label: "周期剩余", unit: "额度", meaning: .remaining,
                    value: "/used", total: "/plan/limit", operation: .remaining, collection: monthly)
            ])
    }
    private func item(_ reset: Any = "NEVER", used: Any = 20, limit: Any = 100) -> [String: Any] {
        ["used": used, "plan": ["reset": reset, "limit": limit]]
    }
    private func data(_ rows: Any, success: Any = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": success, "data": ["items": rows]])
    }
    private func read(_ rows: Any, config: CustomSiteConfig? = nil) throws -> BalanceReading {
        try CustomSiteParser.parseJSON(data: data(rows), config: config ?? self.config(), id: id)
    }

    func testMultipleGroupsAndOverage() throws {
        let rows = [item(used: 25, limit: 100), item("MONTHLY", used: 8, limit: 40),
                    item(used: 15, limit: 200), item("WEEKLY", used: 12, limit: 60)]
        let stamp = Date(timeIntervalSince1970: 1234)
        let result = try CustomSiteParser.parseJSON(data: data(rows), config: config(), id: id, at: stamp)
        expectEqual(result.metrics.map(\.value), ["260 额度", "80 额度"])
        expectEqual(result.metrics[0].remainingFraction!, 260.0 / 300.0, accuracy: 1e-12)
        expectEqual(result.metrics[1].remainingFraction, 0.8)
        expectEqual(result.service, .custom(id)); expectEqual(result.fetchedAt, stamp)
        expectEqual(result.source, "自定义站点（JSON）")
        // Order is irrelevant and a second subscription must not be ignored.
        expectEqual(try read(Array(rows.reversed())).metrics, result.metrics)
        let overage = try read([item(used: 150, limit: 100), item(used: 80, limit: 100)])
        expectEqual(overage.metrics[0].value, "-30 额度")
        expectEqual(overage.metrics[0].remainingFraction, 0)
        var scaled = config(); scaled.metrics[0].multiplier = 1000
        expectEqual(try read(rows, config: scaled).metrics[0].value, "260,000 额度")
        expectEqual(try read([item(used: "1,000", limit: "2,000")]).metrics[0].value, "1,000 额度")
    }

    func testExplicitEmptyAndValueAggregation() throws {
        let empty = try read([])
        expectEqual(empty.metrics.map(\.value), ["0 额度", "0 额度"])
        expectTrue(empty.metrics.allSatisfy { $0.remainingFraction == nil })
        let onlyMonthly = try read([item("MONTHLY")])
        expectEqual(onlyMonthly.metrics[0].value, "0 额度")
        expectNil(onlyMonthly.metrics[0].remainingFraction)
        expectEqual(onlyMonthly.metrics[1].value, "80 额度")
        let zero = try read([item(used: 0, limit: 0)])
        expectEqual(zero.metrics[0].value, "0 额度")
        expectNil(zero.metrics[0].remainingFraction)
        var c = config()
        c.metrics = [CustomSiteMetric(id: "used", label: "累计使用", unit: "额度", meaning: .used,
            value: "/used", collection: CustomMetricCollection(path: "/data/items"))]
        expectEqual(try read([item(used: 2), item("MONTHLY", used: 3)], config: c).metrics[0].value, "5 额度")
        expectEqual(try read([], config: c).metrics[0].value, "0 额度")
        expectNil(try read([], config: c).metrics[0].remainingFraction)
        expectEqual(try read(Array(repeating: item(used: 1), count: 1000), config: c).metrics[0].value, "1,000 额度")
        expectThrowsError(try read(Array(repeating: item(used: 1), count: 1001), config: c))
    }

    func testInvalidResponsesNeverBecomeZero() throws {
        for success: Any in [false, 1, "true", NSNull()] {
            expectThrowsError(try CustomSiteParser.parseJSON(data: data([], success: success), config: config(), id: id))
        }
        for payload in [#"{"success":true,"data":{}}"#, #"{"success":true}"#,
                        #"{"data":{"items":[]}}"#] {
            expectThrowsError(try CustomSiteParser.parseJSON(data: Data(payload.utf8), config: config(), id: id))
        }
        for wrong: Any in [NSNull(), [:], 0, "[]", true] { expectThrowsError(try read(wrong)) }
        for wrongRow: Any in [NSNull(), [], "row", 0, true] { expectThrowsError(try read([wrongRow])) }
        // Negation must never turn absent or wrong-typed filter values into matches.
        for row: [String: Any] in [[:], ["plan": NSNull()], ["plan": [:]],
                                  item(NSNull()), item(1), item(true), item([]), item([:])] {
            expectThrowsError(try read([row]))
        }
        for invalid: Any in [NSNull(), true, false, [], [:], "", "loading", "1e999", -1, 9_007_199_254_740_992.0] {
            expectThrowsError(try read([item(used: invalid)]))
            expectThrowsError(try read([item(limit: invalid)]))
        }
        expectThrowsError(try read([["plan": ["reset": "NEVER", "limit": 100]]]))
        expectThrowsError(try read([["used": 0, "plan": ["reset": "NEVER"]]]))
        let bound = 9_007_199_254_740_991.0
        expectThrowsError(try read([item(used: bound, limit: bound), item(used: 1, limit: 1)]))
        var scaled = config(); scaled.metrics[0].multiplier = 1e9
        expectThrowsError(try read([item(used: 0, limit: bound)], config: scaled))
        // A negative matched amount cannot cancel out another row to pass validation.
        expectThrowsError(try read([item(used: -1), item(used: 2)]))
        expectThrowsError(try read([item(limit: -1), item(limit: 200)]))
    }

    func testStrictVersionAndNestedConfiguration() throws {
        let c = config()
        let encoded = try JSONEncoder().encode(c)
        expectEqual(try CustomSiteConfig.decode(data: encoded), c)
        expectEqual(try JSONDecoder().decode(CustomSiteConfig.self, from: encoded), c)
        var bad = c; bad.schemaVersion = 1
        expectThrowsError(try bad.validate())
        expectThrowsError(try CustomSiteConfig.decode(data: JSONEncoder().encode(bad)))
        bad = c; bad.schemaVersion = 3; expectThrowsError(try bad.validate())
        bad = c; bad.success = nil; expectThrowsError(try bad.validate())
        bad = c; bad.mode = .dom; bad.requestPath = nil; bad.success = nil
        expectThrowsError(try bad.validate())
        bad = c; bad.metrics[0].unit = "%"; expectThrowsError(try bad.validate())
        for pointer in ["items", "/bad~2", ""] {
            bad = c; bad.metrics[0].collection?.path = pointer; expectThrowsError(try bad.validate())
            bad = c; bad.metrics[0].collection?.filter?.path = pointer; expectThrowsError(try bad.validate())
        }
        bad = c; bad.metrics[0].collection?.filter?.equals = .number(.infinity); expectThrowsError(try bad.validate())
        bad = c; bad.metrics[0].collection?.filter?.equals = .string(String(repeating: "x", count: 101)); expectThrowsError(try bad.validate())
        var root = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let originalRows = root["metrics"] as! [[String: Any]]
        for level in ["metric", "collection", "filter"] {
            var rows = originalRows
            if level == "metric" { rows[0]["expression"] = "sum(items)" }
            else {
                var collection = rows[0]["collection"] as! [String: Any]
                if level == "collection" { collection["script"] = "synthetic" }
                else {
                    var filter = collection["filter"] as! [String: Any]
                    filter["regex"] = ".*"; collection["filter"] = filter
                }
                rows[0]["collection"] = collection
            }
            root["metrics"] = rows
            let data = try JSONSerialization.data(withJSONObject: root)
            expectThrowsError(try CustomSiteConfig.decode(data: data))
            expectThrowsError(try JSONDecoder().decode(CustomSiteConfig.self, from: data))
        }
        for level in ["collection", "filter", "negate"] {
            var rows = originalRows
            if level == "collection" { rows[0]["collection"] = NSNull() }
            else {
                var collection = rows[0]["collection"] as! [String: Any]
                if level == "filter" { collection["filter"] = NSNull() }
                else {
                    var filter = collection["filter"] as! [String: Any]
                    filter["negate"] = NSNull(); collection["filter"] = filter
                }
                rows[0]["collection"] = collection
            }
            root["metrics"] = rows
            let data = try JSONSerialization.data(withJSONObject: root)
            expectThrowsError(try CustomSiteConfig.decode(data: data))
            expectThrowsError(try JSONDecoder().decode(CustomSiteConfig.self, from: data))
        }
        var rows = originalRows
        var collection = rows[0]["collection"] as! [String: Any]
        var filter = collection["filter"] as! [String: Any]; filter.removeValue(forKey: "negate")
        collection["filter"] = filter; rows[0]["collection"] = collection; root["metrics"] = rows
        let defaulted = try CustomSiteConfig.decode(data: JSONSerialization.data(withJSONObject: root))
        expectEqual(defaulted.metrics[0].collection?.filter?.negate, false)
        filter["negate"] = "true"; collection["filter"] = filter; rows[0]["collection"] = collection; root["metrics"] = rows
        expectThrowsError(try CustomSiteConfig.decode(data: JSONSerialization.data(withJSONObject: root)))
        // Version 1 scalar rules and scalar positive-total requirement remain unchanged.
        var legacy = c; legacy.schemaVersion = 1; legacy.metrics = [CustomSiteMetric(id: "left", label: "剩余", unit: "额度",
            meaning: .remaining, value: "/used", total: "/total", operation: .remaining)]
        expectEqual(try CustomSiteConfig.decode(data: JSONEncoder().encode(legacy)), legacy)
        let scalar = Data(#"{"success":true,"used":20,"total":100}"#.utf8)
        expectEqual(try CustomSiteParser.parseJSON(data: scalar, config: legacy, id: id).metrics[0].value, "80 额度")
        expectThrowsError(try CustomSiteParser.parseJSON(data: Data(#"{"success":true,"used":0,"total":0}"#.utf8), config: legacy, id: id))
    }

    func testTypedFilterAndEscapedPointers() throws {
        var c = config(); c.metrics = [c.metrics[0]]
        c.metrics[0].collection?.filter = CustomCollectionFilter(path: "/eligible", equals: .bool(true))
        var yes = item(); yes["eligible"] = true
        var no = item(); no["eligible"] = false
        expectEqual(try read([yes, no], config: c).metrics[0].value, "80 额度")
        yes["eligible"] = 1; expectThrowsError(try read([yes], config: c))
        c.metrics[0].collection?.filter = CustomCollectionFilter(path: "/kind", equals: .number(2))
        var numeric = item(); numeric["kind"] = 2
        expectEqual(try read([numeric], config: c).metrics[0].value, "80 额度")
        numeric["kind"] = true; expectThrowsError(try read([numeric], config: c))
        c.metrics[0].collection?.filter = nil
        c.metrics[0].value = "/a~1b/~0used"
        expectEqual(try read([["a/b": ["~used": 30], "plan": ["limit": 100]]], config: c).metrics[0].value, "70 额度")
    }
}
