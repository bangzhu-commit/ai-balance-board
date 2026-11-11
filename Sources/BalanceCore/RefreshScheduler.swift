import Foundation

public enum RefreshTrigger: Sendable {
    case startup, periodic, manual, wake, connectionAvailable
}

public enum RefreshNetworkState: Sendable {
    case unknown, offline, online
}

/// A serial, deterministic refresh coordinator. All times use the same monotonic clock.
/// The owner calls beginIfDue after events, timer firings, and finish, then schedules
/// one timer for nextDueAt. This type performs no I/O and never starts a task itself.
public struct RefreshScheduler: Sendable {
    public private(set) var isRunning = false
    public var hasPendingRefresh: Bool { pendingAt != nil }

    private let interval: TimeInterval
    private let debounce: TimeInterval
    private let maxDebounce: TimeInterval
    private var network: RefreshNetworkState = .unknown
    private var startupRequested = false
    private var hasBegunRun = false
    private var consecutiveFailures = 0
    private var pendingAt: TimeInterval?
    private var nextPeriodicAt: TimeInterval?
    private var burstStartedAt: TimeInterval?
    private var settlingUntil: TimeInterval?

    public init(interval: TimeInterval = 300, debounce: TimeInterval = 2,
                maxDebounce: TimeInterval = 4) {
        precondition(interval.isFinite && interval > 0)
        precondition(debounce.isFinite && debounce >= 0)
        precondition(maxDebounce.isFinite && maxDebounce >= debounce)
        self.interval = interval
        self.debounce = debounce
        self.maxDebounce = maxDebounce
    }

    /// Nil means the owner must not create a timer, including during an active run.
    public var nextDueAt: TimeInterval? {
        guard !isRunning, network == .online else { return nil }
        guard let requested = [pendingAt, nextPeriodicAt].compactMap({ $0 }).min() else { return nil }
        return max(requested, settlingUntil ?? requested)
    }

    public func isDue(at now: TimeInterval) -> Bool {
        guard now.isFinite, let due = nextDueAt else { return false }
        return now >= due
    }

    public mutating func trigger(_ event: RefreshTrigger, at now: TimeInterval) {
        guard now.isFinite else { return }
        switch event {
        case .startup:
            // A late startup signal must not repeat a refresh already begun on first online.
            guard !startupRequested, !hasBegunRun else { return }
            startupRequested = true
            requestImmediate(at: now)
        case .periodic:
            // finish owns the periodic deadline; timer ticks never enqueue another run.
            break
        case .manual:
            // A current run already fulfills repeated manual/periodic requests.
            guard !isRunning else { return }
            requestImmediate(at: now)
        case .wake, .connectionAvailable:
            // A wake or reconnected browser can invalidate an in-flight request.
            requestDebounced(at: now)
        }
    }

    public mutating func updateNetwork(_ state: RefreshNetworkState, at now: TimeInterval) {
        guard now.isFinite, state != network else { return }
        network = state
        if state == .online {
            // An expired burst while offline must not bypass the recovery settle period.
            if let settlingUntil, settlingUntil < now {
                burstStartedAt = nil
                self.settlingUntil = nil
            }
            requestDebounced(at: now)
        } else {
            // Do not query while unknown/offline. Remember one recovery refresh instead.
            requestImmediate(at: now)
        }
    }

    /// Atomically consumes all currently pending triggers and marks a single active run.
    @discardableResult
    public mutating func beginIfDue(at now: TimeInterval) -> Bool {
        guard isDue(at: now) else { return false }
        isRunning = true
        hasBegunRun = true
        pendingAt = nil
        nextPeriodicAt = nil
        burstStartedAt = nil
        settlingUntil = nil
        return true
    }

    public mutating func finish(at now: TimeInterval, succeeded: Bool) {
        guard now.isFinite, isRunning else { return }
        isRunning = false
        if succeeded {
            consecutiveFailures = 0
            nextPeriodicAt = now + interval
        } else {
            // A route can recover before its proxy or DNS does. Retry twice, then
            // return to the ordinary cadence rather than creating a rapid loop.
            consecutiveFailures = min(3, consecutiveFailures + 1)
            let delay: TimeInterval
            switch consecutiveFailures {
            case 1: delay = 15
            case 2: delay = 60
            default: delay = interval
            }
            nextPeriodicAt = now + delay
        }
        if pendingAt != nil {
            // In-flight wake/network events get exactly one settled follow-up after completion.
            pendingAt = now
            burstStartedAt = now
            settlingUntil = now + debounce
        } else {
            burstStartedAt = nil
            settlingUntil = nil
        }
    }

    private mutating func requestImmediate(at now: TimeInterval) {
        pendingAt = min(pendingAt ?? now, now)
    }

    private mutating func requestDebounced(at now: TimeInterval) {
        requestImmediate(at: now)
        let start = burstStartedAt ?? now
        burstStartedAt = start
        settlingUntil = min(now + debounce, start + maxDebounce)
    }
}
