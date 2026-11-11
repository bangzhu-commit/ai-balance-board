import Foundation
@testable import BalanceCore

final class CodexParserTests {
    private func parse(_ json: String) throws -> BalanceReading {
        try CodexParser.parse(Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 123))
    }

    func testWeeklyPrimaryAndIndependentCreditBalance() throws {
        let reading = try parse(#"{"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1794380088},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"2500.0000000000"}}}}"#)
        expectEqual(reading.service, .codex)
        expectEqual(reading.metrics.map(\.label), ["每周剩余", "额度余额"])
        expectEqual(reading.metrics.map(\.value), ["24%", "2,500"])
        expectEqual(reading.metrics[0].remainingFraction, 0.24)
        expectEqual(reading.metrics[0].resetsAt, Date(timeIntervalSince1970: 1794380088))
        expectNil(reading.metrics[1].remainingFraction)
        expectEqual(reading.fetchedAt, Date(timeIntervalSince1970: 123))
    }

    func testMultiBucketViewWinsOverLegacyAndKeepsAllWindows() throws {
        let reading = try parse(#"{"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"b":{"limitName":"另一模型","primary":{"usedPercent":50,"windowDurationMins":90}},"a":{"limitId":"codex","primary":{"usedPercent":19.25,"windowDurationMins":300},"secondary":{"usedPercent":10,"windowDurationMins":10080}}}}}"#)
        expectEqual(reading.metrics.map(\.id), ["a.primary", "a.secondary", "b.primary"])
        expectEqual(reading.metrics.map(\.value), ["80.75%", "90%", "50%"])
        expectEqual(reading.metrics.map(\.label), ["codex · 5 小时剩余", "codex · 每周剩余", "另一模型 · 90 分钟剩余"])
    }

    func testNullDoesNotBecomeZero() throws {
        let reading = try parse(#"{"result":{"rateLimitsByLimitId":null,"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null},"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}}"#)
        expectEqual(reading.metrics.map(\.value), ["暂不可用", "暂不可用"])
        expectTrue(reading.metrics.allSatisfy { $0.remainingFraction == nil && $0.resetsAt == nil })
    }

    func testEmptyMapFallsBackAndPercentageIsClamped() throws {
        let reading = try parse(#"{"result":{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":101,"windowDurationMins":1440},"secondary":{"usedPercent":-1,"windowDurationMins":2880}}}}"#)
        expectEqual(reading.metrics.map(\.value), ["0%", "100%"])
        expectEqual(reading.metrics.map(\.label), ["每日剩余", "2 天剩余"])
    }

    func testUnlimitedCreditsAndDecimalCredits() throws {
        let unlimited = try parse(#"{"result":{"rateLimits":{"credits":{"unlimited":true,"balance":null}}}}"#)
        expectEqual(unlimited.metrics[0].value, "不限额")
        let fractional = try parse(#"{"result":{"rateLimits":{"credits":{"unlimited":false,"balance":"12.375"}}}}"#)
        expectEqual(fractional.metrics[0].value, "12.375")
        let invalid = try parse(#"{"result":{"rateLimits":{"credits":{"unlimited":false,"balance":"2500secret"}}}}"#)
        expectEqual(invalid.metrics[0].value, "暂不可用")
    }

    func testMissingOrMalformedResponsesFailWithoutEchoingRawError() throws {
        for json in ["not JSON", "{}", #"{"result":{}}"#, #"{"result":{"rateLimits":{"primary":null,"secondary":null,"credits":null}}}"#, #"{"result":{"rateLimits":{"primary":{"usedPercent":"76"}}}}"#] {
            expectThrowsError(try parse(json))
        }
        expectThrowsError(try parse(#"{"error":{"code":401,"message":"secret-token-do-not-display"}}"#)) { error in
            expectFalse(error.localizedDescription.contains("secret-token"))
        }
    }
}
