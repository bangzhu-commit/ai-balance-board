import Foundation

/// Only explicit choices are persisted. No credentials or account data belong here.
public struct BoardPreferences {
    public static let enabledKey = "AIBalanceBoard.enabledServices"
    public static let completedKey = "AIBalanceBoard.setupCompleted"
    public var enabledServices: Set<ServiceID>
    public var setupCompleted: Bool

    public init(defaults: UserDefaults, hasLegacyReadings: Bool) {
        if let saved = defaults.array(forKey: Self.enabledKey) as? [String] {
            enabledServices = Set(saved.compactMap(ServiceID.init(rawValue:)))
            setupCompleted = defaults.bool(forKey: Self.completedKey)
        } else {
            enabledServices = hasLegacyReadings ? Set(ServiceID.allCases) : []
            setupCompleted = hasLegacyReadings
            save(to: defaults)
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(enabledServices.map(\.rawValue).sorted(), forKey: Self.enabledKey)
        defaults.set(setupCompleted, forKey: Self.completedKey)
    }
}
