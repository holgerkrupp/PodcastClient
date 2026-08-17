#if DEBUG
import Foundation
import SwiftData

struct StoreSplitDevelopmentResetResult: Sendable {
    var userStateRecordsDeleted = 0
    var cacheRecordsDeleted = 0
}

actor StoreSplitDevelopmentResetService {
    private let userStateContext: ModelContext
    private let cacheContext: ModelContext

    private init(
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        userStateContext = ModelContext(userStateContainer)
        cacheContext = ModelContext(cacheContainer)
        userStateContext.autosaveEnabled = false
        cacheContext.autosaveEnabled = false
    }

    nonisolated static func reset(
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) async throws -> StoreSplitDevelopmentResetResult {
        try await Task.detached(priority: .utility) {
            let service = StoreSplitDevelopmentResetService(
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
            return try await service.run()
        }.value
    }

    private func run() throws -> StoreSplitDevelopmentResetResult {
        var result = StoreSplitDevelopmentResetResult()

        result.userStateRecordsDeleted += try deleteAll(
            SubscriptionSync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            EpisodeStateSync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            QueueEntrySync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            PlaylistEntrySync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            PlaylistSync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            BookmarkSync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            ListeningHistorySync.self,
            from: userStateContext
        )
        result.userStateRecordsDeleted += try deleteAll(
            ListeningSummarySync.self,
            from: userStateContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            StoreSplitMigrationCheckpoint.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            AITranscriptChunkSync.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            AITranscriptSync.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            AIChapterSetSync.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedFeedExtensionElement.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            AppliedAIContentRevision.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedChapter.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedTranscriptLine.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedTranscriptionRecord.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedDownloadRecord.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedRateSegment.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedHourlyListeningStat.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedPlaySession.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            FeedAlias.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedEpisode.self,
            from: cacheContext
        )
        result.cacheRecordsDeleted += try deleteAll(
            CachedPodcast.self,
            from: cacheContext
        )

        if userStateContext.hasChanges {
            try userStateContext.save()
        }
        if cacheContext.hasChanges {
            try cacheContext.save()
        }

        return result
    }

    private func deleteAll<Model: PersistentModel>(
        _ model: Model.Type,
        from context: ModelContext
    ) throws -> Int {
        let count = try context.fetchCount(FetchDescriptor<Model>())
        try context.delete(model: model)
        return count
    }
}
#endif
