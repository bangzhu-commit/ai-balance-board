import Foundation

@main
enum TestMain {
    static func main() {
        let codex = CodexParserTests()
        TestResults.run("Codex：每周额度与余额独立") { try codex.testWeeklyPrimaryAndIndependentCreditBalance() }
        TestResults.run("Codex：多 buckets 与多个周期") { try codex.testMultiBucketViewWinsOverLegacyAndKeepsAllWindows() }
        TestResults.run("Codex：null 不推断成零") { try codex.testNullDoesNotBecomeZero() }
        TestResults.run("Codex：空 map 回退与百分比边界") { try codex.testEmptyMapFallsBackAndPercentageIsClamped() }
        TestResults.run("Codex：不限额与小数余额") { try codex.testUnlimitedCreditsAndDecimalCredits() }
        TestResults.run("Codex：错误响应与敏感内容") { try codex.testMissingOrMalformedResponsesFailWithoutEchoingRawError() }

        let foxCode = FoxCodeParserTests()
        TestResults.run("FoxCode：多订阅按重置类型聚合") { try foxCode.testSuccessfulSubscriptionsAreAggregatedByResetType() }
        TestResults.run("FoxCode：明确成功的空订阅才返回零") { try foxCode.testExplicitSuccessfulEmptySubscriptionsAreZero() }
        TestResults.run("FoxCode：错误、缺失与异常字段绝非零") { foxCode.testFailuresMissingFieldsAndInvalidNumbersNeverBecomeZero() }
        TestResults.run("FoxCode：保留超额负数") { try foxCode.testOverageKeepsNegativeRemainingQuota() }
        TestResults.run("FoxCode：保留缓存时间戳") { try foxCode.testProvidedTimestampIsPreservedForCacheAge() }

        let grok = GrokParserTests()
        TestResults.run("Grok：缓存时间与独立消费") { try grok.testRemainingUsesCacheTimestampAndKeepsSpendingSeparate() }
        TestResults.run("Grok：未知重置与超额") { try grok.testNullResetAndOverageDoNotInventNegativeBalance() }
        TestResults.run("Grok：过期与未来时间") { grok.testExpiredResetAndFutureTimestampAreRejected() }
        TestResults.run("Grok：schema、百分比与无效数字") { grok.testUnknownSchemaMissingPercentageAndInvalidNumbersFail() }
        TestResults.run("Grok：团队与试用范围") { try grok.testScopeAndTrialAreVisible() }
        TestResults.run("Grok：缓存 slot 与文件命名") { try grok.testSlotAndFilenameMatchClientFormat() }

        let grokServer = GrokServerParserTests()
        TestResults.run("Grok服务器：百分比与查询时间独立于缓存") { try grokServer.testServerPercentageAndFetchedTimeWithoutClientCache() }
        TestResults.run("Grok服务器：protoJSON缺省、null与数字字符串") { try grokServer.testProtoJSONDefaultsNullsAndNumericStrings() }
        TestResults.run("Grok服务器：未知与无效用量不伪造剩余") { grokServer.testMissingOrInvalidUsageNeverInventsFullRemaining() }
        TestResults.run("Grok服务器：RFC3339与无效日期") { try grokServer.testRFC3339FractionsOffsetsAndInvalidDates() }
        TestResults.run("Grok服务器：共享池与团队范围明确") { try grokServer.testSharedAndTeamScopesStayExplicitAndPooledIsUnavailable() }
        TestResults.run("Grok服务器：截止时间不推断试用状态") { try grokServer.testTrialDeadlineDoesNotAssertActiveTrial() }
        TestResults.run("Grok服务器：历史试用日期不阻断当前付费额度") { try grokServer.testHistoricalTrialDeadlineDoesNotInvalidateActivePaidQuota() }

        let scheduler = RefreshSchedulerTests()
        TestResults.run("刷新：浏览器重连与唤醒合并补查") { scheduler.testBrowserReconnectMergesWithWakeAndInFlightRecovery() }
        TestResults.run("刷新：启动等待网络且迟到回调不重复") { scheduler.testStartupWaitsForOnlineAndLateCallbacksDoNotDuplicate() }
        TestResults.run("刷新：唤醒风暴有界去抖") { scheduler.testWakeBurstHasBoundedDebounce() }
        TestResults.run("刷新：离线多触发合并恢复一次") { scheduler.testOfflineTriggersMergeIntoOneRecovery() }
        TestResults.run("刷新：运行中休眠保留一次唤醒补查") { scheduler.testSleepDuringRunKeepsOneSettledWakeFollowup() }
        TestResults.run("刷新：周期从完成计算且不追赶连发") { scheduler.testPeriodicIsMeasuredFromCompletionAndDoesNotCatchUp() }
        TestResults.run("刷新：近期成功不丢真实恢复与新唤醒") { scheduler.testRealRecoveryAndNewWakeAreNotSuppressedAfterSuccess() }
        TestResults.run("刷新：离线结束不建计时器") { scheduler.testOfflineFinishHasNoTimerUntilRecovery() }
        TestResults.run("刷新：失败退避有上限且成功重置") { scheduler.testFailuresBackOffAndSuccessResetsFailureCount() }
        TestResults.run("刷新：离线阻断退避并合并联网恢复") { scheduler.testOfflineBlocksBackoffTimerAndRecoveryStillCoalesces() }

        let serviceScheduler = ServiceRefreshCoordinatorTests()
        TestResults.run("分服务：只查询已启用服务且启动去重") { serviceScheduler.testDisabledServicesNeverQueryAndSelectedServicesStartOnce() }
        TestResults.run("分服务：失败退避不连带正常服务") { serviceScheduler.testFailureBackoffDoesNotRepeatSuccessfulServices() }
        TestResults.run("分服务：登录依赖限流不短周期重试") { serviceScheduler.testAuthenticationAndDependenciesUseNormalCadence() }
        TestResults.run("分服务：禁用重启用拒绝旧回包且查询不重叠") { serviceScheduler.testDisableReenableRejectsOldResultsAndCannotOverlap() }
        TestResults.run("分服务：清除读数后旧回包不能写回") { serviceScheduler.testClearingReadingRejectsInFlightResultAndKeepsNormalCadence() }
        TestResults.run("分服务：清除后显式刷新等待旧查询且不丢请求") { serviceScheduler.testExplicitRefreshAfterClearWaitsForOldTaskWithoutLosingRequest() }
        TestResults.run("分服务：浏览器重连只查询Grok并合并唤醒") { serviceScheduler.testBrowserReconnectOnlyRefreshesGrokAndWakeMerges() }
        TestResults.run("分服务：单卡手动刷新不影响其他服务") { serviceScheduler.testManualRefreshTargetsOnlyRequestedService() }
        let preferences = BoardPreferencesTests()
        TestResults.run("设置：全新安装默认不启用服务") { preferences.testCleanInstallStartsWithNoServicesAndIncompleteSetup() }
        TestResults.run("设置：旧版迁移且尊重明确的空选择") { preferences.testLegacyMigrationAndExplicitEmptySelectionAreStable() }
        TestResults.run("设置：服务选择持久化且忽略未知服务") { preferences.testSelectionPersistsAndUnknownServicesDoNotEnableAnything() }

        TestResults.printSummary()
        exit(TestResults.failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
