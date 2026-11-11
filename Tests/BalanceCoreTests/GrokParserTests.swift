import Foundation
@testable import BalanceCore

final class GrokParserTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture(percent: String = "20.109194", readAt: Double = 1_799_998_800_000,
                         reset: String = "1800086400000", expires: Double = 1_800_080_000_000,
                         version: Int = 2, team: String = "null", trial: Bool = false,
                         included: Bool = true) -> Data {
        Data("""
        {"schemaVersion":\(version),"value":{"kind":"present","selectedTeamId":\(team),"reading":{"usage":{"percentUsed":\(percent),"nextResetMs":\(reset),"isSandTrial":\(trial),"hasNonZeroIncludedLimit":\(included),"isTeamSeat":false,"onDemand":{"usedCents":100,"limitCents":2000}},"readAtMs":\(readAt)},"expiresAtMs":\(expires)}}
        """.utf8)
    }

    func testRemainingUsesCacheTimestampAndKeepsSpendingSeparate() throws {
        let reading = try GrokParser.parse(data: fixture(), now: now)
        expectEqual(reading.service, .grok)
        expectEqual(reading.metrics.count, 1)
        expectEqual(reading.metrics[0].value, "79.9%")
        expectEqual(reading.metrics[0].label, "每周剩余")
        expectEqual(reading.metrics[0].remainingFraction!, 0.79890806, accuracy: 0.0000001)
        expectEqual(reading.fetchedAt.timeIntervalSince1970, 1_799_998_800)
        expectEqual(now.timeIntervalSince(reading.fetchedAt), 1_200)
        expectEqual(reading.source, "客户端缓存")
    }

    func testNullResetAndOverageDoNotInventNegativeBalance() throws {
        let reading = try GrokParser.parse(data: fixture(percent: "110.5", reset: "null"), now: now)
        expectEqual(reading.metrics[0].value, "0%")
        expectEqual(reading.metrics[0].remainingFraction, 0)
        expectNil(reading.metrics[0].resetsAt)
    }

    func testExpiredResetAndFutureTimestampAreRejected() {
        expectThrowsError(try GrokParser.parse(data: fixture(expires: 1_799_999_999_000), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(reset: "1800000000000"), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(readAt: 1_800_000_000_001), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(readAt: 1_799_913_600_000), now: now))
    }

    func testUnknownSchemaMissingPercentageAndInvalidNumbersFail() {
        expectThrowsError(try GrokParser.parse(data: fixture(version: 3), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(percent: "null"), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(percent: "-1"), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(percent: "1e999"), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(percent: "true"), now: now))
        let missing = String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: "\"percentUsed\":20.109194,", with: "")
        expectThrowsError(try GrokParser.parse(data: Data(missing.utf8), now: now))
        expectThrowsError(try GrokParser.parse(data: fixture(included: false), now: now))
    }

    func testScopeAndTrialAreVisible() throws {
        let team = try GrokParser.parse(data: fixture(team: "42"), now: now)
        expectEqual(team.metrics[0].label, "团队席位 · 每周剩余")
        let trial = try GrokParser.parse(data: fixture(trial: true), now: now)
        expectEqual(trial.metrics[0].label, "试用额度剩余")
        expectThrowsError(try GrokParser.parse(data: fixture(team: "-1"), now: now))
        let missingScope = String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: "\"selectedTeamId\":null,", with: "")
        expectThrowsError(try GrokParser.parse(data: Data(missingScope.utf8), now: now))
    }

    func testSlotAndFilenameMatchClientFormat() throws {
        let slot = try GrokParser.accountSlot(from: Data(#"{"schemaVersion":1,"value":"grok|example"}"#.utf8))
        expectEqual(try GrokParser.usageKey(accountSlot: slot), "sand.client.slice.account.grok%7Cexample.weekly-usage.cache")
        expectEqual(GrokParser.fileName(for: "foo"), "mzxw6.blob")
        expectEqual(GrokParser.fileName(for: GrokParser.accountSlotKey), "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob")
        expectThrowsError(try GrokParser.accountSlot(from: Data(#"{"schemaVersion":2,"value":"grok|example"}"#.utf8)))
        expectThrowsError(try GrokParser.accountSlot(from: Data(#"{"schemaVersion":1,"value":""}"#.utf8)))
        expectThrowsError(try GrokParser.accountSlot(from: Data(count: GrokParser.maximumFileBytes)))
        expectThrowsError(try GrokParser.parse(data: Data(count: GrokParser.maximumFileBytes), now: now))
    }
}
