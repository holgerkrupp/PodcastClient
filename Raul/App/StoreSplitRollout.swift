import Foundation

/// Per-install position in the legacy → split-store transition.
enum StoreSplitRolloutState: String {
    /// First launch with the rollout code; new-vs-existing not yet decided.
    case unclassified
    /// Existing user: publish user state into `UserState.sqlite` in bounded
    /// slices while the durable local library store stays the authority.
    case migrating
    /// New user, or an existing user whose migration finished: `UserState.sqlite`
    /// is the authority for user-owned state.
    case newStoreReads
}

/// Decides whether this device is still backfilling or has completed the split.
/// Both states render from the same durable, local-only library store, so the
/// rollout position is never visible as missing podcasts, episodes, or queue
/// entries.
///
/// State is persisted only in the shared app-group defaults — there is no server
/// component, and CloudKit remains the single network dependency.
enum StoreSplitRollout {
    static let stateKey = "storeSplit.rollout.state"
    static let unclassifiedLaunchesKey = "storeSplit.rollout.unclassifiedLaunches"

    /// How many launches CloudKit is given to deliver legacy data when legacy
    /// CloudKit sync is enabled (for development or an earlier rollout phase)
    /// before an empty legacy store is treated as a brand-new install.
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
    ///
    /// Neither branch changes which container the UI binds to — both keep the
    /// durable local library store — so a remote pause or a rollback between
    /// them can never empty the Library or the playlists.
    static var resolvedMode: DevelopmentStoreMode {
        // During the backfill release the rollout state records migration
        // progress but must not change how the app reads: the legacy graph stays
        // the authority for everything.
        guard StoreSplitReleasePhase.current == .userStateAuthority else {
            return .splitStores
        }
        switch state {
        case .newStoreReads:
            return .splitStoreReads
        case .unclassified, .migrating:
            return .splitStores
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
