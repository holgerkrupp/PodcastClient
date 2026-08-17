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
        destinationCounts["listeningSummaries"] =
            (try? userState.fetchCount(FetchDescriptor<ListeningSummarySync>())) ?? 0

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
/// release tooling can assert that no cache/legacy model is accidentally added.
enum UserStateCloudSchemaAudit {
    static let allowedModelNames: Set<String> = [
        "SubscriptionSync", "EpisodeStateSync", "QueueEntrySync",
        "PlaylistSync", "PlaylistEntrySync", "BookmarkSync",
        "PodcastPreferenceSync", "ListeningSummarySync",
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

    static var containsFeedDerivedData: Bool {
        allowedModelNames.isDisjoint(with: forbiddenFeedDerivedModelNames) == false
    }
}
