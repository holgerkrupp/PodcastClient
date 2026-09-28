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
    static let debugConfigurationVersionKey =
        "development.database.configurationVersion"
    private static let currentDebugConfigurationVersion = 1
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

    /// The configuration a DEBUG installation should mirror while validating
    /// the currently published release phase. This is deliberately independent
    /// of DEBUG overrides so the settings screen can show every deviation.
    static var publicBaseline: StoreDevelopmentConfiguration {
        StoreDevelopmentConfiguration(
            mode: StoreSplitRollout.resolvedMode,
            legacyCloudSyncEnabled: releaseLegacyCloudSyncEnabled,
            userStateCloudSyncEnabled: releaseUserStateCloudSyncEnabled,
            splitStoreWorkEnabled: true
        )
    }

    static let launch = loadCurrent()

    static var current: StoreDevelopmentConfiguration {
        loadCurrent()
    }

    static var splitStoresEnabled: Bool {
        launch.splitStoresEnabled
    }

    /// Whether `UserState.sqlite` is the authority for user-owned state.
    ///
    /// The DEBUG next-step preview may exercise the read-authority path before
    /// the release phase constant moves. Release builds remain gated by the
    /// published phase and rollout state.
    static var newStoreReadsEnabled: Bool {
#if DEBUG
        return launch.newStoreReadsEnabled
#else
        guard StoreSplitReleasePhase.current == .userStateAuthority else {
            return false
        }
        guard splitStoresEnabled else { return false }
        return launch.newStoreReadsEnabled || StoreSplitRollout.state == .newStoreReads
#endif
    }

    static var legacyMigrationEnabled: Bool {
        launch.legacyMigrationEnabled
    }

    /// Whether synchronized user state is projected back onto the library graph.
    ///
    /// Release builds keep this off during `dualSyncBackfill`. DEBUG can enable
    /// it only through the explicit next-step read-authority preview, so the
    /// cutover path can be exercised before changing the release phase.
    static var userStateImportEnabled: Bool {
#if DEBUG
        return launch.newStoreReadsEnabled && splitStoresEnabled
#else
        StoreSplitReleasePhase.current == .userStateAuthority && splitStoresEnabled
#endif
    }

    static let legacyCloudSyncLastStateKey =
        "storeSplit.legacyCloudSyncLastEnabled"
    static let legacyCloudReattachApprovedKey =
        "storeSplit.legacyCloudReattachApproved"
    /// Persisted one-way boundary for the production cutover. This lives in the
    /// app group so the app and its extensions agree that SharedDatabase has
    /// been detached, even if a later release changes the read-authority
    /// policy back to the legacy projection.
    static let legacyCloudCutoverCompletedKey =
        "storeSplit.legacyCloudCutoverCompleted.v1"

    private static var legacyAttachmentDefaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static var legacyCloudSyncEnabled: Bool {
        guard launch.effectiveLegacyCloudSyncEnabled else { return false }
        // Read authority and CloudKit attachment are deliberately independent.
        // Once production has crossed the boundary, a rollback may change which
        // local projection is read but can never reopen SharedDatabase with
        // CloudKit's automatic mirroring.
        guard legacyCloudCutoverCompleted == false else { return false }
        return legacyCloudReattachBlocked == false
    }

    static var legacyCloudCutoverCompleted: Bool {
        legacyAttachmentDefaults.bool(forKey: legacyCloudCutoverCompletedKey)
    }

    /// Whether the legacy store is being re-attached to CloudKit after a spell
    /// with mirroring switched off — and has not been cleared to do so.
    ///
    /// Re-attaching is not the no-op it looks like. Rows written while the store
    /// was detached carry no CloudKit identity, so turning mirroring back on
    /// re-imports the zone and merges it alongside them. With no
    /// `@Attribute(.unique)` anywhere in the schema, nothing collapses the two
    /// copies: the library duplicates. That is what happened between
    /// `9c7ddeae` (mirroring off, 2026-08-17) and `0d0f3f77` (back on,
    /// 2026-08-21).
    ///
    /// A device that never had mirroring off has no recorded previous state and
    /// is never blocked, so shipping users are unaffected.
    static var legacyCloudReattachBlocked: Bool {
        let defaults = legacyAttachmentDefaults
        guard let previous = defaults.object(forKey: legacyCloudSyncLastStateKey) as? Bool,
              previous == false else {
            return false
        }
        return defaults.bool(forKey: legacyCloudReattachApprovedKey) == false
    }

    /// Records the decision actually applied to the store, so the next launch can
    /// recognise an off→on transition. Call this once the container is built.
    ///
    /// Detaching re-arms the guard. An approval covers the one divergence window
    /// it was granted for and says nothing about rows written during a later one,
    /// so it must not survive into the next off→on transition — otherwise the
    /// guard fires once per install and the very sequence it exists to catch
    /// (`userStateAuthority` detaches every store, a rollback re-attaches them)
    /// passes unblocked on any device that has ever approved a re-attach.
    static func recordLegacyCloudSyncDecision(_ enabled: Bool) {
        let defaults = legacyAttachmentDefaults
        if enabled == false {
            // The production authority release is the one-way door. Do not set
            // this for a DEBUG-only manual detach: the existing approval path is
            // still useful for explicit development experiments before cutover.
            if StoreSplitReleasePhase.current == .userStateAuthority {
                markLegacyCloudCutoverCompleted()
                return
            }
            defaults.removeObject(forKey: legacyCloudReattachApprovedKey)
        }
        defaults.set(enabled, forKey: legacyCloudSyncLastStateKey)
    }

    /// Records the irreversible production boundary explicitly. Keeping this
    /// separate from the last applied configuration makes the rollback rule
    /// testable and prevents a failed container open from claiming cutover.
    static func markLegacyCloudCutoverCompleted() {
        let defaults = legacyAttachmentDefaults
        defaults.set(true, forKey: legacyCloudCutoverCompletedKey)
        defaults.removeObject(forKey: legacyCloudReattachApprovedKey)
        defaults.set(false, forKey: legacyCloudSyncLastStateKey)
    }

    /// Clears the block. Deduplicate first — approving re-attach on a duplicated
    /// library merges the duplicates into CloudKit for every other device.
    static func approveLegacyCloudReattach() {
        // An explicit development approval cannot override the production
        // one-way boundary. It remains available only for pre-cutover DEBUG
        // experiments, where no customer store has crossed the boundary.
        guard legacyCloudCutoverCompleted == false else { return }
        legacyAttachmentDefaults.set(true, forKey: legacyCloudReattachApprovedKey)
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
        let publicBaseline = Self.publicBaseline
        if defaults.integer(forKey: debugConfigurationVersionKey)
            < currentDebugConfigurationVersion {
            // The previous DEBUG build intentionally forced a local-only graph.
            // Move existing installations back to the public backfill state once;
            // subsequent changes are explicit DEBUG previews from the settings UI.
            defaults.set(
                publicBaseline.mode.rawValue,
                forKey: modeKey
            )
            defaults.set(
                publicBaseline.legacyCloudSyncEnabled,
                forKey: legacyCloudSyncEnabledKey
            )
            defaults.set(
                publicBaseline.userStateCloudSyncEnabled,
                forKey: userStateCloudSyncEnabledKey
            )
            defaults.set(
                publicBaseline.splitStoreWorkEnabled,
                forKey: splitStoreWorkEnabledKey
            )
            defaults.set(
                currentDebugConfigurationVersion,
                forKey: debugConfigurationVersionKey
            )
        }

        let mode = defaults.string(forKey: modeKey)
            .flatMap(DevelopmentStoreMode.init(rawValue:))
            ?? publicBaseline.mode
        let legacyCloudSyncEnabled = defaults.object(
            forKey: legacyCloudSyncEnabledKey
        ) as? Bool ?? publicBaseline.legacyCloudSyncEnabled
        let userStateCloudSyncEnabled = defaults.object(
            forKey: userStateCloudSyncEnabledKey
        ) as? Bool ?? publicBaseline.userStateCloudSyncEnabled
        let splitStoreWorkEnabled = defaults.object(
            forKey: splitStoreWorkEnabledKey
        ) as? Bool ?? publicBaseline.splitStoreWorkEnabled
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
