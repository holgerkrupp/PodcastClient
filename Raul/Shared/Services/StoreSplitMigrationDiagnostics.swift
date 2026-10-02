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
    var syncedListeningBaselineCount: Int
    var cachedAITranscriptCount: Int
    var cachedAITranscriptChunkCount: Int
    var cachedAIChapterSetCount: Int
    var failedCheckpointCount: Int
    var lastMigrationAt: Date?
    var failedItemCount: Int
}

/// Production-safe, aggregate-only readiness for the local PodcastCache. It
/// intentionally contains counts, versions and dates but no feed URLs, titles,
/// or other user content.
struct StoreSplitFeedCacheReadiness: Sendable, Equatable {
    let subscribedFeedCount: Int
    let readyFeedCount: Int
    let pendingFeedCount: Int
    let failedOrRetryableFeedCount: Int
    let unrecoverableFeedCount: Int
    let cachedEpisodeCount: Int
    let cacheSchemaVersion: Int
    let lastSuccessfulProgressAt: Date?

    var rssRecoverablePendingFeedCount: Int {
        max(0, pendingFeedCount - unrecoverableFeedCount)
    }

    var requiredFieldsCachedOrRSSRecoverable: Bool {
        unrecoverableFeedCount == 0
    }

    var isSafeForCutover: Bool {
        pendingFeedCount == 0
            && failedOrRetryableFeedCount == 0
            && requiredFieldsCachedOrRSSRecoverable
    }

    static func read(
        legacyContext: ModelContext,
        cacheContext: ModelContext
    ) -> Self {
        let sourceFeeds = Set(
            ((try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? [])
                .filter { $0.metaData?.isSubscribed != false }
                .compactMap { $0.feed.map(PodcastFeedIdentity.normalizedFeedURLString) }
        )
        let cachedPodcasts = (try? cacheContext.fetch(FetchDescriptor<CachedPodcast>())) ?? []
        let readyCacheByFeed = Dictionary(
            cachedPodcasts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let readyFeeds = Set(
            sourceFeeds.filter {
                readyCacheByFeed[$0]?.cacheSchemaVersion ?? 0
                    >= StoreSplitFeedCacheWriter.currentCacheSchemaVersion
            }
        )
        let checkpoints = (try? cacheContext.fetch(
            FetchDescriptor<StoreSplitFeedCacheCheckpoint>()
        )) ?? []
        let failedFeeds = Set(
            checkpoints.filter {
                $0.targetSchemaVersion >= StoreSplitFeedCacheWriter.currentCacheSchemaVersion
                    && $0.stateRawValue == "failed"
            }.map(\.feedURL)
        ).intersection(sourceFeeds)
        let pendingFeeds = sourceFeeds.subtracting(readyFeeds)
        let unrecoverable = pendingFeeds.filter { isRSSRecoverable($0) == false }
        let successfulDates = checkpoints.compactMap(\.lastSuccessfulAt)
        let cachedProgressDates = cachedPodcasts
            .filter { sourceFeeds.contains($0.id) }
            .map(\.updatedAt)
        let lastProgress = (successfulDates + cachedProgressDates).max()

        return Self(
            subscribedFeedCount: sourceFeeds.count,
            readyFeedCount: readyFeeds.count,
            pendingFeedCount: pendingFeeds.count,
            failedOrRetryableFeedCount: failedFeeds.count,
            unrecoverableFeedCount: unrecoverable.count,
            cachedEpisodeCount: ((try? cacheContext.fetch(
                FetchDescriptor<CachedEpisode>()
            )) ?? []).filter { sourceFeeds.contains($0.feedURL) }.count,
            cacheSchemaVersion: StoreSplitFeedCacheWriter.currentCacheSchemaVersion,
            lastSuccessfulProgressAt: lastProgress
        )
    }

    private static func isRSSRecoverable(_ feedURL: String) -> Bool {
        guard let url = URL(string: feedURL),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

struct StoreSplitMigrationHealthRecord: Codable, Sendable, Equatable {
    let operation: String
    let appState: String
    let playbackActive: Bool
    let rowsScanned: Int
    let rowsMutated: Int
    let modelContextSaveCount: Int
    let modelContextSaveDurationMilliseconds: Int
    let targetStores: String
    let cloudKitExportInProgressBefore: Bool
    let cloudKitExportInProgressAfter: Bool
    let exporterWaitDurationMilliseconds: Int
    let nextRetryAt: Date?
    let recordedAt: Date
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

enum StoreSplitMigrationReadiness: String, Sendable, Equatable {
    case unavailable
    case preparing
    case ready
    case running
    case blocked
    case complete

    var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .preparing: "Preparing"
        case .ready: "Ready"
        case .running: "Running"
        case .blocked: "Blocked"
        case .complete: "Complete"
        }
    }
}

struct StoreSplitMigrationStatus: Sendable, Equatable {
    let migrationVersion: Int
    let readiness: StoreSplitMigrationReadiness
    let blocker: String?
    let isRunning: Bool
    let completedPhaseCount: Int
    let totalPhaseCount: Int
    let scannedItemCount: Int
    let failedItemCount: Int
    let lastMigrationAt: Date?
    let lastSliceStatus: StoreSplitSliceReport.Status?
    let lastSliceProcessed: Int
    let lastSliceError: String?
    let currentJob: String?
    let pendingReason: String?
    let phases: [StoreSplitMigrationPhaseStatus]
    let podcastCacheReadiness: StoreSplitFeedCacheReadiness?
    /// AI content is checkpointed by the importer, but is intentionally kept
    /// out of the slice progress denominator because it is not part of the
    /// regular user-state slice engine.
    let supplementalPhases: [StoreSplitMigrationPhaseStatus]

    var fractionCompleted: Double {
        guard totalPhaseCount > 0 else { return 0 }
        return Double(completedPhaseCount) / Double(totalPhaseCount)
    }

    var isComplete: Bool {
        readiness != .blocked
            && completedPhaseCount == totalPhaseCount
            && failedItemCount == 0
    }
}

/// The manual development action has an explicit outcome even when no database
/// row was touched. Keeping this separate from `StoreSplitSliceReport` prevents
/// the UI from turning a deferred/failed prerequisite into “Slice complete”.
enum StoreSplitMigrationSliceResult: Sendable, Equatable {
    case advanced(phase: String?, processed: Int)
    case phaseCompleted(phase: String?, processed: Int)
    case allComplete
    case deferred(String)
    case failed(String)
}

enum StoreSplitMigrationDiagnostics {
    private static let lastMigrationKey = "storeSplit.lastMigrationAt"
    private static let failedItemsKey = "storeSplit.failedItems"
    private static let healthRecordKey = "storeSplit.lastHealthRecord.v1"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }
    /// Keep the readout in lockstep with the phases the automatic slice engine
    /// actually runs. Queue entries are produced by `playlist_entries`, and AI
    /// content is intentionally deferred to its own importer; showing either as
    /// pending migration phases made a completed backfill look permanently stuck.
    private static let phaseTitles: [String: String] = [
        StoreSplitMigrationService.Phase.subscriptions: "Subscribed podcasts",
        StoreSplitMigrationService.Phase.playlists: "Playlists",
        StoreSplitMigrationService.Phase.playlistEntries: "Playlist entries",
        StoreSplitMigrationService.Phase.bookmarks: "Bookmarks",
        StoreSplitMigrationService.Phase.preferences: "Podcast preferences",
        StoreSplitMigrationService.Phase.episodeStates: "Playback state",
        StoreSplitMigrationService.Phase.listeningSummaries: "Listening statistics",
        StoreSplitMigrationService.Phase.listeningHistory: "Listening history"
    ]

    private static let supplementalPhaseTitles: [String: String] = [
        "ai_transcripts": "AI transcripts",
        "ai_chapters": "AI chapters"
    ]

    private static var phases: [(id: String, title: String)] {
        StoreSplitMigrationService.slicePhaseOrder.compactMap { phase in
            guard let title = phaseTitles[phase] else { return nil }
            return (phase, title)
        }
    }

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
            syncedListeningBaselineCount: (try? userStateContext.fetchCount(FetchDescriptor<ListeningBaselineSync>())) ?? 0,
            cachedAITranscriptCount: (try? cacheContext.fetchCount(FetchDescriptor<AITranscriptSync>())) ?? 0,
            cachedAITranscriptChunkCount: (try? cacheContext.fetchCount(FetchDescriptor<AITranscriptChunkSync>())) ?? 0,
            cachedAIChapterSetCount: (try? cacheContext.fetchCount(FetchDescriptor<AIChapterSetSync>())) ?? 0,
            failedCheckpointCount: (try? cacheContext.fetchCount(failedCheckpointDescriptor)) ?? 0,
            lastMigrationAt: defaults.object(forKey: lastMigrationKey) as? Date,
            failedItemCount: failedItems().count
        )
    }

    static func recordMigrationRun(at date: Date = .now) {
        defaults.set(date, forKey: lastMigrationKey)
    }

    static func recordFailedItems(_ items: [String]) {
        defaults.set(items, forKey: failedItemsKey)
    }

    static func failedItems() -> [String] {
        defaults.stringArray(forKey: failedItemsKey) ?? []
    }

    static func recordHealth(_ record: StoreSplitMigrationHealthRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: healthRecordKey)
    }

    static func lastHealthRecord() -> StoreSplitMigrationHealthRecord? {
        guard let data = defaults.data(forKey: healthRecordKey) else { return nil }
        return try? JSONDecoder().decode(StoreSplitMigrationHealthRecord.self, from: data)
    }

    @MainActor
    static func migrationStatus(
        cacheContext: ModelContext,
        userStateContext: ModelContext,
        legacyContext: ModelContext? = nil,
        isRunning: Bool,
        readiness: StoreSplitMigrationReadiness = .ready,
        blocker: String? = nil,
        lastSliceStatus: StoreSplitSliceReport.Status? = nil,
        lastSliceProcessed: Int = 0,
        lastSliceError: String? = nil,
        currentJob: String? = nil,
        pendingReason: String? = nil
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
                    context: phase.id.hasPrefix("ai_")
                        ? cacheContext
                        : userStateContext
                ),
                failedCount: checkpoint?.failedCount ?? 0,
                cursor: checkpoint?.cursor,
                updatedAt: checkpoint?.updatedAt
            )
        }

        let supplementalPhaseStatuses = supplementalPhaseTitles.map { phaseID, title in
            let checkpoint = checkpointsByPhase[phaseID]
            return StoreSplitMigrationPhaseStatus(
                id: phaseID,
                title: title,
                isComplete: checkpoint?.completedAt != nil,
                scannedCount: checkpoint?.scannedCount ?? 0,
                activeDestinationCount: activeDestinationCount(
                    for: phaseID,
                    context: cacheContext
                ),
                failedCount: checkpoint?.failedCount ?? 0,
                cursor: checkpoint?.cursor,
                updatedAt: checkpoint?.updatedAt
            )
        }

        return StoreSplitMigrationStatus(
            migrationVersion: version,
            readiness: readiness,
            blocker: blocker,
            isRunning: isRunning,
            completedPhaseCount: phaseStatuses.filter(\.isComplete).count,
            totalPhaseCount: phaseStatuses.count,
            scannedItemCount: phaseStatuses.reduce(0) { $0 + $1.scannedCount },
            failedItemCount: phaseStatuses.reduce(0) { $0 + $1.failedCount },
            lastMigrationAt: defaults.object(forKey: lastMigrationKey) as? Date,
            lastSliceStatus: lastSliceStatus,
            lastSliceProcessed: lastSliceProcessed,
            lastSliceError: lastSliceError,
            currentJob: currentJob,
            pendingReason: pendingReason,
            phases: phaseStatuses,
            podcastCacheReadiness: legacyContext.map {
                StoreSplitFeedCacheReadiness.read(
                    legacyContext: $0,
                    cacheContext: cacheContext
                )
            },
            supplementalPhases: supplementalPhaseStatuses
        )
    }

    @MainActor
    static func unavailableStatus(
        readiness: StoreSplitMigrationReadiness,
        blocker: String?,
        isRunning: Bool,
        lastSliceStatus: StoreSplitSliceReport.Status?,
        lastSliceProcessed: Int,
        lastSliceError: String?,
        currentJob: String?,
        pendingReason: String?
    ) -> StoreSplitMigrationStatus {
        let emptyPhases = phases.map {
            StoreSplitMigrationPhaseStatus(
                id: $0.id,
                title: $0.title,
                isComplete: false,
                scannedCount: 0,
                activeDestinationCount: 0,
                failedCount: 0,
                cursor: nil,
                updatedAt: nil
            )
        }
        return StoreSplitMigrationStatus(
            migrationVersion: StoreSplitMigrationService.migrationVersion,
            readiness: readiness,
            blocker: blocker,
            isRunning: isRunning,
            completedPhaseCount: 0,
            totalPhaseCount: emptyPhases.count,
            scannedItemCount: 0,
            failedItemCount: 0,
            lastMigrationAt: defaults.object(forKey: lastMigrationKey) as? Date,
            lastSliceStatus: lastSliceStatus,
            lastSliceProcessed: lastSliceProcessed,
            lastSliceError: lastSliceError,
            currentJob: currentJob,
            pendingReason: pendingReason,
            phases: emptyPhases,
            podcastCacheReadiness: nil,
            supplementalPhases: []
        )
    }

    @MainActor
    private static func activeDestinationCount(
        for phase: String,
        context: ModelContext
    ) -> Int {
        switch phase {
        case "subscriptions":
            let records = (try? context.fetch(FetchDescriptor<SubscriptionSync>())) ?? []
            return Set(records.filter {
                $0.isSubscribed && $0.unsubscribedAt == nil
            }.map {
                URL(string: $0.feedURL)
                    .map(PodcastFeedIdentity.normalizedFeedURLString)
                    ?? $0.feedURL
            }).count
        case "episode_states":
            return Set(
                ((try? context.fetch(FetchDescriptor<EpisodeStateSync>())) ?? []).map(\.id)
            ).count
        case "playlists":
            return Set(
                ((try? context.fetch(FetchDescriptor<PlaylistSync>())) ?? [])
                    .filter { $0.isDeleted == false && $0.deletedAt == nil }
                    .map(\.id)
            ).count
        case "playlist_entries":
            return Set(
                ((try? context.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [])
                    .filter { $0.isDeleted == false && $0.deletedAt == nil }
                    .map(\.id)
            ).count
        case "queue_entries":
            return Set(
                ((try? context.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
                    .filter { $0.isDeleted == false && $0.deletedAt == nil }
                    .map(\.id)
            ).count
        case "bookmarks":
            return Set(
                ((try? context.fetch(FetchDescriptor<BookmarkSync>())) ?? [])
                    .filter { $0.isDeleted == false && $0.deletedAt == nil }
                    .map(\.id)
            ).count
        case "preferences":
            return Set(
                ((try? context.fetch(FetchDescriptor<PodcastPreferenceSync>())) ?? []).map(\.id)
            ).count
        case "listening_history":
            return Set(
                ((try? context.fetch(FetchDescriptor<ListeningHistorySync>())) ?? []).map(\.id)
            ).count
        case "listening_summaries":
            return Set(
                ((try? context.fetch(FetchDescriptor<ListeningBaselineSync>())) ?? []).map(\.id)
            ).count
        case "ai_transcripts":
            return Set(
                ((try? context.fetch(FetchDescriptor<AITranscriptSync>())) ?? []).map(\.id)
            ).count
        case "ai_chapters":
            return Set(
                ((try? context.fetch(FetchDescriptor<AIChapterSetSync>())) ?? []).map(\.id)
            ).count
        default:
            return 0
        }
    }
}
