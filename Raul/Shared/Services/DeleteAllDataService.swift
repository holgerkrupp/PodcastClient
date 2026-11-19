import CloudKit
import Foundation
import SwiftData

struct DeleteAllDataResult: Sendable {
    let localDataCleared: Bool
    let iCloudDeletionPending: Bool
    let message: String
}

enum DeleteAllDataServiceError: LocalizedError {
    case storesUnavailable
    case localCleanupFailed

    var errorDescription: String? {
        switch self {
        case .storesUnavailable:
            "Up Next could not open its data stores. Nothing was deleted. Try again when storage is available."
        case .localCleanupFailed:
            "Some Up Next data could not be cleared. The reset will retry when you open the app again."
        }
    }
}

/// Coordinates an account-scoped reset fence with an idempotent local cleanup.
/// The small CloudKit control record is deliberately retained: it fences stale
/// UserState and subscription-manifest copies on devices that reconnect later.
enum DeleteAllDataService {
    private static let cloudContainerID = "iCloud.de.holgerkrupp.PodcastClient"
    private static let fenceRecordType = "UpNextLibraryResetFence"
    private static let fenceRecordName = "library-reset-v1"
    private static let appGroup = ModelContainerManager.appGroupID
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    private static let appliedGenerationKey = "deleteAllData.appliedGeneration.v1"
    private static let pendingGenerationKey = "deleteAllData.pendingGeneration.v1"
    private static let pendingAccountKey = "deleteAllData.pendingAccount.v1"
    private static let pendingOperationKey = "deleteAllData.pendingOperation.v1"
    private static let expectedCloudAccountKey = "deleteAllData.expectedCloudAccount.v1"
    private static let resetOccurredKey = "deleteAllData.didReset.v1"
    private static let resetStartedAtKey = "deleteAllData.resetStartedAt.v1"
    private static let cloudResetPendingKey = "deleteAllData.cloudResetPending.v1"
    private static let cloudFenceSavedKey = "deleteAllData.cloudFenceSaved.v1"
    private static let exportBaselineEventIDKey = "deleteAllData.exportBaselineEventID.v1"

    struct Fence: Sendable, Equatable {
        let generation: Int64
        let operationID: String
        let accountRecordName: String
    }

    struct ResetIntent: Sendable {
        let generation: Int64
        let operationID: String
    }

    enum CloudResult: Sendable {
        case saved(Fence)
        case pending(Fence?)
    }

    static var hasEverReset: Bool {
        defaults.bool(forKey: resetOccurredKey)
    }

    static var appliedGeneration: Int64 {
        defaults.object(forKey: appliedGenerationKey) as? Int64 ?? 0
    }

    static var hasPendingLocalReset: Bool {
        (defaults.object(forKey: pendingGenerationKey) as? Int64 ?? 0) > appliedGeneration
    }

    static var resetStartedAt: Date? {
        defaults.object(forKey: resetStartedAtKey) as? Date
    }

    static var hasPendingCloudReset: Bool {
        defaults.bool(forKey: cloudResetPendingKey)
    }

    static var hasSavedCloudFence: Bool {
        defaults.bool(forKey: cloudFenceSavedKey)
    }

    static var canRetryPendingCloudReset: Bool {
        defaults.string(forKey: expectedCloudAccountKey) != nil
            || (defaults.string(forKey: pendingAccountKey) != nil
                && defaults.string(forKey: pendingOperationKey) != nil)
    }

    static var exportBaselineEventID: UUID? {
        defaults.string(forKey: exportBaselineEventIDKey).flatMap(UUID.init(uuidString:))
    }

    static func setExportBaselineEventID(_ eventID: UUID?) {
        defaults.set(eventID?.uuidString, forKey: exportBaselineEventIDKey)
    }

    static func acknowledgeCloudResetExported() {
        defaults.set(false, forKey: cloudResetPendingKey)
        defaults.removeObject(forKey: exportBaselineEventIDKey)
        defaults.removeObject(forKey: expectedCloudAccountKey)
    }

    static func acknowledgeNoCloudResetRequired() {
        defaults.set(false, forKey: cloudResetPendingKey)
        defaults.set(true, forKey: cloudFenceSavedKey)
        defaults.removeObject(forKey: expectedCloudAccountKey)
    }

    /// Runs before the CloudKit-backed SwiftData container opens. A remote fence
    /// is copied to local durable state so launch cleanup can finish before the
    /// library is exposed to normal reconciliation.
    static func fetchNewRemoteFence() async -> Fence? {
        do {
            let container = CKContainer(identifier: cloudContainerID)
            let account = try await container.userRecordID()
            let database = container.privateCloudDatabase
            let id = CKRecord.ID(recordName: fenceRecordName)
            let record: CKRecord
            do {
                record = try await database.record(for: id)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
            guard let generation = record["generation"] as? Int64,
                  let operationID = record["operationID"] as? String,
                  let accountName = record["accountRecordName"] as? String,
                  accountName == account.recordName else { return nil }
            let fence = Fence(
                generation: generation,
                operationID: operationID,
                accountRecordName: accountName
            )
            guard generation > appliedGeneration else { return nil }
            persistPending(fence)
            return fence
        } catch {
            // Account or network unavailability is recoverable. A prior local
            // reset remains pending and is retried after the next activation.
            return nil
        }
    }

    /// Records user intent before doing destructive local work. The fence is
    /// retried under the same account if CloudKit is temporarily unavailable.
    static func prepareResetIntent() -> ResetIntent {
        let prior = max(appliedGeneration, defaults.object(forKey: pendingGenerationKey) as? Int64 ?? 0)
        let generation = max(Int64(Date().timeIntervalSince1970 * 1_000), prior + 1)
        let operationID = UUID().uuidString
        defaults.set(Date(), forKey: resetStartedAtKey)
        defaults.set(true, forKey: cloudResetPendingKey)
        defaults.set(false, forKey: cloudFenceSavedKey)
        defaults.set(generation, forKey: pendingGenerationKey)
        defaults.set(operationID, forKey: pendingOperationKey)
        defaults.removeObject(forKey: pendingAccountKey)
        defaults.removeObject(forKey: expectedCloudAccountKey)
        defaults.set(true, forKey: resetOccurredKey)
        return ResetIntent(generation: generation, operationID: operationID)
    }

    static func beginReset(_ intent: ResetIntent) async -> CloudResult {
        let generation = intent.generation
        let operationID = intent.operationID
        do {
            let container = CKContainer(identifier: cloudContainerID)
            let account = try await container.userRecordID()
            let fence = Fence(
                generation: generation,
                operationID: operationID,
                accountRecordName: account.recordName
            )
            persistPending(fence)
            try await save(fence, in: container.privateCloudDatabase)
            defaults.set(true, forKey: cloudFenceSavedKey)
            return .saved(fence)
        } catch {
            let accountName = try? await CKContainer(identifier: cloudContainerID).userRecordID().recordName
            let fence = accountName.map {
                Fence(generation: generation, operationID: operationID, accountRecordName: $0)
            }
            if let fence { persistPending(fence) }
            else {
                defaults.set(generation, forKey: pendingGenerationKey)
                defaults.set(operationID, forKey: pendingOperationKey)
                defaults.removeObject(forKey: pendingAccountKey)
                defaults.set(true, forKey: resetOccurredKey)
            }
            return .pending(fence)
        }
    }

    static func retryPendingFence() async -> Bool {
        guard let generation = defaults.object(forKey: pendingGenerationKey) as? Int64,
              let operationID = defaults.string(forKey: pendingOperationKey),
              let accountName = defaults.string(forKey: pendingAccountKey) else { return false }
        do {
            let container = CKContainer(identifier: cloudContainerID)
            let currentAccount = try await container.userRecordID()
            guard currentAccount.recordName == accountName else { return false }
            let fence = Fence(
                generation: generation,
                operationID: operationID,
                accountRecordName: accountName
            )
            try await save(fence, in: container.privateCloudDatabase)
            defaults.set(true, forKey: cloudFenceSavedKey)
            acknowledgeFenceSaved()
            return true
        } catch {
            return false
        }
    }

    static func acknowledgeFenceSaved() {
        defaults.removeObject(forKey: pendingGenerationKey)
        defaults.removeObject(forKey: pendingOperationKey)
    }

    static func isOriginalCloudAccountAvailable() async -> Bool {
        guard let expectedAccount = defaults.string(forKey: expectedCloudAccountKey)
            ?? defaults.string(forKey: pendingAccountKey) else { return false }
        do {
            let currentAccount = try await CKContainer(identifier: cloudContainerID).userRecordID()
            return currentAccount.recordName == expectedAccount
        } catch {
            return false
        }
    }

    static func clearLocalData(
        library: ModelContainer,
        userState: ModelContainer,
        appGroupContainerURL: URL?
    ) async throws {
        do {
            try await LocalDataCleaner(
                library: library,
                userState: userState,
                appGroupContainerURL: appGroupContainerURL
            ).run()
            defaults.set(true, forKey: resetOccurredKey)
            let generation = defaults.object(forKey: pendingGenerationKey) as? Int64 ?? appliedGeneration
            defaults.set(generation, forKey: appliedGenerationKey)
        } catch {
            defaults.set(true, forKey: resetOccurredKey)
            CrashBreadcrumbs.shared.record("delete_all_data_local_cleanup_failed")
            throw DeleteAllDataServiceError.localCleanupFailed
        }
    }

    private static func persistPending(_ fence: Fence) {
        defaults.set(fence.generation, forKey: pendingGenerationKey)
        defaults.set(fence.operationID, forKey: pendingOperationKey)
        defaults.set(fence.accountRecordName, forKey: pendingAccountKey)
        defaults.set(fence.accountRecordName, forKey: expectedCloudAccountKey)
        defaults.set(true, forKey: resetOccurredKey)
        defaults.set(true, forKey: cloudResetPendingKey)
        defaults.set(true, forKey: cloudFenceSavedKey)
        if defaults.object(forKey: resetStartedAtKey) == nil {
            defaults.set(Date(), forKey: resetStartedAtKey)
        }
    }

    private static func save(_ fence: Fence, in database: CKDatabase) async throws {
        let id = CKRecord.ID(recordName: fenceRecordName)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: fenceRecordType, recordID: id)
        }
        let currentGeneration = record["generation"] as? Int64 ?? 0
        guard currentGeneration <= fence.generation else { return }
        record["generation"] = fence.generation as CKRecordValue
        record["operationID"] = fence.operationID as CKRecordValue
        record["accountRecordName"] = fence.accountRecordName as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        _ = try await database.save(record)
    }
}

private actor LocalDataCleaner {
    private let library: ModelContainer
    private let userState: ModelContainer
    private let appGroupContainerURL: URL?

    init(library: ModelContainer, userState: ModelContainer, appGroupContainerURL: URL?) {
        self.library = library
        self.userState = userState
        self.appGroupContainerURL = appGroupContainerURL
    }

    func run() async throws {
        let libraryContext = ModelContext(library)
        let userStateContext = ModelContext(userState)
        libraryContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false

        // Capture episode-to-file associations before deleting the models.
        let storageReport = try await StorageManagementService(modelContainer: library).makeReport()

        // Delete children and portable references before their owning rows.
        try deleteAll(Bookmark.self, from: libraryContext)
        try deleteAll(Marker.self, from: libraryContext)
        try deleteAll(PlaylistEntry.self, from: libraryContext)
        try deleteAll(RateSegment.self, from: libraryContext)
        try deleteAll(PlaySession.self, from: libraryContext)
        try deleteAll(PlaySessionSummary.self, from: libraryContext)
        try deleteAll(ListeningStat.self, from: libraryContext)
        try deleteAll(TranscriptionRecord.self, from: libraryContext)
        try deleteAll(CachedTranscriptAlignment.self, from: libraryContext)
        try deleteAll(CachedTranscriptSynchronizationJob.self, from: libraryContext)
        try deleteAll(CachedMissingEpisodeReference.self, from: libraryContext)
        try deleteAll(EpisodeMetaData.self, from: libraryContext)
        try deleteAll(Episode.self, from: libraryContext)
        try deleteAll(PodcastMetaData.self, from: libraryContext)
        try deleteAll(Podcast.self, from: libraryContext)
        try deleteAll(Playlist.self, from: libraryContext)
        try libraryContext.delete(model: PodcastSettings.self)

        try deleteAll(PlaybackSessionSync.self, from: userStateContext)
        try deleteAll(EpisodeStateSync.self, from: userStateContext)
        try deleteAll(QueueEntrySync.self, from: userStateContext)
        try deleteAll(PlaylistEntrySync.self, from: userStateContext)
        try deleteAll(PlaylistSync.self, from: userStateContext)
        try deleteAll(BookmarkSync.self, from: userStateContext)
        try deleteAll(ListeningHistorySync.self, from: userStateContext)
        try deleteAll(ListeningBaselineSync.self, from: userStateContext)
        try deleteAll(PodcastPreferenceSync.self, from: userStateContext)
        try deleteAll(SubscriptionSync.self, from: userStateContext)
        try libraryContext.save()
        try userStateContext.save()

        // These report only app-owned media/cache files. The exported package
        // lives in the user-selected destination and is never enumerated here.
        for file in storageReport.files {
            guard FileManager.default.fileExists(atPath: file.url.path) else { continue }
            try FileManager.default.removeItem(at: file.url)
        }
        URLCache.shared.removeAllCachedResponses()
        try PodcastCredentialStoreProvider.removeAllAppCredentials()

        clearSubscriptionManifest()
        clearAppPreferences()
        clearKnownAppGroupArtifacts()
#if canImport(CoreSpotlight) && (os(iOS) || os(macOS))
        await LocalSpotlightIndexer.deleteAllIndexedItems()
#endif
    }

    private func deleteAll<Model: PersistentModel>(_ model: Model.Type, from context: ModelContext) throws {
        try context.delete(model: model)
    }

    private func clearAppPreferences() {
        let standard = UserDefaults.standard
        for key in standard.dictionaryRepresentation().keys
        where key.hasPrefix("deleteAllData.") == false && key.hasPrefix("storeSplit.") == false {
            standard.removeObject(forKey: key)
        }
        let group = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        for key in group.dictionaryRepresentation().keys
        where key.hasPrefix("deleteAllData.") == false && key.hasPrefix("storeSplit.") == false {
            group.removeObject(forKey: key)
        }
    }

    private func clearSubscriptionManifest() {
        let store = NSUbiquitousKeyValueStore.default
        for key in store.dictionaryRepresentation.keys {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    private func clearKnownAppGroupArtifacts() {
        guard let root = appGroupContainerURL else { return }
        let paths = [
            "PodcastEpisodeImportRetries.json",
            "Library/Application Support/PortableWriteOutbox",
            "TranscriptionCheckpoints",
            "TranscriptSearch",
            "play-next-widget-covers",
            "ArtworkImages-v1",
            "ArtworkImages-v2",
            "SideLoadedArtwork",
            "PodcastCoverArchive"
        ]
        for path in paths {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
    }
}
