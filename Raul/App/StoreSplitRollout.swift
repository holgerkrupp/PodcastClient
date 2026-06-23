import Foundation

/// Per-install position in the legacy → split-store transition.
enum StoreSplitRolloutState: String {
    /// First launch with the rollout code; new-vs-existing not yet decided.
    case unclassified
    /// Existing user: keep reading the legacy store and dual-writing while the
    /// split store is backfilled in bounded slices.
    case migrating
    /// New user, or an existing user whose migration finished: read from the
    /// split store (projected onto the legacy graph) and keep dual-writing.
    case newStoreReads
}

/// Decides whether this device reads from the legacy store while it backfills the
/// split store, or reads from the split store directly.
///
/// State is persisted only in the shared app-group defaults — there is no server
/// component, and CloudKit remains the single network dependency.
enum StoreSplitRollout {
    static let stateKey = "storeSplit.rollout.state"
    static let unclassifiedLaunchesKey = "storeSplit.rollout.unclassifiedLaunches"

    /// How many launches CloudKit is given to deliver legacy data before an empty
    /// legacy store is treated as a brand-new install. Prevents a reinstalling
    /// user from being misclassified as new before their data downloads.
    static let maxUnclassifiedLaunches = 3

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static var state: StoreSplitRolloutState {
        guard let raw = defaults.string(forKey: stateKey),
              let value = StoreSplitRolloutState(rawValue: raw) else {
            return .unclassified
        }
        return value
    }

    static func set(_ newState: StoreSplitRolloutState) {
        guard state != newState else { return }
        defaults.set(newState.rawValue, forKey: stateKey)
        CrashBreadcrumbs.shared.record(
            "store_split_rollout_state",
            details: newState.rawValue
        )
    }

    static var unclassifiedLaunches: Int {
        defaults.integer(forKey: unclassifiedLaunchesKey)
    }

    @discardableResult
    static func incrementUnclassifiedLaunches() -> Int {
        let next = unclassifiedLaunches + 1
        defaults.set(next, forKey: unclassifiedLaunchesKey)
        return next
    }

    /// The store mode this launch should run in, derived from the rollout state.
    static var resolvedMode: DevelopmentStoreMode {
        switch state {
        case .newStoreReads:
            .splitStoreReads
        case .unclassified, .migrating:
            .splitStores
        }
    }

#if DEBUG
    static func resetForDevelopment() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: unclassifiedLaunchesKey)
        CrashBreadcrumbs.shared.record("store_split_rollout_reset")
    }
#endif
}
