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
    private var preparationTask: Task<ModelContainer, Error>?
    private var splitStorePreparationTask: Task<SplitStoreContainers, Never>?
    private var migrationTask: Task<Void, Never>?
    private var aiContentImportTask: Task<Void, Never>?
    private var lastMigrationCompletedAt: Date?
    private var lastAIContentImportAt: Date?
    private let successfulMigrationRerunInterval: TimeInterval = 60 * 60 * 24
    private let failedMigrationRerunInterval: TimeInterval = 60 * 60
    private let minimumAIContentImportInterval: TimeInterval = 60 * 15
    private static let lastMigrationCompletedAtKey = "storeSplitMigration.lastCompletedAt.v3"
    private static let lastMigrationHadFailuresKey = "storeSplitMigration.lastRunHadFailures.v3"

    var container: ModelContainer {
        guard let preparedContainer else {
            preconditionFailure("ModelContainer accessed before preparation completed")
        }
        return preparedContainer
    }
    
    static let shared = ModelContainerManager()

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

    
    func prepareContainer() async {
        guard preparedContainer == nil else { return }

        let task: Task<ModelContainer, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            isInitializing = true
            initializationError = nil
            requiresInitialCloudImport = Self.sharedStoreURL.map {
                !FileManager.default.fileExists(atPath: $0.path)
            } ?? false
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
        await prepareSplitStores()
        startMigrationIfPossible()
        if let migrationTask {
            await migrationTask.value
        }
        await applySyncedAIContentIfPossible()
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
            await applySyncedAIContentIfPossible()
        }
    }

    private func applySyncedAIContentIfPossible() async {
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
                cloudKitDatabase: .automatic
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
                cloudKitDatabase: .automatic
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

private struct SplitStoreContainers: @unchecked Sendable {
    let userState: Result<ModelContainer, Error>?
    let cache: Result<ModelContainer, Error>?
}
