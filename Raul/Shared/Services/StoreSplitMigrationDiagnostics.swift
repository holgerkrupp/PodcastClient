import Foundation
import SwiftData

struct StoreSplitMigrationDiagnosticsSnapshot: Sendable {
    var legacySubscribedPodcastCount: Int
    var legacyEpisodeCount: Int
    var legacyEpisodesWithPlaybackProgressCount: Int
    var legacyPlaylistEntryCount: Int
    var legacyBookmarkCount: Int
    var legacyTranscriptLineCount: Int
    var legacyPlaySessionCount: Int
    var legacyPlaySessionSummaryCount: Int
    var syncedSubscriptionCount: Int
    var syncedEpisodeStateCount: Int
    var syncedPlaylistCount: Int
    var syncedPlaylistEntryCount: Int
    var syncedQueueEntryCount: Int
    var syncedBookmarkCount: Int
    var syncedListeningHistoryCount: Int
    var syncedListeningSummaryCount: Int
    var syncedAITranscriptCount: Int
    var syncedAITranscriptChunkCount: Int
    var syncedAIChapterSetCount: Int
    var failedCheckpointCount: Int
    var lastMigrationAt: Date?
    var failedItemCount: Int
}

struct StoreSplitMigrationPhaseStatus: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let isComplete: Bool
    let scannedCount: Int
    let activeDestinationCount: Int
    let failedCount: Int
    let cursor: String?
    let updatedAt: Date?
}

struct StoreSplitMigrationStatus: Sendable, Equatable {
    let migrationVersion: Int
    let isRunning: Bool
    let completedPhaseCount: Int
    let totalPhaseCount: Int
    let scannedItemCount: Int
    let failedItemCount: Int
    let lastMigrationAt: Date?
    let phases: [StoreSplitMigrationPhaseStatus]

    var fractionCompleted: Double {
        guard totalPhaseCount > 0 else { return 0 }
        return Double(completedPhaseCount) / Double(totalPhaseCount)
    }

    var isComplete: Bool {
        completedPhaseCount == totalPhaseCount && failedItemCount == 0
    }
}

enum StoreSplitMigrationDiagnostics {
    private static let lastMigrationKey = "storeSplit.lastMigrationAt"
    private static let failedItemsKey = "storeSplit.failedItems"
    private static let phases: [(id: String, title: String)] = [
        ("subscriptions", "Subscriptions"),
        ("episode_states", "Playback state"),
        ("playlists", "Playlists"),
        ("playlist_entries", "Playlist entries"),
        ("queue_entries", "Up Next queue"),
        ("bookmarks", "Bookmarks"),
        ("listening_history", "Listening history"),
        ("listening_summaries", "Listening statistics"),
        ("ai_transcripts", "AI transcripts"),
        ("ai_chapters", "AI chapters")
    ]

    static func snapshot(
        legacyContext: ModelContext,
        userStateContext: ModelContext,
        cacheContext: ModelContext
    ) -> StoreSplitMigrationDiagnosticsSnapshot {
        let subscribedPodcastDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.metaData?.isSubscribed != false }
        )
        let episodesDescriptor = FetchDescriptor<Episode>()
        let progressDescriptor = FetchDescriptor<EpisodeMetaData>(
            predicate: #Predicate<EpisodeMetaData> {
                ($0.playPosition ?? 0) > 0 || ($0.maxPlayposition ?? 0) > 0
            }
        )

        let legacySubscribedPodcastCount = (try? legacyContext.fetchCount(subscribedPodcastDescriptor)) ?? 0
        let legacyEpisodeCount = (try? legacyContext.fetchCount(episodesDescriptor)) ?? 0
        let legacyEpisodesWithPlaybackProgressCount = (try? legacyContext.fetchCount(progressDescriptor)) ?? 0
        let legacyPlaylistEntryCount = (try? legacyContext.fetchCount(FetchDescriptor<PlaylistEntry>())) ?? 0
        let legacyBookmarkCount = (try? legacyContext.fetchCount(FetchDescriptor<Bookmark>())) ?? 0
        let legacyTranscriptLineCount = (try? legacyContext.fetchCount(FetchDescriptor<TranscriptLineAndTime>())) ?? 0
        let failedCheckpointDescriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate<StoreSplitMigrationCheckpoint> { $0.failedCount > 0 }
        )

        return StoreSplitMigrationDiagnosticsSnapshot(
            legacySubscribedPodcastCount: legacySubscribedPodcastCount,
            legacyEpisodeCount: legacyEpisodeCount,
            legacyEpisodesWithPlaybackProgressCount: legacyEpisodesWithPlaybackProgressCount,
            legacyPlaylistEntryCount: legacyPlaylistEntryCount,
            legacyBookmarkCount: legacyBookmarkCount,
            legacyTranscriptLineCount: legacyTranscriptLineCount,
            legacyPlaySessionCount: (try? legacyContext.fetchCount(FetchDescriptor<PlaySession>())) ?? 0,
            legacyPlaySessionSummaryCount: (try? legacyContext.fetchCount(FetchDescriptor<PlaySessionSummary>())) ?? 0,
            syncedSubscriptionCount: (try? userStateContext.fetchCount(FetchDescriptor<SubscriptionSync>())) ?? 0,
            syncedEpisodeStateCount: (try? userStateContext.fetchCount(FetchDescriptor<EpisodeStateSync>())) ?? 0,
            syncedPlaylistCount: (try? userStateContext.fetchCount(FetchDescriptor<PlaylistSync>())) ?? 0,
            syncedPlaylistEntryCount: (try? userStateContext.fetchCount(FetchDescriptor<PlaylistEntrySync>())) ?? 0,
            syncedQueueEntryCount: (try? userStateContext.fetchCount(FetchDescriptor<QueueEntrySync>())) ?? 0,
            syncedBookmarkCount: (try? userStateContext.fetchCount(FetchDescriptor<BookmarkSync>())) ?? 0,
            syncedListeningHistoryCount: (try? userStateContext.fetchCount(FetchDescriptor<ListeningHistorySync>())) ?? 0,
            syncedListeningSummaryCount: (try? userStateContext.fetchCount(FetchDescriptor<ListeningSummarySync>())) ?? 0,
            syncedAITranscriptCount: (try? userStateContext.fetchCount(FetchDescriptor<AITranscriptSync>())) ?? 0,
            syncedAITranscriptChunkCount: (try? userStateContext.fetchCount(FetchDescriptor<AITranscriptChunkSync>())) ?? 0,
            syncedAIChapterSetCount: (try? userStateContext.fetchCount(FetchDescriptor<AIChapterSetSync>())) ?? 0,
            failedCheckpointCount: (try? cacheContext.fetchCount(failedCheckpointDescriptor)) ?? 0,
            lastMigrationAt: UserDefaults.standard.object(forKey: lastMigrationKey) as? Date,
            failedItemCount: failedItems().count
        )
    }

    static func recordMigrationRun(at date: Date = .now) {
        UserDefaults.standard.set(date, forKey: lastMigrationKey)
    }

    static func recordFailedItems(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: failedItemsKey)
    }

    static func failedItems() -> [String] {
        UserDefaults.standard.stringArray(forKey: failedItemsKey) ?? []
    }

    @MainActor
    static func migrationStatus(
        cacheContext: ModelContext,
        userStateContext: ModelContext,
        isRunning: Bool
    ) -> StoreSplitMigrationStatus {
        let version = StoreSplitMigrationService.migrationVersion
        let checkpoints = ((try? cacheContext.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>())) ?? [])
            .filter { $0.migrationVersion == version }
        let checkpointsByPhase = checkpoints.reduce(
            into: [String: StoreSplitMigrationCheckpoint]()
        ) { result, checkpoint in
            guard let existing = result[checkpoint.phase],
                  existing.updatedAt >= checkpoint.updatedAt else {
                result[checkpoint.phase] = checkpoint
                return
            }
        }

        let phaseStatuses = phases.map { phase in
            let checkpoint = checkpointsByPhase[phase.id]
            return StoreSplitMigrationPhaseStatus(
                id: phase.id,
                title: phase.title,
                isComplete: checkpoint?.completedAt != nil,
                scannedCount: checkpoint?.scannedCount ?? 0,
                activeDestinationCount: activeDestinationCount(
                    for: phase.id,
                    context: userStateContext
                ),
                failedCount: checkpoint?.failedCount ?? 0,
                cursor: checkpoint?.cursor,
                updatedAt: checkpoint?.updatedAt
            )
        }

        return StoreSplitMigrationStatus(
            migrationVersion: version,
            isRunning: isRunning,
            completedPhaseCount: phaseStatuses.filter(\.isComplete).count,
            totalPhaseCount: phaseStatuses.count,
            scannedItemCount: phaseStatuses.reduce(0) { $0 + $1.scannedCount },
            failedItemCount: phaseStatuses.reduce(0) { $0 + $1.failedCount },
            lastMigrationAt: UserDefaults.standard.object(forKey: lastMigrationKey) as? Date,
            phases: phaseStatuses
        )
    }

    @MainActor
    private static func activeDestinationCount(
        for phase: String,
        context: ModelContext
    ) -> Int {
        switch phase {
        case "subscriptions":
            let descriptor = FetchDescriptor<SubscriptionSync>(
                predicate: #Predicate<SubscriptionSync> { $0.isSubscribed }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        case "episode_states":
            return (try? context.fetchCount(FetchDescriptor<EpisodeStateSync>())) ?? 0
        case "playlists":
            let descriptor = FetchDescriptor<PlaylistSync>(
                predicate: #Predicate<PlaylistSync> { $0.deletedAt == nil }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        case "playlist_entries":
            let descriptor = FetchDescriptor<PlaylistEntrySync>(
                predicate: #Predicate<PlaylistEntrySync> { $0.deletedAt == nil }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        case "queue_entries":
            let descriptor = FetchDescriptor<QueueEntrySync>(
                predicate: #Predicate<QueueEntrySync> { $0.deletedAt == nil }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        case "bookmarks":
            let descriptor = FetchDescriptor<BookmarkSync>(
                predicate: #Predicate<BookmarkSync> { $0.deletedAt == nil }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        case "listening_history":
            return (try? context.fetchCount(FetchDescriptor<ListeningHistorySync>())) ?? 0
        case "listening_summaries":
            return (try? context.fetchCount(FetchDescriptor<ListeningSummarySync>())) ?? 0
        case "ai_transcripts":
            return (try? context.fetchCount(FetchDescriptor<AITranscriptSync>())) ?? 0
        case "ai_chapters":
            return (try? context.fetchCount(FetchDescriptor<AIChapterSetSync>())) ?? 0
        default:
            return 0
        }
    }
}
