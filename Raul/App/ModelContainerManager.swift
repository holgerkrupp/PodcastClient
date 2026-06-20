import SwiftData
import SwiftUI

@MainActor
class ModelContainerManager: ObservableObject {
    nonisolated static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    @Published private(set) var preparedContainer: ModelContainer?
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
#if DEBUG
    @Published private(set) var developmentResetRequiresRelaunch = false
#endif
    private var preparationTask: Task<ModelContainer, Error>?
    private var splitStorePreparationTask: Task<SplitStoreContainers, Never>?
    private var migrationTask: Task<Void, Never>?
    private var aiContentImportTask: Task<Void, Never>?
    private var userStateImportTask: Task<StoreSplitUserStateImportResult, Never>?
    private var missingFeedRefreshAttempts: [String: Date] = [:]
    private var lastMigrationCompletedAt: Date?
    private var lastAIContentImportAt: Date?
    private var lastUserStateImportAt: Date?
    private let successfulMigrationRerunInterval: TimeInterval = 60 * 60 * 24
    private let failedMigrationRerunInterval: TimeInterval = 60 * 60
    private let minimumAIContentImportInterval: TimeInterval = 60 * 15
    private let minimumForegroundUserStateImportInterval: TimeInterval = 60 * 10
    private let splitStoreCoordinator = StoreSplitWorkCoordinator.shared
    nonisolated private static let lastMigrationCompletedAtKey =
        "storeSplitMigration.lastCompletedAt.v3"
    nonisolated private static let lastMigrationHadFailuresKey =
        "storeSplitMigration.lastRunHadFailures.v3"

    var container: ModelContainer {
        guard let preparedContainer else {
            preconditionFailure("ModelContainer accessed before preparation completed")
        }
        return preparedContainer
    }
    
    static let shared = ModelContainerManager()

    init() {
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
            if resetAllStores {
                clearMigrationRunState()
            }
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
            requiresInitialCloudImport =
                StoreDevelopmentConfiguration.legacyCloudSyncEnabled
                && (Self.sharedStoreURL.map {
                    !FileManager.default.fileExists(atPath: $0.path)
                } ?? false)
            CrashBreadcrumbs.shared.record("model_container_initialization_started")

            let newTask = Task.detached(priority: .userInitiated) {
                try Self.makeLegacyContainer()
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
        CrashBreadcrumbs.shared.record(
            "store_split_container_initialization_completed",
            details: "user_state=\(preparedUserStateContainer != nil),cache=\(preparedCacheContainer != nil)"
        )
    }

    func runStoreSplitMigration() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else { return }
#endif
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            migrationError = nil
            currentSplitStoreJobDescription = nil
            pendingSplitStoreWorkReason = "paused for stability"
            return
        }
        await splitStoreCoordinator.scheduleForegroundMigration()
    }

    func runLaunchStoreMaintenance() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else { return }
#endif
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return
        }
        await prepareSplitStores()
        guard StoreDevelopmentConfiguration.splitStoresEnabled else { return }
        await splitStoreCoordinator.scheduleLaunchWork()
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
    func importAvailableSplitStoreStateNow() async throws {
        await splitStoreCoordinator.runManualReconcile(authoritativePlaylists: true)
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
        _ = legacyContainer
        _ = userStateContainer
        _ = cacheContainer
        return result.interruptedByPlayback ? .deferredForPlayback : .completed
    }

#if DEBUG
    func republishLegacyStateToCloudKit(
        scope: StoreSplitDevelopmentRepublishScope
    ) async throws
        -> StoreSplitDevelopmentRepublishResult {
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: scope
        )
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

    private func startMigrationIfPossible() {
        guard migrationTask == nil,
              let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let persistedCompletionDate = defaults.object(
            forKey: Self.lastMigrationCompletedAtKey
        ) as? Date
        let previousCompletionDate = lastMigrationCompletedAt ?? persistedCompletionDate
        let previousRunHadFailures = defaults.bool(forKey: Self.lastMigrationHadFailuresKey)
        let rerunInterval = previousRunHadFailures
            ? failedMigrationRerunInterval
            : successfulMigrationRerunInterval

        if let previousCompletionDate,
           Date().timeIntervalSince(previousCompletionDate) < rerunInterval {
            return
        }

        migrationError = nil
        isMigratingSplitStores = true
        migrationTask = Task { @MainActor in
            let result = await StoreSplitMigrationService.migrate(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
            if result.failedCount > 0 {
                migrationError = "\(result.failedCount) migration item(s) failed"
            }
            let completedAt = Date()
            lastMigrationCompletedAt = completedAt
            defaults.set(completedAt, forKey: Self.lastMigrationCompletedAtKey)
            defaults.set(
                result.failedCount > 0,
                forKey: Self.lastMigrationHadFailuresKey
            )
            isMigratingSplitStores = false
            migrationTask = nil
        }
    }

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
        startMigrationIfPossible()
        if let migrationTask {
            await migrationTask.value
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
        guard StoreDevelopmentConfiguration.newStoreReadsEnabled else { return emptyResult }
        if let userStateImportTask {
            _ = await userStateImportTask.value
        }
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            return emptyResult
        }

        lastUserStateImportAt = .now
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_started",
            details: "authoritative_playlists=\(authoritativePlaylists),refresh_missing_feeds=\(refreshMissingFeeds)"
        )
        let task = Task {
            let result = await StoreSplitUserStateImporter.apply(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                authoritativePlaylists: authoritativePlaylists,
                projectListeningHistoryToLegacy: StoreDevelopmentConfiguration
                    .projectsListeningHistoryToLegacy,
                episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                    .episodeStateProjectionRecencyCutoff
            )
            guard refreshMissingFeeds, result.feedsToBootstrap.isEmpty == false else {
                return result
            }

            let retryInterval: TimeInterval = 60 * 15
            let now = Date()
            let feedsToRefresh = result.feedsToBootstrap.filter { feed in
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                guard let lastAttempt = self.missingFeedRefreshAttempts[key] else {
                    self.missingFeedRefreshAttempts[key] = now
                    return true
                }
                guard now.timeIntervalSince(lastAttempt) >= retryInterval else {
                    return false
                }
                self.missingFeedRefreshAttempts[key] = now
                return true
            }
            for feed in feedsToRefresh {
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                do {
                    let refreshed = try await PodcastModelActor(
                        modelContainer: legacyContainer
                    ).updatePodcast(feed, force: true, silent: true)
                    if refreshed == false {
                        self.missingFeedRefreshAttempts.removeValue(forKey: key)
                    }
                } catch {
                    self.missingFeedRefreshAttempts.removeValue(forKey: key)
                }
            }
            if feedsToRefresh.isEmpty == false {
                return await StoreSplitUserStateImporter.apply(
                    legacyContainer: legacyContainer,
                    userStateContainer: userStateContainer,
                    authoritativePlaylists: authoritativePlaylists,
                    projectListeningHistoryToLegacy: StoreDevelopmentConfiguration
                        .projectsListeningHistoryToLegacy,
                    episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                        .episodeStateProjectionRecencyCutoff
                )
            }
            return result
        }
        userStateImportTask = task
        let result = await task.value
        userStateImportTask = nil
        return result
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
        await applySyncedAIContentIfPossible()
    }

    private func applySyncedAIContentIfPossible() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        if let aiContentImportTask {
            await aiContentImportTask.value
            return
        }
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer,
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
                userStateContainer: userStateContainer,
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
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let sharedContainerURL = sharedContainerURL {
            configuration = ModelConfiguration(
                "Legacy",
                url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
                cloudKitDatabase: StoreDevelopmentConfiguration.legacyCloudSyncEnabled
                    ? .automatic
                    : .none
            )
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }

        return try ModelContainer(
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
            ListeningSummarySync.self,
            ListeningHistorySync.self,
            AITranscriptSync.self,
            AITranscriptChunkSync.self,
            AIChapterSetSync.self
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
            CachedFeedExtensionElement.self,
            AppliedAIContentRevision.self
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
