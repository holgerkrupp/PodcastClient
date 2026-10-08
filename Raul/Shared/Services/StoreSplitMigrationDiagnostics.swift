import Foundation
import SwiftData

#if DEBUG
struct StoreSplitAutomaticCheck: Identifiable, Sendable {
    enum Status: String, Sendable, Equatable {
        case passed
        case partial
        case failed
    }

    let id: String
    let title: String
    let status: Status
    let details: String
}

/// Runs small, deterministic migration scenarios only against in-memory stores.
/// Partial results call out acceptance criteria that need real BGProcessing or
/// CloudKit conditions and therefore cannot be certified by this local runner.
enum StoreSplitAutomaticChecks {
    private struct Containers: Sendable {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    static func runAll() async -> [StoreSplitAutomaticCheck] {
        do {
            let stores = try makeContainers()
            let fixture = try populate(stores.legacy, episodeCount: 45)
            let migration = await resumeMigration(stores)
            guard migration.completed else {
                return [failed("Fixture migration", migration.details)]
            }

            let cacheResult = await checkPriorityCache(stores, feedURL: fixture.feedURL)
            let reconciliationResult = await checkReconciliation(stores)
            let verificationResult = checkVerifier(stores)
            let policyResult = checkExporterPolicy()

            return [
                .init(
                    id: "201",
                    title: "Background migration checkpoint resume",
                    status: .partial,
                    details: "Stopped after the first persisted slice and completed \(migration.sliceCount) bounded slices after resuming. This fixture does not measure CPU duty cycle or the 1–2 / 7 overnight-opportunity throughput target."
                ),
                .init(
                    id: "202",
                    title: "Newest-wins backfill",
                    status: .passed,
                    details: "Newer synchronized playback state remained unchanged while migrating 45 synthetic episodes; the test also exercised queue and bookmark backfill."
                ),
                cacheResult,
                reconciliationResult,
                verificationResult,
                policyResult,
                .init(
                    id: "207",
                    title: "Dormant-device replay simulation",
                    status: .partial,
                    details: "The in-memory stale-device scenario passed as part of backfill. Real CloudKit delivery order, device sleep, and BGProcessing expiration still require a multi-device release test."
                )
            ]
        } catch {
            return [failed("Automatic migration checks", error.localizedDescription)]
        }
    }

    private static func makeContainers() throws -> Containers {
        Containers(
            legacy: try ModelContainerManager.makeLegacyContainer(
                isStoredInMemoryOnly: true
            ),
            userState: try ModelContainerManager.makeUserStateContainer(
                isStoredInMemoryOnly: true
            ),
            cache: try ModelContainerManager.makeCacheContainer(
                isStoredInMemoryOnly: true
            )
        )
    }

    private struct Fixture: Sendable {
        let feedURL: URL
    }

    private static func populate(
        _ container: ModelContainer,
        episodeCount: Int
    ) throws -> Fixture {
        let context = ModelContext(container)
        let feedURL = URL(string: "https://store-split-check.invalid/feed.xml")!
        let podcast = Podcast(feed: feedURL)
        podcast.title = "Store split verification fixture"
        podcast.metaData?.isSubscribed = true
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        context.insert(podcast)

        var episodes: [Episode] = []
        for index in 0..<episodeCount {
            let episode = Episode(
                guid: "fixture-episode-\(index)",
                title: "Fixture episode \(index)",
                publishDate: Date(timeIntervalSince1970: Double(index) * 10_000),
                url: URL(string: "https://store-split-check.invalid/\(index).mp3")!,
                podcast: podcast,
                duration: 300
            )
            episode.metaData?.playPosition = Double(index + 1)
            episode.metaData?.maxPlayposition = Double(index + 2)
            episode.metaData?.lastPlayed = Date(timeIntervalSince1970: Double(index + 2_000))
            episode.metaData?.stateUpdatedAt = Date(timeIntervalSince1970: 4_000)
            episodes.append(episode)
            context.insert(episode)
        }
        podcast.episodes = episodes

        let queue = Playlist()
        queue.title = Playlist.defaultQueueTitle
        if let first = episodes.first {
            let entry = PlaylistEntry(episode: first, order: 0)
            entry.playlist = queue
            queue.items = [entry]
            context.insert(entry)

            let bookmark = Bookmark(start: 30, title: "Fixture bookmark", type: .bookmark)
            bookmark.uuid = UUID()
            bookmark.creationtime = Date(timeIntervalSince1970: 5_000)
            bookmark.bookmarkEpisode = first
            first.bookmarks = [bookmark]
            context.insert(bookmark)
        }
        context.insert(queue)
        try context.save()

        guard episodes.isEmpty == false else {
            throw StoreSplitAutomaticCheckError.emptyFixture
        }
        return Fixture(feedURL: feedURL)
    }

    private struct MigrationOutcome {
        let completed: Bool
        let sliceCount: Int
        let details: String
    }

    private static func resumeMigration(_ stores: Containers) async -> MigrationOutcome {
        let legacyContext = ModelContext(stores.legacy)
        guard let episode = try? legacyContext.fetch(FetchDescriptor<Episode>()).first else {
            return MigrationOutcome(completed: false, sliceCount: 0, details: "Fixture episode is missing")
        }
        let identity = episode.stableEpisodeIdentity
        let remoteUpdatedAt = Date().addingTimeInterval(86_400)
        let userContext = ModelContext(stores.userState)
        userContext.insert(EpisodeStateSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            playPosition: 180,
            maxPlayPosition: 240,
            duration: 300,
            updatedAt: remoteUpdatedAt,
            sourceDeviceID: "verification-other-device"
        ))
        do {
            try userContext.save()
        } catch {
            return MigrationOutcome(completed: false, sliceCount: 0, details: error.localizedDescription)
        }

        var sliceCount = 0
        var firstSliceWasResumable = false
        for _ in 0..<100 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: stores.legacy,
                userStateContainer: stores.userState,
                cacheContainer: stores.cache
            )
            sliceCount += 1
            switch report.status {
            case .failed:
                return MigrationOutcome(
                    completed: false,
                    sliceCount: sliceCount,
                    details: report.error ?? "A migration slice failed"
                )
            case .cancelled:
                return MigrationOutcome(completed: false, sliceCount: sliceCount, details: "Migration was cancelled")
            case .completed:
                let verificationContext = ModelContext(stores.userState)
                let identityKey = identity.key
                let stored: EpisodeStateSync?
                do {
                    stored = try verificationContext.fetch(
                        FetchDescriptor<EpisodeStateSync>(
                            predicate: #Predicate { $0.id == identityKey }
                        )
                    ).first
                } catch {
                    return MigrationOutcome(
                        completed: false,
                        sliceCount: sliceCount,
                        details: error.localizedDescription
                    )
                }
                let newestStatePreserved = stored?.playPosition == 180
                    && stored?.maxPlayPosition == 240
                    && stored?.updatedAt == remoteUpdatedAt
                return MigrationOutcome(
                    completed: firstSliceWasResumable && newestStatePreserved,
                    sliceCount: sliceCount,
                    details: newestStatePreserved
                        ? "Checkpoint resumed and newer synchronized playback state was preserved."
                        : "The resumed migration rewound newer synchronized playback state."
                )
            case .advanced, .phaseCompleted:
                if sliceCount == 1 {
                    firstSliceWasResumable = report.processed > 0
                        && StoreSplitMigrationService.isSliceMigrationComplete(
                            cacheContainer: stores.cache
                        ) == false
                }
            }
        }
        return MigrationOutcome(completed: false, sliceCount: sliceCount, details: "Migration exceeded 100 fixture slices")
    }

    @MainActor
    private static func checkPriorityCache(
        _ stores: Containers,
        feedURL: URL
    ) -> StoreSplitAutomaticCheck {
        let references = ModelContainerManager.shared.priorityRecoveryFeedURLs(
            stores.userState,
            after: nil,
            limit: 20
        )
        let priorityFound = references.feeds.contains {
            PodcastFeedIdentity.normalizedFeedURLString($0)
                == PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        }
        let projected = StoreSplitFeedCacheWriter.bootstrapPriorityFeeds(
            references.feeds,
            legacyContainer: stores.legacy,
            cacheContainer: stores.cache,
            limit: 20
        )
        let cacheContext = ModelContext(stores.cache)
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let cached = (try? cacheContext.fetch(
            FetchDescriptor<CachedPodcast>(predicate: #Predicate { $0.id == feedKey })
        ).first) != nil
        let passed = priorityFound && projected > 0 && cached
        return .init(
            id: "203",
            title: "Queue-critical cache bootstrap",
            status: passed ? .partial : .failed,
            details: passed
                ? "Queue and recent-playback feed references were selected and projected to the in-memory PodcastCache. Generic-feed cursor throughput and unavailable/private network feeds still need separate verification."
                : "The priority feed reference was not resolved into PodcastCache."
        )
    }

    private static func checkReconciliation(
        _ stores: Containers
    ) async -> StoreSplitAutomaticCheck {
        let context = ModelContext(stores.userState)
        context.insert(SubscriptionSync(
            feedURL: "https://stale.store-split-check.invalid/feed.xml",
            isSubscribed: true
        ))
        do {
            try context.save()
        } catch {
            return failed("Authoritative reconciliation", error.localizedDescription)
        }
        let result = await StoreSplitAuthoritativeReconciliationService.reconcile(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState
        )
        let checkContext = ModelContext(stores.userState)
        let staleURL = "https://stale.store-split-check.invalid/feed.xml"
        let stale: SubscriptionSync?
        do {
            stale = try checkContext.fetch(
                FetchDescriptor<SubscriptionSync>(predicate: #Predicate { $0.feedURL == staleURL })
            ).first
        } catch {
            return failed("Authoritative reconciliation", error.localizedDescription)
        }
        let passed = result.failed == 0 && stale?.isSubscribed == false
        return .init(
            id: "204",
            title: "Authoritative reconciliation smoke check",
            status: passed ? .partial : .failed,
            details: passed
                ? "The small in-memory stale-subscription case reconciled correctly. This does not verify bounded pages or checkpoint resume; the current reconciliation implementation still needs that refactor."
                : "The synthetic destination-only subscription was not tombstoned."
        )
    }

    private static func checkVerifier(
        _ stores: Containers
    ) -> StoreSplitAutomaticCheck {
        let report = StoreSplitMigrationVerifier.verify(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        return .init(
            id: "205",
            title: "Verification smoke check",
            status: .partial,
            details: "The current one-shot verifier completed with \(report.issues.count) reported issues and \(report.cacheMissingCount) cache misses. It still reads full populations and is not a resumable readiness gate."
        )
    }

    private static func checkExporterPolicy() -> StoreSplitAutomaticCheck {
        let yieldsWhileExporting = StoreSplitMaintenancePolicy
            .shouldYieldForCloudKitExport(exportInProgress: true)
        let proceedsWhenIdle = StoreSplitMaintenancePolicy
            .shouldYieldForCloudKitExport(exportInProgress: false) == false
        let passed = yieldsWhileExporting && proceedsWhenIdle
        return .init(
            id: "206",
            title: "CloudKit pressure gate",
            status: passed ? .partial : .failed,
            details: passed
                ? "Maintenance rejects batches while an exporter is active and resumes when idle. This pure policy check does not measure export backlog, cooldown duration, or write amplification."
                : "The maintenance export-pressure predicate returned an unexpected result."
        )
    }

    private static func failed(
        _ title: String,
        _ details: String
    ) -> StoreSplitAutomaticCheck {
        .init(id: "setup", title: title, status: .failed, details: details)
    }
}

private enum StoreSplitAutomaticCheckError: Error {
    case emptyFixture
}
#endif

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
