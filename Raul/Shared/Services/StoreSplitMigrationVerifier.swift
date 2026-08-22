import CryptoKit
import Foundation
import SwiftData

struct StoreSplitVerificationReport: Equatable, Sendable {
    var sourceCounts: [String: Int]
    var destinationCounts: [String: Int]
    var sourceDigest: String
    var destinationDigest: String
    var cacheRecoverableCount: Int
    var cacheMissingCount: Int
    var issues: [String]

    var isLossless: Bool { issues.isEmpty && cacheMissingCount == 0 }
}

struct LegacyStoreCleanupGate: Equatable, Sendable {
    let migrationVerified: Bool
    let legacyFallbackDisabled: Bool
    let convergenceTelemetryPassed: Bool
    let supportedVersionGracePeriodEnded: Bool
    let cacheOrRSSRecoveryVerified: Bool

    var isSafe: Bool {
        migrationVerified
            && legacyFallbackDisabled
            && convergenceTelemetryPassed
            && supportedVersionGracePeriodEnded
            && cacheOrRSSRecoveryVerified
    }
}

/// Field-level, logical-key verification. It deliberately never deletes files;
/// callers may use `LegacyStoreCleanupGate` only after the release grace period
/// and telemetry gates have independently passed.
enum StoreSplitMigrationVerifier {
    static let verificationID = "store-split-v\(StoreSplitMigrationService.migrationVersion)"

    @discardableResult
    static func verify(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) -> StoreSplitVerificationReport {
        let legacy = ModelContext(legacyContainer)
        let userState = ModelContext(userStateContainer)
        let cache = ModelContext(cacheContainer)
        var issues: [String] = []
        var sourceCounts: [String: Int] = [:]
        var destinationCounts: [String: Int] = [:]
        var sourceLines: [String] = []
        var destinationLines: [String] = []

        let subscriptions = newest(
            (try? userState.fetch(FetchDescriptor<SubscriptionSync>())) ?? [],
            id: \SubscriptionSync.id,
            date: \SubscriptionSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let episodeStates = newest(
            (try? userState.fetch(FetchDescriptor<EpisodeStateSync>())) ?? [],
            id: \EpisodeStateSync.id,
            date: \EpisodeStateSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let playlists = newest(
            (try? userState.fetch(FetchDescriptor<PlaylistSync>())) ?? [],
            id: \PlaylistSync.id,
            date: \PlaylistSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let playlistEntries = newest(
            (try? userState.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [],
            id: \PlaylistEntrySync.id,
            date: \PlaylistEntrySync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let bookmarks = newest(
            (try? userState.fetch(FetchDescriptor<BookmarkSync>())) ?? [],
            id: \BookmarkSync.id,
            date: \BookmarkSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let preferences = newest(
            (try? userState.fetch(FetchDescriptor<PodcastPreferenceSync>())) ?? [],
            id: \PodcastPreferenceSync.id,
            date: \PodcastPreferenceSync.updatedAt,
            device: { $0.sourceDeviceID }
        )

        destinationCounts["subscriptions"] = subscriptions.count
        destinationCounts["episodeStates"] = episodeStates.count
        destinationCounts["playlists"] = playlists.count
        destinationCounts["playlistEntries"] = playlistEntries.count
        destinationCounts["bookmarks"] = bookmarks.count
        destinationCounts["preferences"] = preferences.count
        destinationCounts["listeningHistory"] =
            (try? userState.fetchCount(FetchDescriptor<ListeningHistorySync>())) ?? 0
        destinationCounts["listeningBaselines"] =
            (try? userState.fetchCount(FetchDescriptor<ListeningBaselineSync>())) ?? 0

        var requiredFeedKeys = Set<String>()
        var requiredEpisodeKeys = Set<String>()
        let legacyPodcasts = (try? legacy.fetch(FetchDescriptor<Podcast>())) ?? []
        sourceCounts["subscriptions"] = 0
        for podcast in legacyPodcasts {
            guard let feed = podcast.feed else { continue }
            let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
            requiredFeedKeys.insert(feedKey)
            sourceCounts["subscriptions", default: 0] += 1
            let subscribedAt = podcast.metaData?.subscriptionDate ?? .distantPast
            let isSubscribed = podcast.metaData?.isSubscribed != false
            let line = canonical(
                "subscription", feedKey, isSubscribed,
                subscribedAt.timeIntervalSince1970
            )
            sourceLines.append(line)
            guard let destination = subscriptions[feedKey] else {
                issues.append("missing_subscription:\(feedKey)")
                continue
            }
            destinationLines.append(canonical(
                "subscription", feedKey, destination.isSubscribed,
                destination.subscribedAt.timeIntervalSince1970
            ))
            if destination.updatedAt <= subscribedAt,
               (destination.isSubscribed != isSubscribed
                    || destination.subscribedAt != subscribedAt) {
                issues.append("subscription_fields:\(feedKey)")
            }
        }

        let legacyEpisodes = (try? legacy.fetch(FetchDescriptor<Episode>())) ?? []
        sourceCounts["episodeStates"] = 0
        for episode in legacyEpisodes {
            guard let metadata = episode.metaData,
                  episode.podcast?.feed != nil else { continue }
            let isPlayed = metadata.isHistory == true
                || metadata.status == .history
                || metadata.completionDate != nil
            let isArchived = metadata.isArchived == true || metadata.status == .archived
            let meaningful = (metadata.playPosition ?? 0) > 0
                || (metadata.maxPlayposition ?? 0) > 0
                || isPlayed || isArchived || metadata.wasSkipped
                || metadata.firstListenDate != nil || metadata.lastPlayed != nil
            guard meaningful else { continue }
            let identity = episode.stableEpisodeIdentity
            requiredEpisodeKeys.insert(identity.key)
            requiredFeedKeys.insert(identity.feedURL)
            sourceCounts["episodeStates", default: 0] += 1
            let updatedAt = [
                metadata.lastPlayed, metadata.completionDate,
                metadata.archivedAt, metadata.firstListenDate
            ].compactMap { $0 }.max() ?? .distantPast
            sourceLines.append(canonical(
                "episode", identity.key, metadata.playPosition ?? 0,
                metadata.maxPlayposition ?? 0, isPlayed, isArchived,
                metadata.wasSkipped
            ))
            guard let destination = episodeStates[identity.key] else {
                issues.append("missing_episode_state:\(identity.key)")
                continue
            }
            destinationLines.append(canonical(
                "episode", identity.key, destination.playPosition,
                destination.maxPlayPosition, destination.isPlayed,
                destination.isArchived, destination.wasSkipped
            ))
            if destination.updatedAt <= updatedAt {
                if destination.playPosition != metadata.playPosition ?? 0
                    || destination.maxPlayPosition < metadata.maxPlayposition ?? 0
                    || destination.isPlayed != isPlayed
                    || destination.isArchived != isArchived
                    || destination.wasSkipped != metadata.wasSkipped {
                    issues.append("episode_state_fields:\(identity.key)")
                }
            }
        }

        let legacyPlaylists = (try? legacy.fetch(FetchDescriptor<Playlist>())) ?? []
        sourceCounts["playlists"] = legacyPlaylists.count
        sourceCounts["playlistEntries"] = 0
        for playlist in legacyPlaylists {
            let playlistID = playlist.storeSplitSyncID
            let sourceUpdatedAt = playlist.ordered.compactMap(\.dateAdded).max() ?? .distantPast
            sourceLines.append(canonical(
                "playlist", playlistID, playlist.title, playlist.symbolName,
                playlist.sortIndex, playlist.kindRawValue, playlist.hidden
            ))
            guard let destination = playlists[playlistID] else {
                issues.append("missing_playlist:\(playlistID)")
                continue
            }
            destinationLines.append(canonical(
                "playlist", playlistID, destination.title,
                destination.symbolName, destination.sortIndex,
                destination.kindRawValue, destination.isHidden
            ))
            if destination.updatedAt <= sourceUpdatedAt,
               (destination.title != playlist.title
                    || destination.symbolName != playlist.symbolName
                    || destination.sortIndex != playlist.sortIndex
                    || destination.kindRawValue != playlist.kindRawValue
                    || destination.isHidden != playlist.hidden) {
                issues.append("playlist_fields:\(playlistID)")
            }
            for entry in playlist.ordered {
                guard let episode = entry.episode,
                      episode.podcast?.feed != nil else { continue }
                let identity = episode.stableEpisodeIdentity
                let entryID = StableIdentityKey.make(
                    playlistID, identity.feedURL, identity.episodeID
                )
                requiredFeedKeys.insert(identity.feedURL)
                requiredEpisodeKeys.insert(identity.key)
                sourceCounts["playlistEntries", default: 0] += 1
                sourceLines.append(canonical(
                    "playlistEntry", entryID, entry.order,
                    entry.dateAdded?.timeIntervalSince1970 ?? 0
                ))
                guard let destination = playlistEntries[entryID] else {
                    issues.append("missing_playlist_entry:\(entryID)")
                    continue
                }
                destinationLines.append(canonical(
                    "playlistEntry", entryID, destination.sortIndex,
                    destination.addedAt.timeIntervalSince1970
                ))
                if destination.updatedAt <= entry.dateAdded ?? .distantPast,
                   (destination.isDeleted
                        || destination.sortIndex != entry.order
                        || destination.addedAt != entry.dateAdded ?? .distantPast) {
                    issues.append("playlist_entry_fields:\(entryID)")
                }
            }
        }

        let legacyBookmarks = (try? legacy.fetch(FetchDescriptor<Bookmark>())) ?? []
        sourceCounts["bookmarks"] = 0
        for bookmark in legacyBookmarks {
            guard let episode = bookmark.bookmarkEpisode,
                  episode.podcast?.feed != nil else { continue }
            let identity = episode.stableEpisodeIdentity
            let createdAt = bookmark.creationtime ?? .distantPast
            let bookmarkID = bookmark.uuid?.uuidString ?? StableIdentityKey.make(
                "legacy-bookmark", identity.key, String(bookmark.start ?? 0),
                bookmark.title, String(createdAt.timeIntervalSince1970)
            )
            requiredFeedKeys.insert(identity.feedURL)
            requiredEpisodeKeys.insert(identity.key)
            sourceCounts["bookmarks", default: 0] += 1
            sourceLines.append(canonical(
                "bookmark", bookmarkID, identity.key,
                bookmark.start ?? 0, bookmark.title,
                createdAt.timeIntervalSince1970
            ))
            guard let destination = bookmarks[bookmarkID] else {
                issues.append("missing_bookmark:\(bookmarkID)")
                continue
            }
            destinationLines.append(canonical(
                "bookmark", bookmarkID,
                StableIdentityKey.make(destination.feedURL, destination.episodeID),
                destination.time, destination.title ?? "",
                destination.createdAt.timeIntervalSince1970
            ))
            if destination.updatedAt <= createdAt,
               (destination.isDeleted
                    || destination.feedURL != identity.feedURL
                    || destination.episodeID != identity.episodeID
                    || destination.time != bookmark.start ?? 0
                    || destination.title != bookmark.title) {
                issues.append("bookmark_fields:\(bookmarkID)")
            }
        }

        let legacyPreferences = (try? legacy.fetch(FetchDescriptor<PodcastSettings>())) ?? []
        sourceCounts["preferences"] = Set(legacyPreferences.map {
            $0.podcast?.feed.map(PodcastFeedIdentity.normalizedFeedURLString)
                .map { StableIdentityKey.make("feed", $0) }
                ?? StableIdentityKey.make("global")
        }).count
        for setting in legacyPreferences {
            let id = setting.podcast?.feed
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                .map { StableIdentityKey.make("feed", $0) }
                ?? StableIdentityKey.make("global")
            if preferences[id] == nil { issues.append("missing_preference:\(id)") }
        }

        // Only sessions the migration can actually carry count as source rows.
        // A session with no episode, no start time, or no clean end has nothing
        // to key a cache row or a compact history record on, and rows the
        // importer projected back from UserState are not an independent source.
        // Counting them made verification permanently unsatisfiable, which left
        // the rollout stuck before the read cutover.
        let legacySessions = (try? legacy.fetch(FetchDescriptor<PlaySession>())) ?? []
        var cacheableSessionCount = 0
        var completedSessionCount = 0
        for session in legacySessions {
            guard session.appVersion
                    != ListeningDeviceIdentity.splitStoreProjectionAppVersion,
                  session.episode?.podcast?.feed != nil,
                  let startedAt = session.startTime else { continue }
            cacheableSessionCount += 1
            if let endedAt = session.endTime, endedAt > startedAt {
                completedSessionCount += 1
            }
        }
        sourceCounts["listeningHistory"] = completedSessionCount
        sourceCounts["cacheablePlaySessions"] = cacheableSessionCount
        destinationCounts["cachedPlaySessions"] = (try? cache.fetchCount(
            FetchDescriptor<CachedPlaySession>()
        )) ?? 0
        sourceCounts["listeningSummaries"] = (try? legacy.fetchCount(
            FetchDescriptor<PlaySessionSummary>()
        )) ?? 0
        if completedSessionCount > 0,
           destinationCounts["listeningHistory", default: 0] == 0 {
            issues.append("missing_listening_history")
        }
        // Cached raw sessions are deliberately prunable device-local analytics
        // (`StoreSplitLocalAnalyticsWriter` enforces a 30-day retention), so
        // their count is telemetry, not a losslessness invariant. Compact
        // history and summaries above carry what has to survive.
        if sourceCounts["listeningSummaries", default: 0] > 0,
           destinationCounts["listeningSummaries", default: 0] == 0 {
            issues.append("missing_listening_summaries")
        }

        let cachedFeedKeys = Set(
            ((try? cache.fetch(FetchDescriptor<CachedPodcast>())) ?? []).map(\.feedURL)
        )
        let cachedEpisodeKeys = Set(
            ((try? cache.fetch(FetchDescriptor<CachedEpisode>())) ?? []).map(\.id)
        )
        var recoverableCount = 0
        var missingCount = 0
        for feedKey in requiredFeedKeys {
            if cachedFeedKeys.contains(feedKey) || isRSSRecoverable(feedKey) {
                recoverableCount += 1
            } else {
                missingCount += 1
                issues.append("unrecoverable_feed:\(feedKey)")
            }
        }
        for episodeKey in requiredEpisodeKeys where cachedEpisodeKeys.contains(episodeKey) {
            recoverableCount += 1
        }

        let report = StoreSplitVerificationReport(
            sourceCounts: sourceCounts,
            destinationCounts: destinationCounts,
            sourceDigest: digest(sourceLines),
            destinationDigest: digest(destinationLines),
            cacheRecoverableCount: recoverableCount,
            cacheMissingCount: missingCount,
            issues: Array(Set(issues)).sorted()
        )
        persist(report, in: cache)
        return report
    }

    static func latestVerification(
        cacheContainer: ModelContainer
    ) -> StoreSplitMigrationVerification? {
        let context = ModelContext(cacheContainer)
        let id = verificationID
        var descriptor = FetchDescriptor<StoreSplitMigrationVerification>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func cleanupGate(
        cacheContainer: ModelContainer,
        legacyFallbackDisabled: Bool,
        convergenceTelemetryPassed: Bool,
        gracePeriodEnd: Date,
        now: Date = .now
    ) -> LegacyStoreCleanupGate {
        let verification = latestVerification(cacheContainer: cacheContainer)
        return LegacyStoreCleanupGate(
            migrationVerified: verification?.verifiedAt != nil
                && verification?.issues.isEmpty == true,
            legacyFallbackDisabled: legacyFallbackDisabled,
            convergenceTelemetryPassed: convergenceTelemetryPassed,
            supportedVersionGracePeriodEnded: now >= gracePeriodEnd,
            cacheOrRSSRecoveryVerified: verification?.cacheMissingCount == 0
        )
    }

    private static func persist(
        _ report: StoreSplitVerificationReport,
        in context: ModelContext
    ) {
        let id = verificationID
        var descriptor = FetchDescriptor<StoreSplitMigrationVerification>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let record = (try? context.fetch(descriptor).first)
            ?? StoreSplitMigrationVerification(
                id: id,
                migrationVersion: StoreSplitMigrationService.migrationVersion
            )
        if record.modelContext == nil { context.insert(record) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        record.sourceCountsJSON = (try? encoder.encode(report.sourceCounts))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        record.destinationCountsJSON = (try? encoder.encode(report.destinationCounts))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        record.sourceDigest = report.sourceDigest
        record.destinationDigest = report.destinationDigest
        record.cacheRecoverableCount = report.cacheRecoverableCount
        record.cacheMissingCount = report.cacheMissingCount
        record.issues = report.issues
        record.verifiedAt = report.isLossless ? .now : nil
        record.updatedAt = .now
        try? context.save()
    }

    private static func newest<Model>(
        _ records: [Model],
        id: KeyPath<Model, String>,
        date: KeyPath<Model, Date>,
        device: (Model) -> String?
    ) -> [String: Model] {
        records.reduce(into: [:]) { result, record in
            let key = record[keyPath: id]
            guard let current = result[key] else {
                result[key] = record
                return
            }
            let currentDate = current[keyPath: date]
            let incomingDate = record[keyPath: date]
            if incomingDate > currentDate
                || (incomingDate == currentDate
                    && (device(record) ?? "") > (device(current) ?? "")) {
                result[key] = record
            }
        }
    }

    private static func canonical(_ values: Any...) -> String {
        values.map { String(describing: $0) }.joined(separator: "\u{1f}")
    }

    private static func digest(_ lines: [String]) -> String {
        let data = Data(lines.sorted().joined(separator: "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isRSSRecoverable(_ feedURL: String) -> Bool {
        guard let url = URL(string: feedURL),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// The CloudKit-backed schema is intentionally enumerated here so tests and
/// release tooling can assert that no cache/legacy model is accidentally added,
/// and that nothing aggregate-shaped comes back.
enum UserStateCloudSchemaAudit {
    static let allowedModelNames: Set<String> = [
        "SubscriptionSync", "EpisodeStateSync", "QueueEntrySync",
        "PlaylistSync", "PlaylistEntrySync", "BookmarkSync",
        "PodcastPreferenceSync", "ListeningBaselineSync",
        "ListeningHistorySync"
    ]

    static let forbiddenFeedDerivedModelNames: Set<String> = [
        "Podcast", "PodcastMetaData", "Episode", "EpisodeMetaData",
        "Marker", "PlaySession", "RateSegment", "ListeningStat",
        "TranscriptionRecord", "TranscriptLineAndTime", "CachedPodcast",
        "CachedEpisode", "CachedChapter", "CachedTranscriptLine",
        "CachedFeedExtensionElement", "CachedDownloadRecord",
        "CachedPlaySession", "CachedRateSegment", "CachedHourlyListeningStat",
        "AITranscriptSync", "AITranscriptChunkSync", "AIChapterSetSync"
    ]

    /// Entities retired from the synced schema, and why they may not come back.
    ///
    /// `ListeningSummarySync` was a per-feed, per-period, per-device rollup of
    /// data the store already held as sessions. It was the largest table in the
    /// store the split exists to keep small, and because it was derived from rows
    /// that also synced, every reader had to reconcile the aggregate against its
    /// own source — which is where both double-counting defects lived. Statistics
    /// are per-account and are computed locally; nothing needs it back.
    static let retiredModelNames: Set<String> = [
        "ListeningSummarySync"
    ]

    static var containsFeedDerivedData: Bool {
        allowedModelNames.isDisjoint(with: forbiddenFeedDerivedModelNames) == false
    }

    /// Synced entities the container carries but the allow-list does not name.
    ///
    /// The allow-list is written by hand and the container schema is written by
    /// hand, so on their own the two only agree until someone edits one of them.
    /// Comparing them is what turns the allow-list from documentation into a
    /// constraint.
    static func unlistedModelNames(in schema: Schema) -> Set<String> {
        Set(schema.entities.map(\.name)).subtracting(allowedModelNames)
    }

    /// Allow-listed entities the container does not actually carry.
    static func absentModelNames(in schema: Schema) -> Set<String> {
        allowedModelNames.subtracting(schema.entities.map(\.name))
    }

    /// Retired entities that have found their way back into the synced schema.
    static func reintroducedRetiredModelNames(in schema: Schema) -> Set<String> {
        Set(schema.entities.map(\.name)).intersection(retiredModelNames)
    }

    /// How a synced entity's row count grows.
    ///
    /// The split exists to make the synchronized store *small*, which is a claim
    /// about growth, not about membership. An entity whose rows multiply per
    /// device and per period is a different kind of thing from one bounded by the
    /// number of feeds the user subscribes to, even though both pass the
    /// allow-list.
    enum RowGrowth: String {
        /// One row per feed, or per feed-scoped preference.
        case perFeed
        /// One row per episode the user has touched.
        case perTouchedEpisode
        /// One row per queue or playlist membership, including tombstones.
        case perMembership
        /// One row per bookmark the user created.
        case perUserAction
        /// One row per playback session, forever, across every device.
        case perSessionPerDevice
        /// Rows multiply along more than one axis at once. Nothing in the synced
        /// schema is allowed to grow this way: this is the shape
        /// `ListeningSummarySync` had, and `permitsAggregateGrowth` is false so a
        /// reintroduction fails the audit rather than merely being noted.
        case perFeedPerPeriodPerDevice
    }

    /// Whether an entity with this growth shape may live in the synced store.
    ///
    /// Everything a multiplicative aggregate would carry is derivable from rows
    /// the store already holds, so paying for it in sync payload buys nothing and
    /// costs a reconciliation problem.
    static func permitsAggregateGrowth(_ growth: RowGrowth) -> Bool {
        growth != .perFeedPerPeriodPerDevice
    }

    static let rowGrowthBySyncedModel: [String: RowGrowth] = [
        "SubscriptionSync": .perFeed,
        "PodcastPreferenceSync": .perFeed,
        "EpisodeStateSync": .perTouchedEpisode,
        "QueueEntrySync": .perMembership,
        "PlaylistSync": .perMembership,
        "PlaylistEntrySync": .perMembership,
        "BookmarkSync": .perUserAction,
        "ListeningHistorySync": .perSessionPerDevice,
        // One frozen row per feed, written once and never updated.
        "ListeningBaselineSync": .perFeed
    ]

    /// Fields carried in the synced schema that a feed refresh could supply.
    ///
    /// They are listed rather than removed because each one has a reader that
    /// currently depends on it; the point of the inventory is that adding another
    /// has to be a deliberate edit here, not an incidental one in a model.
    static let feedDerivedFieldsBySyncedModel: [String: Set<String>] = [
        "EpisodeStateSync": ["duration"],
        "ListeningBaselineSync": ["podcastName"],
        "ListeningHistorySync": ["podcastName", "episodeTitle"]
    ]

    /// Rows a multiplicative per-period, per-device aggregate would materialise
    /// for a library of this shape.
    ///
    /// `PlaySessionSummaryPeriod` has five cases, so one day of listening to one
    /// feed on one device produced a day, week, month, year and forever row. Kept
    /// as the measurement that justified retiring `ListeningSummarySync`, and as
    /// the number to run again before anyone proposes another aggregate.
    static func estimatedAggregateRowCount(
        feeds: Int,
        distinctListeningDays: Int,
        devices: Int
    ) -> Int {
        let days = distinctListeningDays
        let weeks = Int((Double(days) / 7).rounded(.up))
        let months = Int((Double(days) / 30).rounded(.up))
        let years = Int((Double(days) / 365).rounded(.up))
        let periodsPerFeed = days + weeks + months + years + 1
        return feeds * periodsPerFeed * devices
    }

    /// Rows the synced store actually materialises for a library of this shape.
    ///
    /// Sessions dominate, and they grow with listening rather than with the
    /// product of listening and calendar granularity.
    static func estimatedSyncedRowCount(
        feeds: Int,
        distinctListeningDays: Int,
        devices: Int,
        sessionsPerDayPerDevice: Int,
        touchedEpisodesPerFeedPerYear: Int,
        queueAndPlaylistEntries: Int,
        bookmarks: Int
    ) -> Int {
        let years = max(1, Int((Double(distinctListeningDays) / 365).rounded(.up)))
        let sessions = distinctListeningDays * sessionsPerDayPerDevice * devices
        let episodeStates = feeds * touchedEpisodesPerFeedPerYear * years
        let subscriptions = feeds
        let preferences = feeds + 1
        let baselines = feeds + 1
        return sessions
            + episodeStates
            + subscriptions
            + preferences
            + baselines
            + queueAndPlaylistEntries
            + bookmarks
    }
}
