import Foundation
@testable import BalanceCore

final class ServiceRefreshCoordinatorTests {
    private func ready(_ ids: [ServiceID]) -> ServiceRefreshCoordinator {
        var result = ServiceRefreshCoordinator()
        for id in ids { result.setEnabled(true, for: id, at: 0) }
        result.updateNetwork(.online, at: 0)
        return result
    }

    func testDisabledServicesNeverQueryAndSelectedServicesStartOnce() {
        var scheduler = ready([])
        scheduler.trigger(.wake, at: 5)
        scheduler.trigger(.manual, at: 10)
        expectTrue(scheduler.beginDue(at: 100).isEmpty)
        expectNil(scheduler.nextDueAt)
        scheduler.setEnabled(true, for: .codex, at: 100)
        expectEqual(scheduler.nextDueAt, 102)
        expectTrue(scheduler.beginDue(at: 101).isEmpty)
        let tickets = scheduler.beginDue(at: 102)
        expectEqual(tickets.map(\.service), [.codex])
        expectTrue(scheduler.beginDue(at: 102).isEmpty)
        scheduler.trigger(.startup, at: 103)
        scheduler.finish(tickets[0], at: 104, retrySoon: false)
        expectEqual(scheduler.nextDueAt, 404)
    }

    func testFailureBackoffDoesNotRepeatSuccessfulServices() {
        var scheduler = ready([.foxcode, .codex])
        let tickets = scheduler.beginDue(at: 2)
        let fox = tickets.first { $0.service == .foxcode }!
        let codex = tickets.first { $0.service == .codex }!
        scheduler.finish(fox, at: 3, retrySoon: true)
        scheduler.finish(codex, at: 3, retrySoon: false)
        expectEqual(scheduler.nextDueAt, 18)
        let retry = scheduler.beginDue(at: 18)
        expectEqual(retry.map(\.service), [.foxcode])
        scheduler.finish(retry[0], at: 19, retrySoon: true)
        expectEqual(scheduler.nextDueAt, 79)
        let secondRetry = scheduler.beginDue(at: 79)
        expectEqual(secondRetry.map(\.service), [.foxcode])
        scheduler.finish(secondRetry[0], at: 80, retrySoon: true)
        expectEqual(scheduler.nextDueAt, 303)
        expectEqual(scheduler.beginDue(at: 303).map(\.service), [.codex])
    }

    func testAuthenticationAndDependenciesUseNormalCadence() {
        let errors: [BalanceError] = [.authenticationRequired("login"), .dependencyMissing("install"), .rateLimited("wait"), .invalidResponse("update")]
        for error in errors {
            var scheduler = ready([.codex])
            let ticket = scheduler.beginDue(at: 2)[0]
            expectFalse(error.shouldRetrySoon)
            scheduler.finish(ticket, at: 3, retrySoon: error.shouldRetrySoon)
            expectEqual(scheduler.nextDueAt, 303)
            expectTrue(scheduler.beginDue(at: 18).isEmpty)
        }
        expectTrue(BalanceError.network("offline").shouldRetrySoon)
        expectTrue(BalanceError.authenticationRequired("login").connectionState.needsConnection)
        expectTrue(BalanceError.dependencyMissing("install").connectionState.needsConnection)
        expectFalse(BalanceError.network("offline").connectionState.needsConnection)
        expectFalse(BalanceError.rateLimited("wait").connectionState.needsConnection)
        expectFalse(BalanceError.invalidResponse("update").connectionState.needsConnection)
    }

    func testDisableReenableRejectsOldResultsAndCannotOverlap() {
        var scheduler = ready([.grok])
        let old = scheduler.beginDue(at: 2)[0]
        expectTrue(scheduler.accepts(old))
        scheduler.setEnabled(false, for: .grok, at: 3)
        expectFalse(scheduler.accepts(old))
        expectNil(scheduler.nextDueAt)
        scheduler.setEnabled(true, for: .grok, at: 4)
        expectFalse(scheduler.accepts(old))
        expectTrue(scheduler.beginDue(at: 10).isEmpty)
        expectNil(scheduler.nextDueAt)
        scheduler.finish(old, at: 11, retrySoon: true)
        let new = scheduler.beginDue(at: 11)
        expectEqual(new.count, 1)
        expectTrue(scheduler.accepts(new[0]))
        expectTrue(new[0] != old)
        scheduler.finish(old, at: 12, retrySoon: true)
        expectTrue(scheduler.accepts(new[0]))
    }

    func testClearingReadingRejectsInFlightResultAndKeepsNormalCadence() {
        var scheduler = ready([.foxcode])
        let old = scheduler.beginDue(at: 2)[0]
        scheduler.invalidate(.foxcode)
        expectFalse(scheduler.accepts(old))
        expectTrue(scheduler.beginDue(at: 10).isEmpty)
        scheduler.finish(old, at: 11, retrySoon: true)
        expectEqual(scheduler.nextDueAt, 311)
        scheduler.trigger(.manual, for: .foxcode, at: 20)
        let fresh = scheduler.beginDue(at: 20)
        expectEqual(fresh.count, 1)
        expectTrue(scheduler.accepts(fresh[0]))
        expectFalse(scheduler.accepts(old))
    }

    func testExplicitRefreshAfterClearWaitsForOldTaskWithoutLosingRequest() {
        var scheduler = ready([.codex])
        let old = scheduler.beginDue(at: 2)[0]
        scheduler.invalidate(.codex)
        scheduler.trigger(.manual, for: .codex, at: 3)
        expectTrue(scheduler.beginDue(at: 10).isEmpty)
        scheduler.finish(old, at: 11, retrySoon: true)
        let replacement = scheduler.beginDue(at: 11)
        expectEqual(replacement.count, 1)
        expectTrue(scheduler.accepts(replacement[0]))
        expectFalse(scheduler.accepts(old))
    }

    func testBrowserReconnectOnlyRefreshesGrokAndWakeMerges() {
        var scheduler = ready([.foxcode, .codex, .grok])
        for ticket in scheduler.beginDue(at: 2) { scheduler.finish(ticket, at: 3, retrySoon: false) }
        scheduler.trigger(.connectionAvailable, for: .grok, at: 10)
        expectEqual(scheduler.beginDue(at: 12).map(\.service), [.grok])
        scheduler.trigger(.wake, at: 13)
        scheduler.updateNetwork(.offline, at: 13.1)
        scheduler.updateNetwork(.online, at: 14)
        expectTrue(scheduler.beginDue(at: 15).isEmpty)
        let others = scheduler.beginDue(at: 16)
        expectEqual(others.map(\.service), [.foxcode, .codex])
        expectTrue(scheduler.beginDue(at: 16).isEmpty)
    }

    func testManualRefreshTargetsOnlyRequestedService() {
        var scheduler = ready([.foxcode, .codex, .grok])
        for ticket in scheduler.beginDue(at: 2) { scheduler.finish(ticket, at: 3, retrySoon: false) }
        scheduler.trigger(.manual, for: .codex, at: 10)
        let tickets = scheduler.beginDue(at: 10)
        expectEqual(tickets.map(\.service), [.codex])
        scheduler.trigger(.manual, for: .codex, at: 11)
        scheduler.finish(tickets[0], at: 12, retrySoon: false)
        expectEqual(scheduler.nextDueAt, 303)
    }

    func testRateLimitDefersPendingRecoveryAndRepeatedManualRefresh() {
        var scheduler = ready([.codex, .grok])
        let tickets = scheduler.beginDue(at: 2)
        let codex = tickets.first { $0.service == .codex }!
        let grok = tickets.first { $0.service == .grok }!
        scheduler.trigger(.wake, at: 3)
        scheduler.updateNetwork(.offline, at: 3.1)
        scheduler.updateNetwork(.online, at: 3.2)
        scheduler.finish(codex, at: 4, retrySoon: false, rateLimited: true)
        scheduler.finish(grok, at: 4, retrySoon: false)
        expectTrue(scheduler.isRateLimited(.codex, at: 6))
        // The unaffected service still gets its recovery query immediately.
        let recovery = scheduler.beginDue(at: 6)
        expectEqual(recovery.map(\.service), [.grok])
        scheduler.finish(recovery[0], at: 7, retrySoon: false)
        for instant: TimeInterval in [8, 20, 100, 303.99] {
            scheduler.trigger(.manual, for: .codex, at: instant)
            expectTrue(scheduler.beginDue(at: instant).isEmpty)
            expectEqual(scheduler.nextDueAt, 304)
        }
        let retry = scheduler.beginDue(at: 304)
        expectEqual(retry.map(\.service), [.codex])
        expectFalse(scheduler.isRateLimited(.codex, at: 304))
        expectTrue(scheduler.beginDue(at: 304).isEmpty)
        scheduler.finish(retry[0], at: 305, retrySoon: false, rateLimited: true)
        expectEqual(scheduler.nextDueAt, 307) // Grok's independent periodic query.
        scheduler.trigger(.manual, for: .codex, at: 306)
        expectTrue(scheduler.beginDue(at: 306).isEmpty)
    }

    func testRateLimitSurvivesReenableAndAuthenticationRecoveryStillWorks() {
        var scheduler = ready([.codex])
        let ticket = scheduler.beginDue(at: 2)[0]
        scheduler.finish(ticket, at: 3, retrySoon: false, rateLimited: true)
        scheduler.setEnabled(false, for: .codex, at: 4)
        expectNil(scheduler.nextDueAt)
        scheduler.setEnabled(true, for: .codex, at: 5)
        scheduler.invalidate(.codex)
        scheduler.trigger(.manual, for: .codex, at: 6)
        expectEqual(scheduler.nextDueAt, 303)
        expectTrue(scheduler.beginDue(at: 100).isEmpty)
        let retry = scheduler.beginDue(at: 303)
        expectEqual(retry.count, 1)
        scheduler.finish(retry[0], at: 304, retrySoon: false)
        scheduler.trigger(.connectionAvailable, for: .codex, at: 305)
        expectEqual(scheduler.beginDue(at: 307).map(\.service), [.codex])

        var login = ready([.grok])
        let unauthenticated = login.beginDue(at: 2)[0]
        login.trigger(.connectionAvailable, for: .grok, at: 3)
        login.finish(unauthenticated, at: 4, retrySoon: false)
        expectEqual(login.nextDueAt, 6)
        expectEqual(login.beginDue(at: 6).map(\.service), [.grok])
    }
}

final class BoardPreferencesTests {
    private func withDefaults(_ operation: (UserDefaults) -> Void) {
        let name = "local.outlier.ai-balance-board.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        operation(defaults)
    }

    func testCleanInstallStartsWithNoServicesAndIncompleteSetup() {
        withDefaults { defaults in
            let preferences = BoardPreferences(defaults: defaults, hasLegacyReadings: false)
            expectTrue(preferences.enabledServices.isEmpty)
            expectFalse(preferences.setupCompleted)
            expectEqual(defaults.array(forKey: BoardPreferences.enabledKey) as? [String], [])
        }
    }

    func testLegacyMigrationAndExplicitEmptySelectionAreStable() {
        withDefaults { defaults in
            var preferences = BoardPreferences(defaults: defaults, hasLegacyReadings: true)
            expectEqual(preferences.enabledServices, Set(ServiceID.allCases))
            expectTrue(preferences.setupCompleted)
            preferences.enabledServices = []
            preferences.save(to: defaults)
            let reloaded = BoardPreferences(defaults: defaults, hasLegacyReadings: true)
            expectTrue(reloaded.enabledServices.isEmpty)
            expectTrue(reloaded.setupCompleted)
        }
    }

    func testSelectionPersistsAndUnknownServicesDoNotEnableAnything() {
        withDefaults { defaults in
            var preferences = BoardPreferences(defaults: defaults, hasLegacyReadings: false)
            preferences.enabledServices = [.codex]
            preferences.setupCompleted = true
            preferences.save(to: defaults)
            let reloaded = BoardPreferences(defaults: defaults, hasLegacyReadings: false)
            expectEqual(reloaded.enabledServices, [.codex])
            expectTrue(reloaded.setupCompleted)
            defaults.set(["unknown-service", "grok"], forKey: BoardPreferences.enabledKey)
            expectEqual(BoardPreferences(defaults: defaults, hasLegacyReadings: true).enabledServices, [.grok])
        }
    }
}
