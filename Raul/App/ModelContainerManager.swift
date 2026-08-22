import SwiftData
import SwiftUI
import CloudKitSyncMonitor
#if canImport(UIKit)
import UIKit
#endif

@MainActor
class ModelContainerManager: ObservableObject {
    nonisolated static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    @Published private(set) var preparedContainer: ModelContainer?
    /// Read-only migration/recovery source. This is deliberately separate from
    /// the model container injected into the application UI.
    @Published private(set) var preparedLegacyMigrationContainer: ModelContainer?
    @Published private(set) var preparedUserStateContainer: ModelContainer?
    @Published private(set) var preparedCacheContainer: ModelContainer?
    @Published private(set) var initializationError: String?
    @Published private(set) var userStateInitializationError: String?
    @Published private(set) var cacheInitializationError: String?
    @Published private(set) var migrationError: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var isPreparingSplitStores = false
    @Published private(set) var isMigratingSplitStores = false
    @Published private(set) var requiresInitialCloudImport = false
    @Published private(set) var currentSplitStoreJobDescription: String?
    @Published private(set) var pendingSplitStoreWorkReason: String?
    @Published private(set) var lastSplitStoreReconcileSummary: String?
    @Published private(set) var lastSplitStoreReconcileAt: Date?
    // Slice migration telemetry (surfaced in the development settings view).
    @Published private(set) var migrationCurrentPhase: String?
    @Published private(set) var migrationCursorSummary: String?
    @Published private(set) var migrationProgressSummary: String?
    @Published private(set) var migrationFootprintSummary: String?
    @Published private(set) var migrationLastSliceError: String?
#if DEBUG
    @Published private(set) var developmentResetRequiresRelaunch = false
#endif
    private var preparationTask: Task<ModelContainer, Error>?
    private var splitStorePreparationTask: Task<SplitStoreContainers, Never>?
    /// Set while a `BGProcessingTask` is driving the migration. iOS has granted a
    /// time budget in that window, so the "app is backgrounded" stop condition
    /// must not apply.
    private var isRunningBackgroundProcessingTask = false
    private var didBuildCompatibilityProjection = false
    private var isBuildingCompatibilityProjection = false
    private var migrationTask: Task<Void, Never>?
    private var aiContentImportTask: Task<Void, Never>?
    private var userStateImportTask: Task<StoreSplitUserStateImportResult, Never>?
    private var missingFeedRefreshAttempts: [String: Date] = [:]
    private var lastMigrationCompletedAt: Date?
    private var lastAIContentImportAt: Date?
    private var lastUserStateImportAt: Date?
    private let minimumAIContentImportInterval: TimeInterval = 60 * 15
    private let minimumForegroundUserStateImportInterval: TimeInterval = 60 * 10
    private let splitStoreCoordinator = StoreSplitWorkCoordinator.shared
    nonisolated private static let lastMigrationCompletedAtKey =
        "storeSplitMigration.lastCompletedAt.v3"
    nonisolated private static let lastMigrationHadFailuresKey =
        "storeSplitMigration.lastRunHadFailures.v3"
    nonisolated private static let playlistRepairVersion = 2
    nonisolated private static let playlistRepairVersionKey =
        "storeSplit.playlistRepairVersion"
    nonisolated private static let cacheRecoveryVersion = 1
    nonisolated private static let cacheRecoveryVersionKey =
        "storeSplit.cacheOnlyLibraryRecoveryVersion"
    nonisolated private static let lastImportedUserStateStampKey =
        "storeSplit.lastImportedUserStateStamp"
    nonisolated private static let usedInMemoryProjectionKey =
        "storeSplit.usedInMemoryLibraryProjection"
    /// Migration version whose phases have all completed on this device.
    nonisolated private static let completedMigrationVersionKey =
        "storeSplit.completedMigrationVersion"
    /// Spacing between migration slices while audio is playing. Long enough that
    /// the backfill stays a background trickle rather than a sustained load.
    /// Idle time between slices, so a long backfill stays a background trickle
    /// instead of a sustained CPU/disk load.
    nonisolated private static let sliceSpacingSeconds = 0.75
    /// Wall-clock budget for one foreground migration run.
    nonisolated private static let foregroundRunBudgetSeconds: TimeInterval = 25
    /// Wall-clock budget inside a `BGProcessingTask`.
    nonisolated private static let backgroundRunBudgetSeconds: TimeInterval = 120
    /// How long to wait before picking the backfill up after a budget stop.
    nonisolated private static let budgetExhaustedRetryDelay: TimeInterval = 180
    /// How long to wait before retrying after yielding to a CloudKit export.
    nonisolated private static let exportBackpressureRetryDelay: TimeInterval = 120

    var container: ModelContainer {
        guard let preparedContainer else {
            preconditionFailure("ModelContainer accessed before preparation completed")
        }
        return preparedContainer
    }
    
    nonisolated static let shared = ModelContainerManager()

    nonisolated private init() {
#if DEBUG
        Self.resetLocalStoreFilesIfRequested()
#endif
    }

    nonisolated static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    nonisolated static var sharedStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite")
    }

    nonisolated static var userStateStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("UserState.sqlite")
    }

    nonisolated static var cacheStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("PodcastCache.sqlite")
    }

    /// True only in the experimental cache-projection mode. Every shipping mode
    /// keeps the durable on-disk library store, so the runtime graph is never
    /// rebuilt from scratch and the UI is never empty at launch.
    nonisolated static var runtimeUsesCacheProjection: Bool {
        StoreDevelopmentConfiguration.runtimeStoreIsInMemoryProjection
    }

    /// The store the slice migration reads from. When the runtime graph is the
    /// on-disk library store, that store *is* the migration source — there is no
    /// second copy to open.
    private var legacyMigrationSourceContainer: ModelContainer? {
        if Self.runtimeUsesCacheProjection {
            return preparedLegacyMigrationContainer
        }
        return preparedContainer
    }

#if DEBUG
    func scheduleLocalSplitStoreReset() {
        UserDefaults.standard.set(
            true,
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        developmentResetRequiresRelaunch = true
        CrashBreadcrumbs.shared.record("store_split_local_reset_scheduled")
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    func scheduleAllLocalStoreReset() {
        let defaults = UserDefaults.standard
        defaults.set(
            true,
            forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
        )
        defaults.removeObject(
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        developmentResetRequiresRelaunch = true
        CrashBreadcrumbs.shared.record("all_local_stores_reset_scheduled")
    }
    #endif

    nonisolated private static func resetLocalStoreFilesIfRequested() {
        let defaults = UserDefaults.standard
        let resetAllStores = defaults.bool(
            forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
        )
        let resetSplitStores = defaults.bool(
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        guard resetAllStores || resetSplitStores else {
            return
        }

        let storeURLs = resetAllStores
            ? [sharedStoreURL, userStateStoreURL, cacheStoreURL]
            : [userStateStoreURL, cacheStoreURL]
        var failedPaths: [String] = []
        for storeURL in storeURLs.compactMap({ $0 }) {
            do {
                try removeSQLiteArtifacts(for: storeURL)
            } catch {
                failedPaths.append(storeURL.lastPathComponent)
            }
        }

        if failedPaths.isEmpty {
            defaults.removeObject(
                forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
            )
            defaults.removeObject(
                forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
            )
            clearMigrationRunState()
            CrashBreadcrumbs.shared.record(
                resetAllStores
                    ? "all_local_stores_reset_completed"
                    : "store_split_local_reset_completed"
            )
        } else {
            CrashBreadcrumbs.shared.record(
                resetAllStores
                    ? "all_local_stores_reset_failed"
                    : "store_split_local_reset_failed",
                details: failedPaths.joined(separator: ",")
            )
        }
    }

    nonisolated private static func clearMigrationRunState() {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        defaults.removeObject(forKey: lastMigrationCompletedAtKey)
        defaults.removeObject(forKey: lastMigrationHadFailuresKey)
    }

    nonisolated private static func sqliteArtifactURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    nonisolated static func removeSQLiteArtifacts(for storeURL: URL) throws {
        for url in sqliteArtifactURLs(for: storeURL) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
#endif

    
    func prepareContainer() async {
        guard preparedContainer == nil else { return }

        let task: Task<ModelContainer, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            isInitializing = true
            initializationError = nil
#if !DEBUG
            Self.promoteRolloutForCompletedSplitStoreMigrationIfNeeded()
#endif
            requiresInitialCloudImport =
                StoreDevelopmentConfiguration.legacyCloudSyncEnabled
                && (Self.sharedStoreURL.map {
                    !FileManager.default.fileExists(atPath: $0.path)
                } ?? false)
            CrashBreadcrumbs.shared.record("model_container_initialization_started")

            let newTask = Task.detached(priority: .userInitiated) {
                try Self.makeRuntimeContainer()
            }
            preparationTask = newTask
            task = newTask
        }

        do {
            let preparedContainer = try await task.value
            if self.preparedContainer == nil {
                self.preparedContainer = preparedContainer
                CrashBreadcrumbs.shared.record("model_container_initialization_completed")
            }
            if Self.runtimeUsesCacheProjection {
                // The in-memory graph is empty until it has been rebuilt, so the
                // projection is on the critical path in that mode only.
                await prepareSplitStores()
            } else {
                // The on-disk library store is already complete. Opening the
                // split stores and applying synchronized state happens off the
                // launch path so the UI renders the user's real data at once.
                Task { [weak self] in
                    await self?.prepareSplitStores()
                }
            }
        } catch {
            if initializationError == nil {
                initializationError = error.localizedDescription
                CrashBreadcrumbs.shared.record(
                    "model_container_initialization_failed",
                    details: error.localizedDescription
                )
            }
        }

        preparationTask = nil
        isInitializing = false
    }

    func prepareSplitStores() async {
        guard preparedContainer != nil else { return }
#if DEBUG
        guard developmentResetRequiresRelaunch == false else { return }
#endif
        guard StoreDevelopmentConfiguration.splitStoresEnabled else {
            CrashBreadcrumbs.shared.record(
                "store_split_container_initialization_skipped",
                details: "development_mode=legacy_only"
            )
            return
        }
        guard preparedUserStateContainer == nil || preparedCacheContainer == nil else {
            await buildRuntimeGraphIfNeeded()
            return
        }

        let task: Task<SplitStoreContainers, Never>
        if let splitStorePreparationTask {
            task = splitStorePreparationTask
        } else {
            isPreparingSplitStores = true
            userStateInitializationError = nil
            cacheInitializationError = nil
            CrashBreadcrumbs.shared.record("store_split_container_initialization_started")

            let needsUserStateContainer = preparedUserStateContainer == nil
            let needsCacheContainer = preparedCacheContainer == nil
            let newTask = Task.detached(priority: .utility) {
                SplitStoreContainers(
                    userState: needsUserStateContainer
                        ? Result { try Self.makeUserStateContainer() }
                        : nil,
                    cache: needsCacheContainer
                        ? Result { try Self.makeCacheContainer() }
                        : nil
                )
            }
            splitStorePreparationTask = newTask
            task = newTask
        }

        let result = await task.value
        if let userState = result.userState {
            apply(
                userState,
                to: \.preparedUserStateContainer,
                error: \.userStateInitializationError,
                storeName: "user_state"
            )
        }
        if let cache = result.cache {
            apply(
                cache,
                to: \.preparedCacheContainer,
                error: \.cacheInitializationError,
                storeName: "cache"
            )
        }

        splitStorePreparationTask = nil
        isPreparingSplitStores = false

        await buildRuntimeGraphIfNeeded()

        CrashBreadcrumbs.shared.record(
            "store_split_container_initialization_completed",
            details: "user_state=\(preparedUserStateContainer != nil),cache=\(preparedCacheContainer != nil)"
        )
    }

    /// Brings the runtime library graph up to date once the split stores are
    /// open. On disk that means a bounded, additive recovery of anything the
    /// cache holds but the durable store does not; in the experimental
    /// projection mode it means rebuilding the whole in-memory graph.
    private func buildRuntimeGraphIfNeeded() async {
        if Self.runtimeUsesCacheProjection {
            await buildCompatibilityProjectionIfNeeded()
        } else {
            await recoverCacheOnlyLibraryDataIfNeeded()
        }
    }

    /// A device that ran an earlier build in cache-projection mode wrote feed
    /// refreshes to `PodcastCache.sqlite` while its runtime graph lived in
    /// memory. Those podcasts and episodes are missing from the durable store,
    /// so copy back anything the on-disk graph does not already have.
    ///
    /// Only runs where it is needed. On a device that never ran the projection
    /// build the cache is a mirror of the durable store, so the pass could only
    /// ever insert rows the durable store deliberately no longer has — deleting
    /// a podcast or an episode leaves its cache rows behind. Feed data is
    /// rebuildable from RSS anyway, so skipping is cheap and resurrecting is not.
    @discardableResult
    private func recoverCacheOnlyLibraryDataIfNeeded(
        force: Bool = false
    ) async -> StoreSplitCompatibilityProjectionResult {
        let empty = StoreSplitCompatibilityProjectionResult()
        let defaults = UserDefaults.standard
        guard force || Self.deviceUsedInMemoryProjection,
              force || defaults.integer(forKey: Self.cacheRecoveryVersionKey)
                < Self.cacheRecoveryVersion,
              let runtimeContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer,
              let userStateContainer = preparedUserStateContainer else {
            return empty
        }

        // Only feeds the user still actively subscribes to may be restored. An
        // unsubscribe or a deleted podcast writes a `SubscriptionSync` tombstone,
        // which is what keeps this pass from bringing them back.
        let recoverableFeedKeys = activeSubscriptionFeedKeys(userStateContainer)
        guard recoverableFeedKeys.isEmpty == false else { return empty }

        CrashBreadcrumbs.shared.record(
            "store_split_cache_recovery_started",
            details: "feeds=\(recoverableFeedKeys.count),forced=\(force)"
        )
        let result = await Task.detached(priority: .utility) {
            StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
                cacheContainer: cacheContainer,
                runtimeContainer: runtimeContainer,
                recoverableFeedKeys: recoverableFeedKeys
            )
        }.value

        if result.failed == 0 {
            defaults.set(Self.cacheRecoveryVersion, forKey: Self.cacheRecoveryVersionKey)
        }
        CrashBreadcrumbs.shared.record(
            "store_split_cache_recovery_completed",
            details: "podcasts=\(result.podcasts),episodes=\(result.episodes),failed=\(result.failed)"
        )

        // Anything recovered here has no user state attached yet, and a device
        // returning from projection mode may also be missing playlist rows.
        // One reconcile right after recovery restores both.
        if result.podcasts > 0 || result.episodes > 0 {
            _ = await performSplitStoreReconcile(
                authoritativePlaylists: false,
                force: true,
                refreshMissingFeeds: false,
                reason: "cache_recovery"
            )
        }
        return result
    }

    /// Normalized feed keys whose newest `SubscriptionSync` record is an active
    /// subscription. Tombstoned and unsubscribed feeds are excluded.
    private func activeSubscriptionFeedKeys(
        _ userStateContainer: ModelContainer
    ) -> Set<String> {
        let context = ModelContext(userStateContainer)
        let records = ((try? context.fetch(
            FetchDescriptor<SubscriptionSync>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )) ?? [])
        var newestByFeed: [String: Bool] = [:]
        for record in records {
            let key = URL(string: record.feedURL)
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? record.feedURL
            guard newestByFeed[key] == nil else { continue }
            newestByFeed[key] = record.isSubscribed && record.unsubscribedAt == nil
        }
        return Set(newestByFeed.filter { $0.value }.keys)
    }

    /// Whether the current migration version still has phases to run on this
    /// device. Cheap enough to call from the background-transition path: it reads
    /// one integer instead of opening the cache store.
    nonisolated static var hasPendingMigrationWork: Bool {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        return defaults.integer(forKey: completedMigrationVersionKey)
            != StoreSplitMigrationService.migrationVersion
    }

    /// Whether this install has ever rendered from the in-memory cache
    /// projection. Set by the projection itself, so a device that only ever used
    /// the durable store never runs the recovery pass.
    nonisolated static var deviceUsedInMemoryProjection: Bool {
        UserDefaults.standard.bool(forKey: usedInMemoryProjectionKey)
    }

    private func buildCompatibilityProjectionIfNeeded() async {
        guard Self.runtimeUsesCacheProjection,
              didBuildCompatibilityProjection == false,
              isBuildingCompatibilityProjection == false,
              let runtimeContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        isBuildingCompatibilityProjection = true
        defer { isBuildingCompatibilityProjection = false }
        // Record that this install has rendered from the in-memory projection, so
        // a later durable-store launch knows the cache may hold feed data the
        // durable store never saw.
        UserDefaults.standard.set(true, forKey: Self.usedInMemoryProjectionKey)

        await prepareLegacyMigrationSourceIfNeeded(cacheContainer: cacheContainer)
        if let source = preparedLegacyMigrationContainer {
            let playlistFeeds = preparedUserStateContainer.map(
                playlistRecoveryFeedURLs
            ) ?? []
            _ = await Task.detached(priority: .utility) {
                let priorityCount = StoreSplitFeedCacheWriter.bootstrapPriorityFeeds(
                    playlistFeeds,
                    legacyContainer: source,
                    cacheContainer: cacheContainer,
                    limit: 50
                )
                StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                    legacyContainer: source,
                    cacheContainer: cacheContainer,
                    limit: 200
                )
                return priorityCount
            }.value
        }
        let projection = await Task.detached(priority: .userInitiated) {
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cacheContainer,
                runtimeContainer: runtimeContainer
            )
        }.value
        didBuildCompatibilityProjection = projection.failed == 0
        CrashBreadcrumbs.shared.record(
            "store_split_compatibility_projection_completed",
            details: "podcasts=\(projection.podcasts),episodes=\(projection.episodes),failed=\(projection.failed)"
        )

        if let userStateContainer = preparedUserStateContainer {
            _ = await StoreSplitUserStateImporter.apply(
                legacyContainer: runtimeContainer,
                userStateContainer: userStateContainer,
                authoritativePlaylists: true,
                projectListeningHistoryToLegacy: true,
                episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                    .episodeStateProjectionRecencyCutoff
            )
            await PlaySessionTrackerActor(
                modelContainer: runtimeContainer
            ).rebuildListeningStats()
        }
    }

    /// Reads only compact UserState rows and returns the feeds whose episodes
    /// must be present before the first playlist frame is projected. Rows are
    /// newest-first so a tombstone suppresses an older duplicate delivery.
    private func playlistRecoveryFeedURLs(
        _ userStateContainer: ModelContainer
    ) -> [URL] {
        let context = ModelContext(userStateContainer)
        var queueDescriptor = FetchDescriptor<QueueEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        queueDescriptor.fetchLimit = 500
        var playlistDescriptor = FetchDescriptor<PlaylistEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        playlistDescriptor.fetchLimit = 1_500

        var seenRecordIDs = Set<String>()
        var seenFeedKeys = Set<String>()
        var result: [URL] = []
        let rows: [(id: String, feedURL: String, isDeleted: Bool, deletedAt: Date?)] =
            ((try? context.fetch(queueDescriptor)) ?? []).map {
                ($0.id, $0.feedURL, $0.isDeleted, $0.deletedAt)
            } + ((try? context.fetch(playlistDescriptor)) ?? []).map {
                ($0.id, $0.feedURL, $0.isDeleted, $0.deletedAt)
            }
        for row in rows {
            guard seenRecordIDs.insert(row.id).inserted,
                  row.isDeleted == false,
                  row.deletedAt == nil,
                  let feed = URL(string: row.feedURL) else { continue }
            let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
            guard seenFeedKeys.insert(key).inserted else { continue }
            result.append(feed)
            if result.count == 50 { break }
        }
        return result
    }

    private func prepareLegacyMigrationSourceIfNeeded(
        cacheContainer: ModelContainer
    ) async {
        guard preparedLegacyMigrationContainer == nil,
              let sourceURL = Self.sharedStoreURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              StoreSplitMigrationService.isMigrationVerified(
                  cacheContainer: cacheContainer
              ) == false else {
            return
        }
        do {
            let source = try await Task.detached(priority: .utility) {
                try Self.makeLegacyContainer(allowsSave: false)
            }.value
            preparedLegacyMigrationContainer = source
            CrashBreadcrumbs.shared.record("store_split_legacy_migration_source_ready")
        } catch {
            migrationError = error.localizedDescription
            CrashBreadcrumbs.shared.record(
                "store_split_legacy_migration_source_failed",
                details: error.localizedDescription
            )
        }
    }

    /// Queues the bounded backfill on the shared work coordinator. Safe to call
    /// repeatedly: the coordinator coalesces requests and the slice engine
    /// resumes from its persisted cursor.
    func scheduleStoreSplitMigrationIfNeeded() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else { return }
#endif
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            migrationError = nil
            currentSplitStoreJobDescription = nil
            pendingSplitStoreWorkReason = "paused for stability"
            return
        }
        guard Self.hasPendingMigrationWork else { return }
        await splitStoreCoordinator.scheduleForegroundMigration()
    }

    func runLaunchStoreMaintenance() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else { return }
#endif
        // Refresh the remote kill switch before any work decision so a published
        // pause/rollback takes effect this launch (heavy work) and is cached for
        // the next launch's read-mode resolution.
        await StoreSplitRemoteConfigStore.refresh()
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return
        }
        await prepareSplitStores()
        guard StoreDevelopmentConfiguration.splitStoresEnabled else { return }
        let repairedLegacyPlaylists = await repairLegacyPlaylistsIfNeeded()
        if repairedLegacyPlaylists {
            _ = await performSplitStoreReconcile(
                authoritativePlaylists: false,
                force: true,
                refreshMissingFeeds: true,
                reason: "legacy_playlist_repair"
            )
        }
        if let userStateContainer = preparedUserStateContainer {
            await StoreSplitPlaylistPresenceStore.publish(
                modelContainer: userStateContainer
            )
        }
        // Runs in every configuration. The rollout only decides read authority —
        // in DEBUG the manual store-mode picker still wins — but it is also what
        // drives the bounded backfill, so skipping it in debug builds meant the
        // migration only ever advanced when someone pressed a button.
        await resolveStoreSplitRolloutIfNeeded()
        await prunePlayedPlaylistEntries()
        await splitStoreCoordinator.scheduleLaunchWork()
        await bootstrapFeedCacheIfNeeded(feedLimit: 15)
#if canImport(UIKit)
        // Arm the overnight charging pass now rather than waiting for a clean
        // background transition, which a force-quit never delivers.
        AppDelegate.scheduleStoreSplitMigrationProcessingIfNeeded()
#endif
    }

    /// A one-time additive repair for devices that completed rollout before all
    /// legacy playlist/queue rows had reached the split store. This runs before
    /// rollout resolution so repaired rows can be projected immediately, while
    /// the version-verification path independently decides whether a full
    /// migration backfill must resume.
    private func repairLegacyPlaylistsIfNeeded() async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.playlistRepairVersionKey)
                < Self.playlistRepairVersion,
              let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            return false
        }

        CrashBreadcrumbs.shared.record("store_split_playlist_repair_started")
        let result = await StoreSplitPlaylistRepairService.repair(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        let details = "playlists=\(result.playlistCount),entries=\(result.playlistEntryCount),queue=\(result.queueEntryCount),missing=\(result.missingRecordCount)"

        if result.isComplete {
            defaults.set(
                Self.playlistRepairVersion,
                forKey: Self.playlistRepairVersionKey
            )
            CrashBreadcrumbs.shared.record(
                "store_split_playlist_repair_completed",
                details: details
            )
            return result.playlistEntryCount > 0 || result.queueEntryCount > 0
        } else {
            CrashBreadcrumbs.shared.record(
                "store_split_playlist_repair_incomplete",
                details: details
            )
            return false
        }
    }

    /// Copy or upgrade a bounded number of legacy feed projections in the
    /// local-only cache store. Runs off-main and is idempotent; the per-feed cache
    /// schema version is the checkpoint. Runtime projection and repositories
    /// consume the cache directly after each committed page.
    func bootstrapFeedCacheIfNeeded(feedLimit: Int) async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreDevelopmentConfiguration.splitStoresEnabled,
              // Only the cache-projection mode needs a complete feed mirror. With
              // the durable library store authoritative this pass would rewrite
              // the whole library into a second SQLite file for nothing.
              Self.runtimeUsesCacheProjection else { return }
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let cacheContainer = preparedCacheContainer else { return }
        let copied = await Task.detached(priority: .utility) {
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer,
                limit: feedLimit
            )
        }.value
        if copied > 0 {
            CrashBreadcrumbs.shared.record(
                "store_split_feed_cache_bootstrap",
                details: "feeds=\(copied)"
            )
        }
    }

    /// Entry point for the overnight `BGProcessingTask`. Prepares the split
    /// stores and advances the rollout (which runs the bounded migration for
    /// existing users). Runs in both DEBUG and release builds so the task can be
    /// exercised on a debug device.
    func runStoreSplitMigrationBackgroundPass() async {
        await withBackgroundProcessingWindow {
            await StoreSplitRemoteConfigStore.refresh()
            guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background pass skipped",
                    details: "split-store work is paused"
                )
#endif
                return
            }
            await prepareSplitStores()
            guard StoreDevelopmentConfiguration.splitStoresEnabled else {
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background pass skipped",
                    details: "split stores disabled in this mode"
                )
#endif
                return
            }
            await resolveStoreSplitRolloutIfNeeded()
            await bootstrapFeedCacheIfNeeded(feedLimit: 200)
        }
    }

    /// Advances the on-device rollout: classifies new vs existing installs, runs
    /// the bounded migration for existing users, and switches them to split-store
    /// reads once the migration has fully completed.
    func resolveStoreSplitRolloutIfNeeded() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        switch StoreSplitRollout.state {
        case .newStoreReads:
            await resumeMigrationAfterVersionUpgradeIfNeeded()
        case .unclassified:
            await classifyStoreSplitRollout()
        case .migrating:
            await advanceStoreSplitRolloutAfterMigration()
        }
    }

    /// A device may already be marked `newStoreReads` by an older migration
    /// version. A version bump must still backfill newly required fields before
    /// relying on UserState; otherwise an update can temporarily hide local
    /// playlists that still exist in SharedDatabase.
    private func resumeMigrationAfterVersionUpgradeIfNeeded() async {
        await prepareSplitStores()
        guard let cacheContainer = preparedCacheContainer,
              StoreSplitMigrationService.isSliceMigrationComplete(
                  cacheContainer: cacheContainer
              ) == false,
              let legacyContainer = legacyMigrationSourceContainer,
              legacyHasMigrationData(legacyContainer) else {
            return
        }
        StoreSplitRollout.set(.migrating)
        CrashBreadcrumbs.shared.record(
            "store_split_rollout_version_upgrade_backfill",
            details: "version=\(StoreSplitMigrationService.migrationVersion)"
        )
        await advanceStoreSplitRolloutAfterMigration()
    }

    /// Split-first classification: always read the cache/UserState projection;
    /// classify whether an existing local legacy source still needs backfill.
    private func classifyStoreSplitRollout() async {
        await prepareSplitStores()

        let legacyHasData = legacyMigrationSourceContainer
            .map(legacyHasMigrationData) ?? false
        let splitHasData = preparedUserStateContainer
            .map(splitUserStateHasData) ?? false
        // Migration is "not applicable" (treated as complete) when there is no
        // legacy data to back-fill from.
        // Completing every migration phase is what makes UserState safe to read
        // from. Lossless *verification* stays a separate, stricter gate for
        // physically retiring the legacy file: making reads wait for it left
        // devices stuck behind a single unmigratable row forever.
        let migrationComplete = !legacyHasData || (preparedCacheContainer.map {
            StoreSplitMigrationService.isSliceMigrationComplete(cacheContainer: $0)
        } ?? false)

        // Prefer split reads whenever it is safe: the split store has data and
        // either this device's legacy data is fully migrated or there is none.
        if splitHasData && migrationComplete {
            StoreSplitRollout.set(.newStoreReads)
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "split_first,legacy=\(legacyHasData)"
            )
            return
        }

        // Split store empty or not yet backfilled: keep projected reads active
        // and migrate, but only if the local source actually has data.
        if legacyHasData {
            StoreSplitRollout.set(.migrating)
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "migration_source_present,split_has_data=\(splitHasData)"
            )
            await advanceStoreSplitRolloutAfterMigration()
            return
        }

        // Nothing locally in either store: give CloudKit a few launches to
        // deliver data before committing a brand-new install to split reads.
        let importSettled = cloudKitLegacyImportSettled()
        let exhaustedGrace = StoreSplitRollout.incrementUnclassifiedLaunches()
            >= StoreSplitRollout.maxUnclassifiedLaunches
        if StoreDevelopmentConfiguration.legacyCloudSyncEnabled == false
            || importSettled
            || exhaustedGrace {
            StoreSplitRollout.set(.newStoreReads)
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "new,import_settled=\(importSettled),grace_exhausted=\(exhaustedGrace)"
            )
        }
    }

    private func advanceStoreSplitRolloutAfterMigration() async {
        await prepareSplitStores()
        guard let cacheContainer = preparedCacheContainer else { return }
        if StoreSplitMigrationService.isSliceMigrationComplete(
            cacheContainer: cacheContainer
        ) == false {
            await runMigrationSliceLoop()
        } else if StoreSplitMigrationService.isMigrationVerified(
            cacheContainer: cacheContainer
        ) == false,
                  let legacyContainer = legacyMigrationSourceContainer,
                  let userStateContainer = preparedUserStateContainer {
            _ = StoreSplitMigrationVerifier.verify(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
        }
        // Verification above is recorded for the cleanup gate and telemetry; the
        // read cutover only requires every phase to have completed.
        guard let cacheContainer = preparedCacheContainer,
              StoreSplitMigrationService.isSliceMigrationComplete(
                  cacheContainer: cacheContainer
              ) else {
            return
        }
        StoreSplitRollout.set(.newStoreReads)
        CrashBreadcrumbs.shared.record(
            "store_split_rollout_migration_complete",
            details: "verified=\(StoreSplitMigrationService.isMigrationVerified(cacheContainer: cacheContainer))"
        )
    }

    /// A legacy store can contain portable settings, an empty custom playlist,
    /// or listening summaries without a current subscription. Treat every
    /// independently migratable root as evidence; podcast count alone is not a
    /// lossless upgrade classifier.
    private func legacyHasMigrationData(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        func hasAny<Model: PersistentModel>(_ type: Model.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<Model>())) ?? 0) > 0
        }
        return hasAny(Podcast.self)
            || hasAny(Playlist.self)
            || hasAny(PodcastSettings.self)
            || hasAny(PlaySession.self)
            || hasAny(PlaySessionSummary.self)
    }

    /// Whether the synced user-state store holds any user-owned data — meaning it
    /// was migrated here previously or delivered by CloudKit from another device.
    private func splitUserStateHasData(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        func hasAny<Model: PersistentModel>(_ type: Model.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<Model>())) ?? 0) > 0
        }
        return hasAny(SubscriptionSync.self)
            || hasAny(EpisodeStateSync.self)
            || hasAny(PlaylistSync.self)
            || hasAny(PlaylistEntrySync.self)
            || hasAny(QueueEntrySync.self)
            || hasAny(BookmarkSync.self)
            || hasAny(PodcastPreferenceSync.self)
            || hasAny(ListeningHistorySync.self)
            || hasAny(ListeningBaselineSync.self)
    }

    private func cloudKitLegacyImportSettled() -> Bool {
        guard StoreDevelopmentConfiguration.legacyCloudSyncEnabled else { return true }
        if case .succeeded = SyncMonitor.default.importState { return true }
        return false
    }

    /// Promotes devices that already finished the current split-store migration
    /// before the launch-time store mode is frozen. This covers users upgrading
    /// from a build that created/backfilled the split stores while still reading
    /// the legacy graph.
    @discardableResult
    nonisolated static func promoteRolloutForCompletedSplitStoreMigrationIfNeeded(
        cacheContainer providedCacheContainer: ModelContainer? = nil
    ) -> Bool {
        guard StoreSplitRollout.state != .newStoreReads else {
            return false
        }

        let cacheContainer: ModelContainer
        if let providedCacheContainer {
            cacheContainer = providedCacheContainer
        } else {
            do {
                cacheContainer = try makeCacheContainer()
            } catch {
                CrashBreadcrumbs.shared.record(
                    "store_split_rollout_preflight_failed",
                    details: error.localizedDescription
                )
                return false
            }
        }

        guard StoreSplitMigrationService.isSliceMigrationComplete(
            cacheContainer: cacheContainer
        ) else {
            return false
        }

        StoreSplitRollout.set(.newStoreReads)
        CrashBreadcrumbs.shared.record("store_split_rollout_preflight_promoted")
        return true
    }

#if DEBUG
    /// Runs the rollout resolution on demand from the development settings so the
    /// automatic release-build behaviour can be exercised on a debug device.
    func resolveStoreSplitRolloutForDevelopment() async {
        await resolveStoreSplitRolloutIfNeeded()
    }

    func resetStoreSplitRolloutForDevelopment() {
        StoreSplitRollout.resetForDevelopment()
    }

    var storeSplitRolloutStateDescription: String {
        StoreSplitRollout.state.rawValue
    }
#endif

    func pauseSplitStoreWorkForBackground() {
        // Everything stops on backgrounding. Letting the backfill continue on the
        // audio session's process time looked attractive, but the loop it kept
        // alive ran at ~98% CPU for hours and the process was killed by the CPU
        // limit. Background progress belongs to the metered `BGProcessingTask`,
        // which has a budget and an expiration handler.
        migrationTask?.cancel()
        userStateImportTask?.cancel()
        aiContentImportTask?.cancel()
        Task {
            await splitStoreCoordinator.pauseForBackground()
        }
        pendingSplitStoreWorkReason = "paused while app is in background"
        CrashBreadcrumbs.shared.record("store_split_work_background_cancel_requested")
    }

    /// Whether the slice loop may keep going given where the app currently is.
    /// Backgrounded without playback means the process can be suspended at any
    /// moment, so the loop stops at its last committed checkpoint.
    ///
    /// A `BGProcessingTask` is the exception: the app is backgrounded but iOS has
    /// granted an explicit time budget and will call the expiration handler
    /// before reclaiming it. Without this the overnight pass would break out of
    /// the loop on its very first check and do nothing at all.
    private func migrationMayContinueInCurrentAppState() -> Bool {
        if isRunningBackgroundProcessingTask { return true }
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return true }
        return Player.shared.isPlaying
#else
        return true
#endif
    }

    /// Runs `body` inside a declared background-processing window, so the slice
    /// loop knows it may keep working while the app is not in the foreground.
    func withBackgroundProcessingWindow(_ body: () async -> Void) async {
        isRunningBackgroundProcessingTask = true
        defer { isRunningBackgroundProcessingTask = false }
        await body()
    }

    func storeSplitMigrationStatus() -> StoreSplitMigrationStatus? {
        guard let cacheContainer = preparedCacheContainer,
              let userStateContainer = preparedUserStateContainer else {
            return nil
        }
        return StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: cacheContainer.mainContext,
            userStateContext: userStateContainer.mainContext,
            isRunning: isMigratingSplitStores
        )
    }

#if DEBUG
    /// Runs the additive cache→durable-store recovery on demand, bypassing both
    /// the projection-mode marker and the one-shot version key. Still limited to
    /// actively subscribed feeds, so it cannot resurrect deleted podcasts.
    func recoverCacheOnlyLibraryDataForDevelopment() async
        -> StoreSplitCompatibilityProjectionResult {
        await prepareSplitStores()
        return await recoverCacheOnlyLibraryDataIfNeeded(force: true)
    }

    /// One-off recovery of listening history that exists only in the split
    /// stores. Rebuilds the hourly statistics afterwards so the Statistics screen
    /// reflects the restored sessions immediately.
    func recoverListeningHistoryForDevelopment() async throws
        -> StoreSplitUserStateImportResult {
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        guard isMigratingSplitStores == false, userStateImportTask == nil else {
            throw StoreSplitDevelopmentResetError.workInProgress
        }

        StoreSplitMigrationDebugLog.record("listening history recovery started")
        let result = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        if result.listeningHistoryApplied > 0 {
            await PlaySessionTrackerActor(
                modelContainer: legacyContainer
            ).rebuildListeningStats()
        }
        StoreSplitMigrationDebugLog.record(
            "listening history recovery finished",
            details: "history=\(result.listeningHistoryApplied), failed=\(result.failed)"
        )
        return result
    }

    func importAvailableSplitStoreStateNow() async throws {
        await splitStoreCoordinator.runManualReconcile(authoritativePlaylists: true)
    }

    func runStoreSplitMigrationNowForDevelopment() async {
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        defaults.removeObject(forKey: Self.lastMigrationCompletedAtKey)
        defaults.removeObject(forKey: Self.lastMigrationHadFailuresKey)
        lastMigrationCompletedAt = nil
        await splitStoreCoordinator.runManualMigration()
    }

    /// Runs exactly one bounded slice on demand. Explicit developer action, so it
    /// bypasses the auto-run gate but still respects the heavy-work pause.
    func runOneMigrationSliceForDevelopment() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            pendingSplitStoreWorkReason = "paused for stability"
            return
        }
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        guard isMigratingSplitStores == false else { return }

        isMigratingSplitStores = true
        migrationError = nil
        let report = await StoreSplitMigrationService.runSlice(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer,
            shouldContinue: { true }
        )
        applyMigrationSliceTelemetry(report)
        if report.status == .completed {
            markMigrationCompleted(hadFailures: report.error != nil)
        }
        isMigratingSplitStores = false
    }
#endif

    func reconcileAvailableSplitStoreState(
        authoritativePlaylists: Bool = false,
        force: Bool = false,
        reason: String = "manual"
    ) async {
        _ = await performSplitStoreReconcile(
            authoritativePlaylists: authoritativePlaylists,
            force: force,
            refreshMissingFeeds: true,
            reason: reason
        )
    }

    enum SplitStoreReconcileOutcome: Equatable {
        case completed
        case deferredForPlayback
        case skipped
    }

    func performSplitStoreReconcile(
        authoritativePlaylists: Bool = false,
        force: Bool = false,
        refreshMissingFeeds: Bool = false,
        reason: String = "manual"
    ) async -> SplitStoreReconcileOutcome {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return .skipped
        }
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return .skipped
        }
        guard shouldRunUserStateImport(
            force: force || authoritativePlaylists,
            reason: reason
        ) else {
            if Player.shared.isPlaying {
                lastSplitStoreReconcileSummary = "Deferred while playback was active"
                return .deferredForPlayback
            }
            lastSplitStoreReconcileSummary = "Skipped reconcile: \(reason)"
            return .skipped
        }
        let result = await applySyncedUserStateIfPossible(
            authoritativePlaylists: authoritativePlaylists,
            refreshMissingFeeds: refreshMissingFeeds
        )
        lastSplitStoreReconcileAt = .now
        lastSplitStoreReconcileSummary =
            "Reconciled subscriptions \(result.subscriptionsApplied), states \(result.episodeStatesApplied), playlists \(result.playlistsApplied), bookmarks \(result.bookmarksApplied), history \(result.listeningHistoryApplied)"
        // An import is the one moment when playlist entries authored elsewhere —
        // including records that predate the tombstone rules — land in the local
        // queue. Re-assert "a played episode is not a queue member" right after.
        await prunePlayedPlaylistEntries()
        _ = legacyContainer
        _ = userStateContainer
        _ = cacheContainer
        return result.interruptedByPlayback ? .deferredForPlayback : .completed
    }

    /// Removes finished episodes that are still queued, and tombstones them so the
    /// removal survives the next CloudKit round trip.
    func prunePlayedPlaylistEntries() async {
        guard let legacyContainer = legacyMigrationSourceContainer else { return }
        await PlayedEpisodePlaylistPruner(legacyContainer: legacyContainer).prune()
    }

#if DEBUG
    // MARK: - Incident recovery (development builds only)
    //
    // Deduplication, tombstone recovery and store export exist to repair a
    // library that a CloudKit re-attach merged. Keeping them out of shipping
    // builds is safe only while nothing a user can install is able to detach or
    // re-attach the legacy store — today that is true, because the attachment is
    // decided solely by `StoreSplitReleasePhase.current`, the remote kill switch
    // cannot reach it, and no released build has ever changed it. The moment the
    // cutover ships, a release build can detach; these have to ship with it.

    /// Recomputes the hourly buckets and every `PlaySessionSummary` from the raw
    /// `PlaySession` rows.
    ///
    /// This is the analytics rebuild to reach for after a bad merge, and since
    /// the synced store stopped carrying aggregates it is the only thing that
    /// recomputes them: summaries are now a purely local derivation.
    func rebuildAnalyticsFromRawSessions() async throws {
        guard let legacyContainer = legacyMigrationSourceContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        await PlaySessionTrackerActor(modelContainer: legacyContainer)
            .rebuildListeningStats()
    }

    /// Collapses duplicate podcasts/episodes and repairs playlist membership.
    /// `dryRun` reports what would change without writing.
    func deduplicateLibrary(dryRun: Bool) async throws -> LibraryDeduplicationReport {
        guard let legacyContainer = legacyMigrationSourceContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await LibraryDeduplicationService(legacyContainer: legacyContainer)
            .run(dryRun: dryRun)
    }

    /// Reports where the queue currently lives, across both stores, plus the
    /// rollout state that decides which of them the app reads.
    func playlistTombstoneReport() async throws -> [String] {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        var lines = ["Rollout: \(storeSplitRolloutStateDescription)"]
        lines += await PlaylistTombstoneRecoveryService(
            userStateContainer: userStateContainer
        ).diagnosticsReport(legacyContainer: legacyMigrationSourceContainer)
        return lines
    }

    /// Clears playlist-entry tombstones stamped inside `window` and re-imports, so
    /// the queue is rebuilt from the UserState records that survived the removal.
    func restorePlaylistTombstones(
        deletedOnOrAfter cutoff: Date
    ) async throws -> PlaylistTombstoneRecoveryResult {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        let result = await PlaylistTombstoneRecoveryService(
            userStateContainer: userStateContainer
        ).restoreTombstones(deletedOnOrAfter: cutoff)
        guard result.restoredEntryCount + result.restoredQueueEntryCount > 0 else {
            return result
        }
        try await importAvailableSplitStoreStateNow()
        return result
    }
#endif

#if DEBUG
    func republishLegacyStateToCloudKit(
        scope: StoreSplitDevelopmentRepublishScope
    ) async throws
        -> StoreSplitDevelopmentRepublishResult {
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: scope
        )
    }

    func rebuildListeningSummariesForDevelopment() async throws
        -> StoreSplitMigrationPhaseResult {
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await Task.detached(priority: .utility) {
            StoreSplitMigrationService.rebuildListeningSummaries(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer
            )
        }.value
    }

    func splitStoreDevelopmentCounts() async throws
        -> StoreSplitDevelopmentStoreCounts {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await Task.detached(priority: .utility) {
            StoreSplitDevelopmentStoreCounts.read(from: userStateContainer)
        }.value
    }

    func resetSplitStoreDevelopmentData() async throws -> StoreSplitDevelopmentResetResult {
        guard isMigratingSplitStores == false,
              migrationTask == nil,
              aiContentImportTask == nil,
              userStateImportTask == nil else {
            throw StoreSplitDevelopmentResetError.workInProgress
        }

        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }

        developmentResetRequiresRelaunch = true
        do {
            let result = try await StoreSplitDevelopmentResetService.reset(
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
            let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
            defaults.removeObject(forKey: Self.lastMigrationCompletedAtKey)
            defaults.removeObject(forKey: Self.lastMigrationHadFailuresKey)
            lastMigrationCompletedAt = nil
            lastAIContentImportAt = nil
            migrationError = nil
            CrashBreadcrumbs.shared.record(
                "store_split_development_reset_completed",
                details: "user_state=\(result.userStateRecordsDeleted),cache=\(result.cacheRecordsDeleted)"
            )
            return result
        } catch {
            developmentResetRequiresRelaunch = false
            CrashBreadcrumbs.shared.record(
                "store_split_development_reset_failed",
                details: error.localizedDescription
            )
            throw error
        }
    }
#endif

    func performSplitStoreMigrationIfNeeded() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return
        }
        await prepareSplitStores()
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else {
            return
        }
        await runMigrationSliceLoop()
    }

    /// Drives the slice engine one bounded slice at a time. Between slices it
    /// yields to cancellation, playback, the live pause switch, and CloudKit
    /// export backpressure so the migration never overwhelms memory or the
    /// outbound CloudKit queue.
    private func runMigrationSliceLoop() async {
        if let migrationTask {
            await migrationTask.value
            return
        }
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }

        migrationError = nil
        isMigratingSplitStores = true
#if DEBUG
        StoreSplitMigrationDebugLog.requestAuthorizationIfNeeded()
        StoreSplitMigrationDebugLog.record(
            "migration run started",
            details: storeSplitMigrationStatus().map {
                "phase \($0.completedPhaseCount)/\($0.totalPhaseCount), scanned \($0.scannedItemCount)"
            }
        )
#endif
        let task = Task { @MainActor in
#if DEBUG
            var stopReason = "loop exited"
#endif
            defer {
                isMigratingSplitStores = false
                migrationTask = nil
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "migration run ended",
                    details: stopReason
                )
#endif
            }
            var exportWaitCount = 0
            var sliceCount = 0
            let deadline = Date().addingTimeInterval(
                self.isRunningBackgroundProcessingTask
                    ? Self.backgroundRunBudgetSeconds
                    : Self.foregroundRunBudgetSeconds
            )
            sliceLoop: while true {
                if Task.isCancelled {
                    CrashBreadcrumbs.shared.record("store_split_migration_cancelled")
#if DEBUG
                    stopReason = "cancelled"
#endif
                    break
                }
                if StoreDevelopmentConfiguration.migrationSlicePaused {
                    pendingSplitStoreWorkReason = "migration paused"
#if DEBUG
                    stopReason = "paused by the migration switch"
#endif
                    break
                }
                // Hard wall-clock budget. A slice is bounded in rows, but the
                // number of slices is not, and an unbudgeted loop saturated a
                // CPU for hours and was killed by the 80%-over-60s limit.
                if Date() >= deadline {
                    pendingSplitStoreWorkReason = "budget reached, continuing later"
                    scheduleMigrationRetry(after: Self.budgetExhaustedRetryDelay)
#if DEBUG
                    stopReason = "run budget reached after \(sliceCount) slices"
#endif
                    break
                }
                if Player.shared.isPlaying {
                    pendingSplitStoreWorkReason = "waiting for playback to stop"
#if DEBUG
                    stopReason = "playback started"
#endif
                    break
                }
                if migrationMayContinueInCurrentAppState() == false {
                    pendingSplitStoreWorkReason = "paused while app is in background"
#if DEBUG
                    stopReason = "app backgrounded"
#endif
                    break
                }
                if cloudKitExportInProgress() {
                    exportWaitCount += 1
                    pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
                    // Cap the wait so a stuck export does not pin a background
                    // task. Yielding here is common during the first big upload,
                    // so schedule our own retry rather than waiting for the next
                    // launch — otherwise a busy export could stall the backfill
                    // until the user happens to relaunch.
                    if exportWaitCount > 20 {
                        scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
#if DEBUG
                        stopReason = "yielded to CloudKit export, retrying in \(Int(Self.exportBackpressureRetryDelay))s"
#endif
                        break
                    }
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                exportWaitCount = 0

                let report = await StoreSplitMigrationService.runSlice(
                    legacyContainer: legacyContainer,
                    userStateContainer: userStateContainer,
                    cacheContainer: cacheContainer,
                    shouldContinue: { Task.isCancelled == false }
                )
                applyMigrationSliceTelemetry(report)

                switch report.status {
                case .completed:
                    markMigrationCompleted(hadFailures: report.error != nil)
#if DEBUG
                    stopReason = "all phases complete"
#endif
                    break sliceLoop
                case .failed:
                    if let error = report.error {
                        migrationError = error
                    }
#if DEBUG
                    stopReason = "slice failed: \(report.error ?? "unknown error")"
#endif
                    break sliceLoop
                case .cancelled:
#if DEBUG
                    stopReason = "slice cancelled"
#endif
                    break sliceLoop
                case .advanced, .phaseCompleted:
                    sliceCount += 1
                    await Task.yield()
                    // Deliberate idle time between slices. Without it the loop
                    // ran back-to-back SwiftData saves at ~98% CPU until iOS
                    // killed the process.
                    try? await Task.sleep(for: .seconds(Self.sliceSpacingSeconds))
                }
            }
        }
        migrationTask = task
        await task.value
    }

    /// Re-queues the backfill after a delay, so a run that yielded to CloudKit
    /// backpressure resumes on its own instead of waiting for the next launch.
    private func scheduleMigrationRetry(after delay: TimeInterval) {
        guard Self.hasPendingMigrationWork else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            await self?.scheduleStoreSplitMigrationIfNeeded()
        }
    }

    private func cloudKitExportInProgress() -> Bool {
        guard StoreDevelopmentConfiguration.userStateCloudSyncEnabled
            || StoreDevelopmentConfiguration.legacyCloudSyncEnabled else {
            return false
        }
        if case .inProgress = SyncMonitor.default.exportState {
            return true
        }
        return false
    }

    private func applyMigrationSliceTelemetry(_ report: StoreSplitSliceReport) {
        migrationCurrentPhase = report.phase
        migrationFootprintSummary =
            "\(MemoryFootprint.formatted(report.footprintAfter)) (\(report.footprintDeltaDescription))"
        if let error = report.error {
            migrationLastSliceError = error
        }
        if let status = storeSplitMigrationStatus() {
            migrationProgressSummary =
                "Phase \(status.completedPhaseCount)/\(status.totalPhaseCount), scanned \(status.scannedItemCount)"
            if let phase = report.phase,
               let cursor = status.phases.first(where: { $0.id == phase })?.cursor {
                migrationCursorSummary = cursor
            }
        }
#if DEBUG
        // Per-slice timing and footprint, so an expensive phase is identifiable
        // from the log instead of from a resource-exhaustion report.
        if let phase = report.phase {
            StoreSplitMigrationDebugLog.recordSlice(
                phase: phase,
                processed: report.processed,
                status: "\(report.status)",
                footprint: migrationFootprintSummary
            )
        }
        // Central hook: every path that runs a slice — the loop, the overnight
        // pass, and the single-slice development button — reports through here.
        if report.status == .phaseCompleted, let phase = report.phase {
            StoreSplitMigrationDebugLog.recordPhaseFinished(
                phase,
                progress: migrationProgressSummary
            )
        }
        if report.status == .failed {
            StoreSplitMigrationDebugLog.record(
                "slice failed",
                details: report.error ?? "unknown error"
            )
        }
#endif
    }

    private func markMigrationCompleted(hadFailures: Bool) {
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let completedAt = Date()
        lastMigrationCompletedAt = completedAt
        defaults.set(completedAt, forKey: Self.lastMigrationCompletedAtKey)
        defaults.set(hadFailures, forKey: Self.lastMigrationHadFailuresKey)
        // Lets the background-task scheduler decide whether to re-arm without
        // opening a container on the app's background-transition path.
        defaults.set(
            StoreSplitMigrationService.migrationVersion,
            forKey: Self.completedMigrationVersionKey
        )
        pendingSplitStoreWorkReason = nil
        currentSplitStoreJobDescription = nil
#if DEBUG
        StoreSplitMigrationDebugLog.record(
            "migration complete",
            details: "version \(StoreSplitMigrationService.migrationVersion), failures=\(hadFailures)"
        )
        StoreSplitMigrationDebugLog.notify(
            title: "Migration complete",
            body: "Every phase of v\(StoreSplitMigrationService.migrationVersion) finished\(hadFailures ? " with failures" : "")."
        )
#endif
        if let cacheContainer = preparedCacheContainer,
           StoreSplitMigrationService.isMigrationVerified(
               cacheContainer: cacheContainer
           ) {
            // Close the disk source as soon as lossless verification succeeds.
            // The SQLite files stay untouched until the independent cleanup gate.
            preparedLegacyMigrationContainer = nil
        }
    }

    private func applySyncedUserStateIfPossible(
        authoritativePlaylists: Bool = false,
        refreshMissingFeeds: Bool = false
    ) async -> StoreSplitUserStateImportResult {
        let emptyResult = StoreSplitUserStateImportResult()
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return emptyResult
        }
        guard StoreDevelopmentConfiguration.userStateImportEnabled else { return emptyResult }
        if let userStateImportTask {
            _ = await userStateImportTask.value
        }
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            return emptyResult
        }

        // A full projection pass walks every synchronized row and rebuilds the
        // listening stats. That is hundreds of megabytes of SQLite writes on a
        // large library, and reconciles are triggered by launch, foreground, and
        // every CloudKit import event — so repeating it when nothing arrived
        // dirtied ~17 GB overnight. Skip the pass unless UserState actually
        // changed since the last complete import.
        let watermark = latestUserStateChangeStamp(userStateContainer)
        if authoritativePlaylists == false,
           let watermark,
           let lastImported = Self.lastImportedUserStateStamp,
           watermark <= lastImported {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "no_user_state_changes"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "reconcile skipped",
                details: "no UserState changes since the last import"
            )
#endif
            return emptyResult
        }

        lastUserStateImportAt = .now
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_started",
            details: "authoritative_playlists=\(authoritativePlaylists),refresh_missing_feeds=\(refreshMissingFeeds)"
        )
        let task = Task {
            // The importer's SQLite write is the checkpoint-critical section, so
            // the background-task assertion is held ONLY around it: a mid-reconcile
            // backgrounding still reaches a safe checkpoint and releases the
            // shared-container lock (instead of 0xdead10cc). Network feed
            // bootstrapping is deliberately not covered by the assertion and is
            // skipped once the task is cancelled (i.e. backgrounded), so the
            // assertion is never held for tens of seconds in the background.
            func runImport() async -> StoreSplitUserStateImportResult {
                await self.withUserStateImportAssertion {
                    await StoreSplitUserStateImporter.apply(
                        legacyContainer: legacyContainer,
                        userStateContainer: userStateContainer,
                        authoritativePlaylists: authoritativePlaylists,
                        projectListeningHistoryToLegacy: StoreDevelopmentConfiguration
                            .projectsListeningHistoryToLegacy,
                        episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                            .episodeStateProjectionRecencyCutoff
                    )
                }
            }

            let result = await runImport()

            // Only bootstrap missing feeds over the network while foreground and
            // not cancelled; otherwise defer to the next foreground reconcile.
            guard refreshMissingFeeds,
                  result.feedsToBootstrap.isEmpty == false,
                  Task.isCancelled == false else {
                return result
            }

            // Playlist entries are not renderable until their episode feed is
            // present in the legacy UI graph. Prioritize those feeds over the
            // much larger episode-state backlog, while retaining a strict cap.
            let priorityFeeds = result.playlistFeedsToBootstrap
            let maxFeedsPerPass = priorityFeeds.isEmpty
                ? 5
                : min(15, max(5, priorityFeeds.count))
            let retryInterval: TimeInterval = 60 * 15
            let now = Date()
            var seenFeedKeys = Set<String>()
            let dueFeeds = (priorityFeeds + result.feedsToBootstrap).filter { feed in
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                guard seenFeedKeys.insert(key).inserted else { return false }
                guard let lastAttempt = self.missingFeedRefreshAttempts[key] else {
                    return true
                }
                return now.timeIntervalSince(lastAttempt) >= retryInterval
            }
            let feedsToRefresh = Array(dueFeeds.prefix(maxFeedsPerPass))

            var didRefreshAny = false
            for feed in feedsToRefresh {
                if Task.isCancelled { break }
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                self.missingFeedRefreshAttempts[key] = now
                do {
                    let refreshed = try await PodcastModelActor(
                        modelContainer: legacyContainer
                    ).updatePodcast(feed, force: true, silent: true)
                    didRefreshAny = true
                    if refreshed == false {
                        self.missingFeedRefreshAttempts.removeValue(forKey: key)
                    }
                } catch {
                    self.missingFeedRefreshAttempts.removeValue(forKey: key)
                }
            }
            if didRefreshAny, Task.isCancelled == false {
                return await runImport()
            }
            return result
        }
        userStateImportTask = task
        let result = await task.value
        userStateImportTask = nil
        // Only rebuild the hourly statistics when history actually moved.
        // Rebuilding after every reconcile rewrote the whole stats table for no
        // reason and was a large part of the write volume.
        if result.listeningHistoryApplied > 0 {
            await PlaySessionTrackerActor(
                modelContainer: legacyContainer
            ).rebuildListeningStats()
        }
        await StoreSplitPlaylistPresenceStore.publish(
            modelContainer: userStateContainer
        )
        if result.failed == 0, result.interruptedByPlayback == false {
            Self.lastImportedUserStateStamp = watermark
        }
#if DEBUG
        StoreSplitMigrationDebugLog.record(
            "reconcile finished",
            details: "subscriptions=\(result.subscriptionsApplied), states=\(result.episodeStatesApplied), playlists=\(result.playlistsApplied), history=\(result.listeningHistoryApplied), failed=\(result.failed)"
        )
#endif
        return result
    }

    /// Newest `updatedAt` across the synchronized models — a cheap change token
    /// for "has anything arrived since the last import?".
    private func latestUserStateChangeStamp(_ container: ModelContainer) -> Date? {
        let context = ModelContext(container)
        func newest<Model: PersistentModel>(
            _ keyPath: KeyPath<Model, Date> & Sendable
        ) -> Date? {
            var descriptor = FetchDescriptor<Model>(
                sortBy: [SortDescriptor(keyPath, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first?[keyPath: keyPath]
        }
        return [
            newest(\SubscriptionSync.updatedAt),
            newest(\EpisodeStateSync.updatedAt),
            newest(\PlaylistSync.updatedAt),
            newest(\PlaylistEntrySync.updatedAt),
            newest(\QueueEntrySync.updatedAt),
            newest(\BookmarkSync.updatedAt),
            newest(\PodcastPreferenceSync.updatedAt),
            newest(\ListeningHistorySync.updatedAt),
            newest(\ListeningBaselineSync.capturedAt)
        ].compactMap { $0 }.max()
    }

    nonisolated private static var lastImportedUserStateStamp: Date? {
        get {
            (UserDefaults(suiteName: appGroupID) ?? .standard)
                .object(forKey: lastImportedUserStateStampKey) as? Date
        }
        set {
            (UserDefaults(suiteName: appGroupID) ?? .standard)
                .set(newValue, forKey: lastImportedUserStateStampKey)
        }
    }

    /// Runs `body` while holding a UIKit background-task assertion named
    /// `StoreSplitUserStateImport`, ending it as soon as `body` returns. Scoping
    /// the assertion to just the SQLite-critical import keeps it from being held
    /// for tens of seconds (and risking termination) during background network work.
    private func withUserStateImportAssertion<T>(
        _ body: () async -> T
    ) async -> T {
#if canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "StoreSplitUserStateImport"
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.userStateImportTask?.cancel()
            }
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
        return await body()
#else
        return await body()
#endif
    }

    private func shouldRunUserStateImport(
        force: Bool,
        reason: String
    ) -> Bool {
        if force {
            return true
        }

        if Player.shared.isPlaying {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "\(reason):player_session_active"
            )
            return false
        }

        if let lastUserStateImportAt,
           Date().timeIntervalSince(lastUserStateImportAt)
            < minimumForegroundUserStateImportInterval {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "\(reason):recently_ran"
            )
            return false
        }

        return true
    }

    func performSplitStoreAIImportIfPossible() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return
        }
        await applyCachedAIContentIfPossible()
    }

    private func applyCachedAIContentIfPossible() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        if let aiContentImportTask {
            await aiContentImportTask.value
            return
        }
        guard let legacyContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        if let lastAIContentImportAt,
           Date().timeIntervalSince(lastAIContentImportAt) < minimumAIContentImportInterval {
            return
        }

        let task = Task {
            _ = await StoreSplitAIContentImporter.apply(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
        }
        aiContentImportTask = task
        await task.value
        lastAIContentImportAt = .now
        aiContentImportTask = nil
    }

    func updateSplitStoreCoordinatorState(
        currentJob: String?,
        pendingReason: String?
    ) {
        currentSplitStoreJobDescription = currentJob
        pendingSplitStoreWorkReason = pendingReason
    }

    private func apply(
        _ result: Result<ModelContainer, Error>,
        to containerKeyPath: ReferenceWritableKeyPath<ModelContainerManager, ModelContainer?>,
        error errorKeyPath: ReferenceWritableKeyPath<ModelContainerManager, String?>,
        storeName: String
    ) {
        switch result {
        case let .success(container):
            self[keyPath: containerKeyPath] = container
            CrashBreadcrumbs.shared.record("store_split_container_ready", details: storeName)
        case let .failure(error):
            self[keyPath: errorKeyPath] = error.localizedDescription
            CrashBreadcrumbs.shared.record(
                "store_split_container_initialization_failed",
                details: "\(storeName):\(error.localizedDescription)"
            )
        }
    }

    nonisolated static func makeLegacyContainer(
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        // Only a container that actually opened tells us what the store is
        // attached to. Recording before the open would let a failed launch leave
        // behind a decision the store never saw, which is enough to disarm the
        // re-attach guard on the following launch.
        var legacyCloudSyncToRecord: Bool?
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        } else if let sharedContainerURL = sharedContainerURL {
            // The library graph keeps its CloudKit mirror through the
            // `dualSyncBackfill` release, so existing users' cross-device
            // behaviour is untouched while UserState is being built up. Ship #2
            // flips `StoreSplitReleasePhase.current` and this becomes `.none`,
            // which is the change that actually shrinks the iCloud payload.
            let legacyCloudSyncApplied =
                StoreDevelopmentConfiguration.legacyCloudSyncEnabled
            legacyCloudSyncToRecord = legacyCloudSyncApplied
            configuration = ModelConfiguration(
                "Legacy",
                url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
                allowsSave: allowsSave,
                cloudKitDatabase: legacyCloudSyncApplied ? .automatic : .none
            )
        } else {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        }

        let container = try ModelContainer(
            for: Podcast.self,
                PodcastMetaData.self,
                Episode.self,
                EpisodeMetaData.self,
                Playlist.self,
                PlaylistEntry.self,
                Marker.self,
                Bookmark.self,
                RateSegment.self,
                PlaySession.self,
                ListeningStat.self,
                PlaySessionSummary.self,
                TranscriptionRecord.self,
            configurations: configuration
        )
        // Remember what was actually applied, so the next launch can tell an
        // off→on re-attach from a store that has always been mirrored.
        if let legacyCloudSyncToRecord {
            StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(
                legacyCloudSyncToRecord
            )
        }
        return container
    }

    nonisolated static func makeRuntimeContainer() throws -> ModelContainer {
        try makeLegacyContainer(isStoredInMemoryOnly: runtimeUsesCacheProjection)
    }

    nonisolated static func makeUserStateContainer(
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            SubscriptionSync.self,
            EpisodeStateSync.self,
            QueueEntrySync.self,
            PlaylistSync.self,
            PlaylistEntrySync.self,
            BookmarkSync.self,
            PodcastPreferenceSync.self,
            ListeningBaselineSync.self,
            ListeningHistorySync.self
        ])
        let configuration: ModelConfiguration

        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let userStateStoreURL {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                url: userStateStoreURL,
                cloudKitDatabase: StoreDevelopmentConfiguration.userStateCloudSyncEnabled
                    ? .automatic
                    : .none
            )
        } else {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(for: schema, configurations: configuration)
    }

    nonisolated static func makeCacheContainer(
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            StoreSplitMigrationCheckpoint.self,
            StoreSplitMigrationVerification.self,
            CachedFeedExtensionElement.self,
            AppliedAIContentRevision.self,
            CachedPodcast.self,
            CachedEpisode.self,
            CachedChapter.self,
            CachedTranscriptLine.self,
            CachedTranscriptionRecord.self,
            CachedDownloadRecord.self,
            CachedPlaySession.self,
            CachedRateSegment.self,
            CachedHourlyListeningStat.self,
            AITranscriptSync.self,
            AITranscriptChunkSync.self,
            AIChapterSetSync.self,
            FeedAlias.self
        ])
        let configuration: ModelConfiguration

        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let cacheStoreURL {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                url: cacheStoreURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(for: schema, configurations: configuration)
    }
}

#if DEBUG
enum StoreSplitDevelopmentResetError: LocalizedError {
    case workInProgress
    case storesUnavailable

    var errorDescription: String? {
        switch self {
        case .workInProgress:
            "Migration or synchronization work is still running. Try again in a moment."
        case .storesUnavailable:
            "The split stores could not be opened."
        }
    }
}
#endif

private struct SplitStoreContainers: @unchecked Sendable {
    let userState: Result<ModelContainer, Error>?
    let cache: Result<ModelContainer, Error>?
}
