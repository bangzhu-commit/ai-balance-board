import Foundation

public struct ServiceRefreshTicket: Equatable, Sendable {
    public let service: ServiceID
    public let generation: UInt64
}

/// One independent scheduler per enabled service. Old tasks retain their slot until
/// completion, so disable/re-enable cannot overlap two queries for the same service.
public struct ServiceRefreshCoordinator: Sendable {
    private struct Slot: Sendable {
        var enabled = false
        var generation: UInt64 = 0
        var scheduler = RefreshScheduler()
        var active: ServiceRefreshTicket?
    }
    private var slots: [ServiceID: Slot] = [:]
    private var network: RefreshNetworkState = .unknown

    public init() {}

    public var nextDueAt: TimeInterval? {
        slots.values.compactMap { $0.enabled && $0.active == nil ? $0.scheduler.nextDueAt : nil }.min()
    }

    public func isEnabled(_ id: ServiceID) -> Bool { slots[id]?.enabled == true }
    public func isRunning(_ id: ServiceID) -> Bool { slots[id]?.active != nil }

    @discardableResult
    public mutating func enableWithFreshReading(for id: ServiceID, at now: TimeInterval) -> Bool {
        var slot = slots[id] ?? Slot()
        guard now.isFinite, slot.active == nil else { return false }
        slot.enabled = true; slot.generation &+= 1
        slot.scheduler = RefreshScheduler()
        slot.scheduler.updateNetwork(network, at: now)
        guard slot.scheduler.seedFreshReading(at: now) else { return false }
        slots[id] = slot
        return true
    }

    public mutating func setEnabled(_ enabled: Bool, for id: ServiceID, at now: TimeInterval) {
        var slot = slots[id] ?? Slot()
        guard slot.enabled != enabled else { return }
        slot.enabled = enabled
        slot.generation &+= 1
        slot.scheduler = RefreshScheduler()
        if enabled {
            slot.scheduler.updateNetwork(network, at: now)
            slot.scheduler.trigger(.startup, at: now)
        }
        slots[id] = slot
    }

    /// Invalidate the result while retaining the existing cadence and physical task.
    public mutating func invalidate(_ id: ServiceID) {
        guard var slot = slots[id] else { return }
        slot.generation &+= 1
        slots[id] = slot
    }

    public mutating func trigger(_ event: RefreshTrigger, for id: ServiceID? = nil, at now: TimeInterval) {
        for service in id.map({ [$0] }) ?? Array(slots.keys) {
            guard var slot = slots[service], slot.enabled else { continue }
            if case .manual = event, let active = slot.active, active.generation != slot.generation {
                // A cancelled old request cannot satisfy a new explicit refresh.
                // Keep its physical slot occupied, but remember the new request.
                slot.scheduler = RefreshScheduler()
                slot.scheduler.updateNetwork(network, at: now)
            }
            slot.scheduler.trigger(event, at: now)
            slots[service] = slot
        }
    }

    public mutating func updateNetwork(_ state: RefreshNetworkState, at now: TimeInterval) {
        network = state
        for id in Array(slots.keys) {
            guard var slot = slots[id], slot.enabled else { continue }
            slot.scheduler.updateNetwork(state, at: now)
            slots[id] = slot
        }
    }

    public mutating func beginDue(at now: TimeInterval) -> [ServiceRefreshTicket] {
        var tickets: [ServiceRefreshTicket] = []
        let ordered = ServiceID.allCases + slots.keys.filter { $0.customUUID != nil }.sorted { $0.rawValue < $1.rawValue }
        for id in ordered {
            guard var slot = slots[id], slot.enabled, slot.active == nil,
                  slot.scheduler.beginIfDue(at: now) else { continue }
            let ticket = ServiceRefreshTicket(service: id, generation: slot.generation)
            slot.active = ticket
            slots[id] = slot
            tickets.append(ticket)
        }
        return tickets
    }

    public func accepts(_ ticket: ServiceRefreshTicket) -> Bool {
        guard let slot = slots[ticket.service] else { return false }
        return slot.enabled && slot.generation == ticket.generation && slot.active == ticket
    }

    /// Authentication, missing dependencies, invalid responses, and rate limits use
    /// normal cadence. Only retryable transport failures opt into short backoff.
    public mutating func finish(_ ticket: ServiceRefreshTicket, at now: TimeInterval, retrySoon: Bool) {
        guard var slot = slots[ticket.service], slot.active == ticket else { return }
        slot.active = nil
        if slot.enabled && slot.scheduler.isRunning {
            slot.scheduler.finish(at: now, succeeded: slot.generation != ticket.generation || !retrySoon)
        }
        slots[ticket.service] = slot
    }
}
