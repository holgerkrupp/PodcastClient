import Foundation

enum DevelopmentStoreMode: String, CaseIterable, Identifiable {
    /// The on-disk library store only. No UserState store, no dual writes.
    case legacyOnly
    /// On-disk library store (local-only) plus dual writes into UserState while
    /// the local store is still the authority for user state.
    case splitStores
    /// On-disk library store (local-only) with `UserState.sqlite` as the read
    /// authority for user state. This is the shipping post-migration mode.
    case splitStoreReads
    /// Development-only: the library graph is an in-memory projection rebuilt
    /// from `PodcastCache.sqlite` at every launch. Nothing on disk backs it.
    case newStoresOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .legacyOnly:
            "Local library store only"
        case .splitStores:
            "Local library + UserState (dual-write)"
        case .splitStoreReads:
            "Local library + UserState authority"
        case .newStoresOnly:
            "Cache projection only (experimental)"
        }
    }

    /// Whether the app's runtime SwiftData graph lives in memory and has to be
    /// rebuilt from `PodcastCache.sqlite` on every launch.
    ///
    /// Only the experimental endgame mode does this. Every shipping mode keeps
    /// the durable on-disk library store, which is what makes the migration
    /// invisible: no library or playlist data ever has to be recreated before
    /// the first frame.
    var usesInMemoryLibraryProjection: Bool {
        self == .newStoresOnly
    }
}

struct StoreDevelopmentConfiguration: Equatable {
    /// App Store cloud-sync policy for the current migration phase. The legacy
    /// database is a local migration/recovery source only; all cross-device user
    /// state flows through UserState.sqlite.
    static let releaseLegacyCloudSyncEnabled = false
    static let releaseUserStateCloudSyncEnabled = true

    static let modeKey = "development.database.storeMode"
    static let legacyCloudSyncEnabledKey = "development.database.legacyCloudSyncEnabled"
    static let userStateCloudSyncEnabledKey = "development.database.userStateCloudSyncEnabled"
    static let splitStoreWorkEnabledKey = "development.database.splitStoreWorkEnabled"
    static let resetLocalSplitStoresOnNextLaunchKey =
        "development.database.resetLocalSplitStoresOnNextLaunch"
    static let resetAllLocalStoresOnNextLaunchKey =
        "development.database.resetAllLocalStoresOnNextLaunch"
    /// Pauses the slice migration loop without disabling the rest of split-store
    /// work. Read live (not frozen at launch) so the toggle takes effect at once.
    static let migrationPausedKey =
        "development.database.migrationPaused"

    let mode: DevelopmentStoreMode
    let legacyCloudSyncEnabled: Bool
    let userStateCloudSyncEnabled: Bool
    let splitStoreWorkEnabled: Bool

    static let launch = loadCurrent()

    static var current: StoreDevelopmentConfiguration {
        loadCurrent()
    }

    static var splitStoresEnabled: Bool {
        launch.splitStoresEnabled
    }

    /// Whether `UserState.sqlite` is the authority for user-owned state.
    ///
    /// Unlike `splitStoresEnabled` this is deliberately **not** frozen at launch
    /// in release builds: the runtime store no longer depends on the mode, so a
    /// device that classifies itself mid-launch can start applying synchronized
    /// user state immediately instead of on the next launch. A brand-new iPad or
    /// Mac therefore fills its queue and playback state on first launch.
    static var newStoreReadsEnabled: Bool {
#if DEBUG
        launch.newStoreReadsEnabled
#else
        guard splitStoresEnabled else { return false }
        return launch.newStoreReadsEnabled || StoreSplitRollout.state == .newStoreReads
#endif
    }

    static var legacyMigrationEnabled: Bool {
        launch.legacyMigrationEnabled
    }

    /// Whether synchronized user state is projected back onto the library graph.
    ///
    /// This is on for every split mode, not just once UserState becomes the read
    /// authority. Importing is additive and merge-guarded, and a device still
    /// backfilling needs it: anything it changed on another device — or during a
    /// spell reading the in-memory projection — exists only in UserState.
    static var userStateImportEnabled: Bool {
        splitStoresEnabled
    }

    static var legacyCloudSyncEnabled: Bool {
        false
    }

    static var userStateCloudSyncEnabled: Bool {
        launch.effectiveUserStateCloudSyncEnabled
    }

    static var cloudSyncSettingsAvailable: Bool {
        launch.cloudSyncSettingsAvailable
    }

    /// Whether the runtime library graph is an in-memory rebuild of
    /// `PodcastCache.sqlite` rather than the durable on-disk library store.
    static var runtimeStoreIsInMemoryProjection: Bool {
        launch.mode.usesInMemoryLibraryProjection
    }

    static var projectsListeningHistoryToLegacy: Bool {
        switch launch.mode {
        case .splitStores, .splitStoreReads, .newStoresOnly:
            true
        case .legacyOnly:
            false
        }
    }

    static var episodeStateProjectionRecencyCutoff: Date? {
        switch launch.mode {
        case .legacyOnly, .splitStores:
            nil
        case .splitStoreReads, .newStoresOnly:
            Calendar.current.date(byAdding: .day, value: -180, to: .now)
        }
    }

    static var modeAllowsDuplicateCleanupDuringProjection: Bool {
        true
    }

    static var splitStoreHeavyWorkPaused: Bool {
#if DEBUG
        launch.splitStoreHeavyWorkPaused || StoreSplitRemoteConfigStore.migrationPausedRemotely
#else
        // Release builds have no manual toggle; the remote kill switch is the only
        // lever. Read live so a published pause takes effect on the next check.
        StoreSplitRemoteConfigStore.migrationPausedRemotely
#endif
    }

    /// Live pause switch for the slice migration loop (read each slice).
    static var migrationSlicePaused: Bool {
#if DEBUG
        UserDefaults.standard.bool(forKey: migrationPausedKey)
#else
        false
#endif
    }

    private static func loadCurrent() -> StoreDevelopmentConfiguration {
#if DEBUG
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: modeKey)
            .flatMap(DevelopmentStoreMode.init(rawValue:))
            ?? .splitStoreReads
        // Ignore the historical debug preference. Re-enabling CloudKit for the
        // legacy graph would violate the split-store architecture.
        let legacyCloudSyncEnabled = false
        let userStateCloudSyncEnabled = defaults.object(
            forKey: userStateCloudSyncEnabledKey
        ) as? Bool ?? true
        let splitStoreWorkEnabled = defaults.object(
            forKey: splitStoreWorkEnabledKey
        ) as? Bool ?? true
        return StoreDevelopmentConfiguration(
            mode: mode,
            legacyCloudSyncEnabled: legacyCloudSyncEnabled,
            userStateCloudSyncEnabled: userStateCloudSyncEnabled,
            splitStoreWorkEnabled: splitStoreWorkEnabled
        )
#else
        // Release builds follow the on-device rollout. Every mode it can resolve
        // to keeps the durable, local-only library store as the runtime graph;
        // the rollout only decides when UserState becomes the read authority for
        // user-owned state.
        return StoreDevelopmentConfiguration(
            mode: StoreSplitRollout.resolvedMode,
            legacyCloudSyncEnabled: releaseLegacyCloudSyncEnabled,
            userStateCloudSyncEnabled: releaseUserStateCloudSyncEnabled,
            splitStoreWorkEnabled: true
        )
#endif
    }
}

extension StoreDevelopmentConfiguration {
    var splitStoreHeavyWorkPaused: Bool {
        splitStoreWorkEnabled == false
    }

    var splitStoresEnabled: Bool {
        splitStoreHeavyWorkPaused == false && mode != .legacyOnly
    }

    var newStoreReadsEnabled: Bool {
        splitStoreHeavyWorkPaused == false
            && (mode == .splitStoreReads || mode == .newStoresOnly)
    }

    var legacyMigrationEnabled: Bool {
        splitStoreHeavyWorkPaused == false
            && (mode == .splitStores || mode == .splitStoreReads)
    }

    var cloudSyncSettingsAvailable: Bool {
        mode == .splitStores || mode == .splitStoreReads
    }

    var effectiveLegacyCloudSyncEnabled: Bool {
        false
    }

    var effectiveUserStateCloudSyncEnabled: Bool {
        cloudSyncSettingsAvailable && userStateCloudSyncEnabled
    }
}
