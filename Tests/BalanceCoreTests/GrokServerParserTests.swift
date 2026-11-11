import Foundation
@testable import BalanceCore

final class GrokServerParserTests {
    private let now = Date(timeIntervalSince1970: 1_794_355_200) // 2026-11-11 00:00:00 UTC
    private func fixture(percent: String = "20.109194", extra: String = "") -> Data {
        Data("""
        {"usagePercent":\(percent),"hasNonZeroIncludedLimit":true\(extra)}
        """.utf8)
    }

    func testServerPercentageAndFetchedTimeWithoutClientCache() throws {
        let reading = try GrokServerParser.parse(data: fixture(extra: #", "nextResetTimestampUtc":"2026-11-12T00:00:00Z", "cursorUsage":{"usagePercent":99}, "onDemand":{"usedCents":500}"#), now: now)
        expectEqual(reading.service, .grok)
        expectEqual(reading.metrics.count, 1)
        expectEqual(reading.metrics[0].value, "79.9%")
        expectEqual(reading.metrics[0].remainingFraction!, 0.79890806, accuracy: 0.0000001)
        expectEqual(reading.metrics[0].label, "每周剩余")
        expectEqual(reading.metrics[0].resetsAt, Date(timeIntervalSince1970: 1_794_441_600))
        expectEqual(reading.fetchedAt, now)
        expectEqual(reading.source, "Grok Bot 服务器接口")
    }

    func testProtoJSONDefaultsNullsAndNumericStrings() throws {
        let reading = try GrokServerParser.parse(data: fixture(percent: #""2.5e1""#, extra: #", "nextResetTimestampUtc":null, "sandTrialExpiresAt":null, "isTeamSeat":null, "isUnified":null, "usesPooledEnterpriseAllowance":null"#), now: now)
        expectEqual(reading.metrics[0].value, "75%")
        expectEqual(reading.metrics[0].label, "每周剩余")
        expectNil(reading.metrics[0].resetsAt)
        let missingReset = try GrokServerParser.parse(data: fixture(percent: "0"), now: now)
        expectEqual(missingReset.metrics[0].value, "100%")
        expectNil(missingReset.metrics[0].resetsAt)
        let overage = try GrokServerParser.parse(data: fixture(percent: "125.5"), now: now)
        expectEqual(overage.metrics[0].value, "0%")
        expectEqual(overage.metrics[0].remainingFraction, 0)
    }

    func testMissingOrInvalidUsageNeverInventsFullRemaining() {
        for body in ["{}", #"{"hasNonZeroIncludedLimit":true}"#, #"{"usagePercent":0}"#, #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#, #"{"usagePercent":0,"hasNonZeroIncludedLimit":null}"#] {
            expectThrowsError(try GrokServerParser.parse(data: Data(body.utf8), now: now))
        }
        for invalid in ["null", "true", "-1", "1e999", #""NaN""#, #""Infinity""#, #""20trailing""#, #""""#] {
            expectThrowsError(try GrokServerParser.parse(data: fixture(percent: invalid), now: now))
        }
        expectThrowsError(try GrokServerParser.parse(data: fixture(extra: #", "isUnified":"true""#), now: now))
        expectThrowsError(try GrokServerParser.parse(data: Data("not JSON".utf8), now: now))
        expectThrowsError(try GrokServerParser.parse(data: Data(count: 1_048_576), now: now))
    }

    func testRFC3339FractionsOffsetsAndInvalidDates() throws {
        let fractional = try GrokServerParser.parse(data: fixture(extra: #", "nextResetTimestampUtc":"2026-11-12T08:00:00.123456789+08:00""#), now: now)
        expectEqual(fractional.metrics[0].resetsAt!.timeIntervalSince1970, 1_794_441_600.123456789, accuracy: 0.000001)
        let negativeOffset = try GrokServerParser.parse(data: fixture(extra: #", "nextResetTimestampUtc":"2026-11-11T19:00:00-05:00""#), now: now)
        expectEqual(negativeOffset.metrics[0].resetsAt, Date(timeIntervalSince1970: 1_794_441_600))
        for timestamp in ["", "tomorrow", "2026-11-11T00:00:00Z", "2026-11-10T23:59:59Z", "2027-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-12T24:00:00Z", "2026-11-12T00:00:00+24:00", "2026-11-12"] {
            let extra = ", \"nextResetTimestampUtc\":\"\(timestamp)\""
            expectThrowsError(try GrokServerParser.parse(data: fixture(extra: extra), now: now))
        }
        expectThrowsError(try GrokServerParser.parse(data: fixture(extra: #", "nextResetTimestampUtc":{"seconds":1794441600}"#), now: now))
    }

    func testSharedAndTeamScopesStayExplicitAndPooledIsUnavailable() throws {
        let shared = try GrokServerParser.parse(data: fixture(extra: #", "isUnified":true"#), now: now)
        expectEqual(shared.metrics[0].label, "共享周额度剩余")
        let team = try GrokServerParser.parse(data: fixture(extra: #", "isUnified":true, "isTeamSeat":true"#), now: now)
        expectEqual(team.metrics[0].label, "团队席位 · 共享周额度剩余")
        let teamOnly = try GrokServerParser.parse(data: fixture(extra: #", "isTeamSeat":true"#), now: now)
        expectEqual(teamOnly.metrics[0].label, "团队席位 · 每周剩余")
        expectThrowsError(try GrokServerParser.parse(data: fixture(extra: #", "usesPooledEnterpriseAllowance":true"#), now: now))
    }

    func testTrialDeadlineDoesNotAssertActiveTrial() throws {
        let reading = try GrokServerParser.parse(data: fixture(extra: #", "sandTrialExpiresAt":"2026-11-12T08:00:00Z""#), now: now)
        expectEqual(reading.metrics.count, 2)
        expectEqual(reading.metrics[0].label, "额度剩余")
        expectEqual(reading.metrics[1].id, "trial-expiry")
        expectEqual(reading.metrics[1].label, "试用截止")
        expectFalse(reading.metrics[1].value.isEmpty)
        expectNil(reading.metrics[1].remainingFraction)
        expectNil(reading.metrics[1].resetsAt)
        let shared = try GrokServerParser.parse(data: fixture(extra: #", "sandTrialExpiresAt":"2026-11-12T08:00:00Z", "isUnified":true"#), now: now)
        expectEqual(shared.metrics[0].label, "共享额度剩余")
        expectThrowsError(try GrokServerParser.parse(data: fixture(extra: #", "sandTrialExpiresAt":"invalid""#), now: now))
    }

    func testHistoricalTrialDeadlineDoesNotInvalidateActivePaidQuota() throws {
        for historicalExpiry in ["2026-11-10T00:00:00Z", "2026-11-11T00:00:00Z"] {
            let extra = ", \"nextResetTimestampUtc\":\"2026-11-12T00:00:00Z\", \"sandTrialExpiresAt\":\"\(historicalExpiry)\""
            let reading = try GrokServerParser.parse(data: fixture(extra: extra), now: now)
            expectEqual(reading.metrics.count, 1)
            expectEqual(reading.metrics[0].label, "每周剩余")
            expectEqual(reading.metrics[0].value, "79.9%")
        }
        let shared = try GrokServerParser.parse(data: fixture(extra: #", "sandTrialExpiresAt":"2026-11-10T00:00:00Z", "isUnified":true"#), now: now)
        expectEqual(shared.metrics.count, 1)
        expectEqual(shared.metrics[0].label, "共享周额度剩余")
    }
}
