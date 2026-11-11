import Foundation
@testable import BalanceCore

final class FoxCodeParserTests {
    private func fixture(used: String = "75", limit: String = "600", resetType: String = #""NEVER""#) -> Data {
        Data("""
        {"success":true,"subscriptions":[{"quotaUsed":\(used),"plan":{"quotaLimit":\(limit),"resetType":\(resetType)}}]}
        """.utf8)
    }

    func testSuccessfulSubscriptionsAreAggregatedByResetType() throws {
        let data = Data(#"{"success":true,"subscriptions":[{"quotaUsed":75,"plan":{"quotaLimit":600,"resetType":"NEVER"}},{"quotaUsed":500,"plan":{"quotaLimit":10000,"resetType":"NEVER"}},{"quotaUsed":200,"plan":{"quotaLimit":1000,"resetType":"MONTHLY"}},{"quotaUsed":50.25,"plan":{"quotaLimit":200,"resetType":"DAILY"}}]}"#.utf8)
        let reading = try FoxCodeParser.parse(data: data)
        expectEqual(reading.service, .foxcode)
        expectEqual(reading.metrics.map(\.id), ["payg", "monthly"])
        expectEqual(reading.metrics.map(\.label), ["按量剩余额度", "月卡剩余额度"])
        expectEqual(reading.metrics.map(\.value), ["10,025", "949.75"])
        expectTrue(reading.metrics.allSatisfy { $0.remainingFraction == nil })
    }

    func testExplicitSuccessfulEmptySubscriptionsAreZero() throws {
        let reading = try FoxCodeParser.parse(data: Data(#"{"success":true,"subscriptions":[]}"#.utf8))
        expectEqual(reading.metrics.count, 2)
        expectEqual(reading.metrics.map(\.value), ["0", "0"])
        expectTrue(reading.metrics.allSatisfy { $0.remainingFraction == nil })
    }

    func testFailuresMissingFieldsAndInvalidNumbersNeverBecomeZero() {
        let malformedResponses = [
            "not JSON", "[]", "{}",
            #"{"success":false,"subscriptions":[]}"#,
            #"{"subscriptions":[]}"#,
            #"{"success":true}"#,
            #"{"success":true,"subscriptions":null}"#,
            #"{"success":true,"subscriptions":[{}]}"#,
            #"{"success":true,"subscriptions":[{"quotaUsed":75}]}"#,
            #"{"success":true,"subscriptions":[{"plan":{"quotaLimit":600,"resetType":"NEVER"}}]}"#,
            #"{"success":true,"subscriptions":[{"quotaUsed":75,"plan":{"resetType":"NEVER"}}]}"#,
            #"{"success":true,"subscriptions":[{"quotaUsed":75,"plan":{"quotaLimit":600}}]}"#,
            #"{"success":1,"subscriptions":[]}"#
        ]
        for response in malformedResponses {
            expectThrowsError(try FoxCodeParser.parse(data: Data(response.utf8)))
        }
        for invalidNumber in [#""75""#, "true", "null", "1e999", "-1", "9007199254740992"] {
            expectThrowsError(try FoxCodeParser.parse(data: fixture(used: invalidNumber)))
            expectThrowsError(try FoxCodeParser.parse(data: fixture(limit: invalidNumber)))
        }
        expectThrowsError(try FoxCodeParser.parse(data: fixture(resetType: #""""#)))
    }

    func testOverageKeepsNegativeRemainingQuota() throws {
        let data = Data(#"{"success":true,"subscriptions":[{"quotaUsed":675,"plan":{"quotaLimit":600,"resetType":"NEVER"}},{"quotaUsed":110.5,"plan":{"quotaLimit":100,"resetType":"MONTHLY"}}]}"#.utf8)
        let reading = try FoxCodeParser.parse(data: data)
        expectEqual(reading.metrics.map(\.value), ["-75", "-10.5"])
        expectTrue(reading.metrics.allSatisfy { $0.remainingFraction == nil })
    }

    func testProvidedTimestampIsPreservedForCacheAge() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = try FoxCodeParser.parse(data: fixture(), at: date)
        expectEqual(reading.fetchedAt, date)
        expectEqual(reading.source, "FoxCode 仪表板接口")
        expectEqual(reading.metrics.map(\.value), ["525", "0"])
    }
}
