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

/// Which step of the store split a shipped build performs.
///
/// The split is delivered in two releases rather than one. Cutting straight to
/// `userStateAuthority` means the update simultaneously stops syncing the legacy
/// graph and starts trusting a store that has never been exercised in
/// production — and it opens a divergence window for anyone whose second device
/// has not updated yet. `dualSyncBackfill` ships the risky half first, with
/// nothing user-visible riding on it.
enum StoreSplitReleasePhase {
    /// Ship #1. The legacy library graph stays exactly as it shipped before:
    /// primary source of truth, CloudKit-backed, unchanged cross-device
    /// behaviour. `UserState.sqlite` is populated in the background and synced,
    /// but nothing reads it. This proves the schema, the CloudKit payload, and
    /// the migration itself against real libraries with no way to lose data.
    case dualSyncBackfill

    /// Ship #2. Legacy CloudKit sync is turned off and `UserState.sqlite`
    /// becomes the authority for user-owned state — the payload win. Safe only
    /// once phase one has converged across the population.
    case userStateAuthority

    /// The phase this build ships. Changing this constant is the cutover.
    static let current: StoreSplitReleasePhase = .dualSyncBackfill
}

struct StoreDevelopmentConfiguration: Equatable {
    /// App Store cloud-sync policy, derived from the release phase.
    ///
    /// During `dualSyncBackfill` the legacy store keeps its CloudKit mirror, so
    /// existing users see no change in sync behaviour and a household with one
    /// updated and one not-yet-updated device cannot diverge.
    static let releaseLegacyCloudSyncEnabled =
        StoreSplitReleasePhase.current == .dualSyncBackfill
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
    /// Always false during `dualSyncBackfill`: that release deliberately reads
    /// nothing from the new store. Outside DEBUG this is not frozen at launch, so
    /// a device that classifies itself mid-launch starts applying synchronized
    /// state in the same launch rather than the next one.
    static var newStoreReadsEnabled: Bool {
        guard StoreSplitReleasePhase.current == .userStateAuthority else {
            return false
        }
#if DEBUG
        return launch.newStoreReadsEnabled
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
    /// Off during `dualSyncBackfill`. In that phase the legacy graph carries its
    /// own CloudKit mirror, so cross-device state already arrives through Core
    /// Data — projecting UserState on top would duplicate that work, fight its
    /// merge, and re-introduce the full-projection write volume for no benefit.
    /// The backfill is strictly one-way: legacy → UserState.
    static var userStateImportEnabled: Bool {
        StoreSplitReleasePhase.current == .userStateAuthority && splitStoresEnabled
    }

    static var legacyCloudSyncEnabled: Bool {
        launch.effectiveLegacyCloudSyncEnabled
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
        // Debug builds can exercise either release phase; the default follows
        // whatever `StoreSplitReleasePhase.current` ships.
        let legacyCloudSyncEnabled = defaults.object(
            forKey: legacyCloudSyncEnabledKey
        ) as? Bool ?? releaseLegacyCloudSyncEnabled
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
        legacyCloudSyncEnabled
    }

    var effectiveUserStateCloudSyncEnabled: Bool {
        cloudSyncSettingsAvailable && userStateCloudSyncEnabled
    }
}
