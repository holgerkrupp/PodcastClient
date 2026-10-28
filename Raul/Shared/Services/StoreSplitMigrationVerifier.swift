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
    private static let verificationInvalidatedKey = "storeSplit.verificationAttemptInvalidated.v1"

    private static var verificationDefaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    /// Invalidates any older full-store result before a production verification
    /// stage admits work. The local history stage is narrower than the global
    /// proof and must never leave a stale green marker readable.
    @discardableResult
    static func invalidateForMigrationStage(in context: ModelContext) -> Bool {
        verificationDefaults.set(true, forKey: verificationInvalidatedKey)
        return invalidatePreviousVerification(in: context) == nil
    }

    /// Builds the local half of the authority-release gate. Population-level
    /// convergence and delayed-import evidence are supplied by release
    /// telemetry because they cannot be inferred from one device's SQLite file.
    static func cutoverGate(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer,
        allDevicesConverged: Bool,
        delayedCloudImportsSettled: Bool
    ) -> StoreSplitCutoverGate {
        StoreSplitCutoverGate(
            localBackfillComplete: StoreSplitMigrationService.isSliceMigrationComplete(
                cacheContainer: cacheContainer
            ),
            localVerificationPassed: StoreSplitMigrationService.isMigrationVerified(
                cacheContainer: cacheContainer
            ),
            podcastCacheReady: StoreSplitFeedCacheReadiness.read(
                legacyContext: ModelContext(legacyContainer),
                cacheContext: ModelContext(cacheContainer)
            ).isSafeForCutover,
            allDevicesConverged: allDevicesConverged,
            delayedCloudImportsSettled: delayedCloudImportsSettled
        )
    }

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

        // Invalidate an older green result before beginning a new attempt. If a
        // later source read fails, a stale verification must not remain usable
        // as evidence for this migration revision.
        verificationDefaults.set(true, forKey: verificationInvalidatedKey)
        if let invalidationFailure = invalidatePreviousVerification(in: cache) {
            return failedReport("verification_invalidation_failed:\(invalidationFailure)")
        }

        func read<T>(_ label: String, fallback: T, _ operation: () throws -> T) -> T {
            do {
                return try operation()
            } catch {
                // Do not include storage error strings: they may contain private
                // store paths or other diagnostic data.
                issues.append("verification_fetch_failed:\(label)")
                return fallback
            }
        }

        let subscriptions = newest(
            read("user_state_subscriptions", fallback: []) {
                try userState.fetch(FetchDescriptor<SubscriptionSync>())
            },
            id: \SubscriptionSync.id,
            date: \SubscriptionSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let episodeStates = newest(
            read("user_state_episode_states", fallback: []) {
                try userState.fetch(FetchDescriptor<EpisodeStateSync>())
            },
            id: \EpisodeStateSync.id,
            date: \EpisodeStateSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let playlists = newest(
            read("user_state_playlists", fallback: []) {
                try userState.fetch(FetchDescriptor<PlaylistSync>())
            },
            id: \PlaylistSync.id,
            date: \PlaylistSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let playlistEntries = newest(
            read("user_state_playlist_entries", fallback: []) {
                try userState.fetch(FetchDescriptor<PlaylistEntrySync>())
            },
            id: \PlaylistEntrySync.id,
            date: \PlaylistEntrySync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let bookmarks = newest(
            read("user_state_bookmarks", fallback: []) {
                try userState.fetch(FetchDescriptor<BookmarkSync>())
            },
            id: \BookmarkSync.id,
            date: \BookmarkSync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        let preferences = newest(
            read("user_state_preferences", fallback: []) {
                try userState.fetch(FetchDescriptor<PodcastPreferenceSync>())
            },
            id: \PodcastPreferenceSync.id,
            date: \PodcastPreferenceSync.updatedAt,
            device: { $0.sourceDeviceID }
        )

        destinationCounts["subscriptions"] = subscriptions.count
        destinationCounts["episodeStates"] = episodeStates.count
        destinationCounts["playlists"] = playlists.count
        destinationCounts["playlistEntries"] = playlistEntries.count
        let queueEntries = newest(
            read("user_state_queue_entries", fallback: []) {
                try userState.fetch(FetchDescriptor<QueueEntrySync>())
            },
            id: \QueueEntrySync.id,
            date: \QueueEntrySync.updatedAt,
            device: { $0.sourceDeviceID }
        )
        destinationCounts["queueEntries"] = queueEntries.count
        destinationCounts["bookmarks"] = bookmarks.count
        destinationCounts["preferences"] = preferences.count
        let destinationHistory = read("user_state_listening_history", fallback: [ListeningHistorySync]()) {
            try userState.fetch(FetchDescriptor<ListeningHistorySync>())
        }
        let destinationBaselines = read("user_state_listening_baselines", fallback: [ListeningBaselineSync]()) {
            try userState.fetch(FetchDescriptor<ListeningBaselineSync>())
        }
        destinationCounts["listeningHistory"] = destinationHistory.count
        destinationCounts["listeningBaselines"] = destinationBaselines.count

        var requiredFeedKeys = Set<String>()
        var requiredEpisodeKeys = Set<String>()
        var sourceSubscriptionKeys = Set<String>()
        var sourceEpisodeStateKeys = Set<String>()
        var sourcePlaylistIDs = Set<String>()
        var sourcePlaylistEntryIDs = Set<String>()
        var sourceQueueEntryIDs = Set<String>()
        var sourceBookmarkIDs = Set<String>()
        var sourcePreferenceIDs = Set<String>()
        let legacyPodcasts = read("legacy_podcasts", fallback: [Podcast]()) {
            try legacy.fetch(FetchDescriptor<Podcast>())
        }
        sourceCounts["subscriptions"] = 0
        for podcast in legacyPodcasts {
            guard let feed = podcast.feed else { continue }
            let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
            requiredFeedKeys.insert(feedKey)
            sourceCounts["subscriptions", default: 0] += 1
            let subscribedAt = podcast.metaData?.subscriptionDate ?? .distantPast
            let isSubscribed = podcast.metaData?.isSubscribed != false
            if isSubscribed { sourceSubscriptionKeys.insert(feedKey) }
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

        let legacyEpisodes = read("legacy_episodes", fallback: [Episode]()) {
            try legacy.fetch(FetchDescriptor<Episode>())
        }
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
            sourceEpisodeStateKeys.insert(identity.key)
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

        let legacyPlaylists = read("legacy_playlists", fallback: [Playlist]()) {
            try legacy.fetch(FetchDescriptor<Playlist>())
        }
        sourceCounts["playlists"] = legacyPlaylists.count
        sourceCounts["playlistEntries"] = 0
        for playlist in legacyPlaylists {
            let playlistID = playlist.storeSplitSyncID
            sourcePlaylistIDs.insert(playlistID)
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
                sourcePlaylistEntryIDs.insert(entryID)
                if playlist.title == Playlist.defaultQueueTitle {
                    sourceQueueEntryIDs.insert(identity.key)
                }
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

        let legacyBookmarks = read("legacy_bookmarks", fallback: [Bookmark]()) {
            try legacy.fetch(FetchDescriptor<Bookmark>())
        }
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
            sourceBookmarkIDs.insert(bookmarkID)
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

        let legacyPreferences = read("legacy_preferences", fallback: [PodcastSettings]()) {
            try legacy.fetch(FetchDescriptor<PodcastSettings>())
        }
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
            sourcePreferenceIDs.insert(id)
            if preferences[id] == nil { issues.append("missing_preference:\(id)") }
        }

        sourceCounts["queueEntries"] = sourceQueueEntryIDs.count
        let appendDestinationOnlyIssue: (String, Set<String>, Set<String>) -> Void = {
            label, destinationIDs, sourceIDs in
            let count = destinationIDs.subtracting(sourceIDs).count
            if count > 0 { issues.append("destination_only_\(label):\(count)") }
        }
        appendDestinationOnlyIssue(
            "subscriptions",
            Set(subscriptions.values.filter {
                $0.isSubscribed && $0.unsubscribedAt == nil
            }.map {
                URL(string: $0.feedURL)
                    .map(PodcastFeedIdentity.normalizedFeedURLString)
                    ?? $0.feedURL
            }),
            sourceSubscriptionKeys
        )
        appendDestinationOnlyIssue(
            "episode_states",
            Set(episodeStates.values.map(\.id)),
            sourceEpisodeStateKeys
        )
        appendDestinationOnlyIssue(
            "playlists",
            Set(playlists.values.filter {
                $0.isDeleted == false && $0.deletedAt == nil
            }.map(\.id)),
            sourcePlaylistIDs
        )
        appendDestinationOnlyIssue(
            "playlist_entries",
            Set(playlistEntries.values.filter {
                $0.isDeleted == false && $0.deletedAt == nil
            }.map(\.id)),
            sourcePlaylistEntryIDs
        )
        appendDestinationOnlyIssue(
            "queue_entries",
            Set(queueEntries.values.filter {
                $0.isDeleted == false && $0.deletedAt == nil
            }.map(\.id)),
            sourceQueueEntryIDs
        )
        appendDestinationOnlyIssue(
            "bookmarks",
            Set(bookmarks.values.filter {
                $0.isDeleted == false && $0.deletedAt == nil
            }.map(\.id)),
            sourceBookmarkIDs
        )
        appendDestinationOnlyIssue(
            "preferences",
            Set(preferences.values.map(\.id)),
            sourcePreferenceIDs
        )

        // Only sessions the migration can actually carry count as source rows.
        // A session with no episode, no start time, or no clean end has nothing
        // to key a cache row or a compact history record on, and rows the
        // importer projected back from UserState are not an independent source.
        // Counting them made verification permanently unsatisfiable, which left
        // the rollout stuck before the read cutover.
        let legacySessions = read("legacy_play_sessions", fallback: [PlaySession]()) {
            try legacy.fetch(FetchDescriptor<PlaySession>())
        }
        var expectedHistory: [String: ListeningHistorySync] = [:]
        var expectedIncompleteCacheSessions: [String: CachedPlaySession] = [:]
        var cacheableSessionCount = 0
        for session in legacySessions {
            guard session.appVersion
                    != ListeningDeviceIdentity.splitStoreProjectionAppVersion,
                  let episode = session.episode,
                  episode.podcast?.feed != nil,
                  let startedAt = session.startTime else { continue }
            cacheableSessionCount += 1
            let identity = episode.stableEpisodeIdentity
            let startPosition = session.startPosition ?? 0
            if session.endTime.map({ $0 > startedAt }) != true {
                let cacheID = session.id?.uuidString ?? StableIdentityKey.uuid(for:
                    StableIdentityKey.make(identity.key, String(Int(startedAt.timeIntervalSince1970)))
                ).uuidString
                expectedIncompleteCacheSessions[cacheID] = CachedPlaySession(
                    id: cacheID,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    podcastName: session.podcastName ?? episode.displayPodcastTitle,
                    episodeTitle: episode.title,
                    sourceDeviceID: session.sourceDeviceID ?? StableIdentityKey.make(
                        "legacy-device", session.deviceModel ?? "unknown-model",
                        session.osVersion ?? "unknown-os"
                    ),
                    sourceDeviceName: session.sourceDeviceName ?? session.deviceModel ?? "Legacy device",
                    deviceModel: session.deviceModel,
                    osVersion: session.osVersion,
                    appVersion: session.appVersion,
                    startedAt: startedAt,
                    endedAt: nil,
                    startPosition: startPosition,
                    endPosition: session.endPosition,
                    silenceGapTimeSavedSeconds: max(0, session.silenceGapTimeSavedSeconds ?? 0),
                    playbackRateTimeSavedSeconds: max(0, PlaybackRateSavingsCalculator.secondsSaved(in: session)),
                    endedCleanly: session.endedCleanly == true,
                    updatedAt: startedAt
                )
                continue
            }
            guard let endedAt = session.endTime else { continue }
            let endPosition = session.endPosition ?? 0
            let id = ListeningHistoryIdentity.make(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: startPosition,
                endPosition: endPosition
            )
            let sourceDeviceID = session.sourceDeviceID ?? StableIdentityKey.make(
                "legacy-device", session.deviceModel ?? "unknown-model",
                session.osVersion ?? "unknown-os"
            )
            let expected = ListeningHistorySync(
                id: id,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                podcastName: session.podcastName ?? episode.displayPodcastTitle,
                episodeTitle: episode.title,
                sourceDeviceID: sourceDeviceID,
                sourceDeviceName: session.sourceDeviceName ?? session.deviceModel ?? "Legacy device",
                deviceModel: session.deviceModel,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: startPosition,
                endPosition: endPosition,
                listenedSeconds: endedAt.timeIntervalSince(startedAt),
                silenceGapTimeSavedSeconds: session.silenceGapTimeSavedSeconds ?? 0,
                playbackRateTimeSavedSeconds: PlaybackRateSavingsCalculator.secondsSaved(in: session),
                endedCleanly: session.endedCleanly == true,
                isLegacyMigrated: true,
                updatedAt: endedAt
            )
            if let previous = expectedHistory[id], historyPayload(previous) != historyPayload(expected) {
                issues.append("conflicting_legacy_listening_history:\(id)")
            } else {
                expectedHistory[id] = expected
                sourceLines.append(canonical("listeningHistory", id, historyPayload(expected)))
            }
        }
        let destinationHistoryByID = newest(
            destinationHistory,
            id: \.id,
            date: \.updatedAt,
            device: { $0.sourceDeviceID }
        )
        for (id, record) in destinationHistoryByID {
            destinationLines.append(canonical("listeningHistory", id, historyPayload(record)))
        }
        sourceCounts["listeningHistory"] = expectedHistory.count
        sourceCounts["cacheablePlaySessions"] = cacheableSessionCount
        for (id, expected) in expectedHistory {
            guard let actual = destinationHistoryByID[id] else {
                issues.append("missing_listening_history:\(id)")
                continue
            }
            requiredFeedKeys.insert(expected.feedURL)
            requiredEpisodeKeys.insert(StableIdentityKey.make(expected.feedURL, expected.episodeID))
            // CloudKit can deliver a newer version from another device. Keep it
            // and classify it as authoritative; equal/older rows must match the
            // complete migrated payload exactly.
            if actual.updatedAt <= expected.updatedAt,
               historyPayload(actual) != historyPayload(expected) {
                issues.append("listening_history_fields:\(id)")
            }
        }
        let cachedSessionsByID = Dictionary(
            read("cache_play_session_rows", fallback: [CachedPlaySession]()) {
                try cache.fetch(FetchDescriptor<CachedPlaySession>())
            }.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in first.updatedAt >= second.updatedAt ? first : second }
        )
        destinationCounts["cachedPlaySessions"] = cachedSessionsByID.count
        sourceCounts["incompletePlaySessions"] = expectedIncompleteCacheSessions.count
        for (id, expected) in expectedIncompleteCacheSessions {
            guard let actual = cachedSessionsByID[id] else {
                issues.append("missing_incomplete_cached_session:\(id)")
                continue
            }
            if cachedSessionPayload(actual) != cachedSessionPayload(expected) {
                issues.append("incomplete_cached_session_fields:\(id)")
            }
            requiredFeedKeys.insert(expected.feedURL)
            requiredEpisodeKeys.insert(StableIdentityKey.make(expected.feedURL, expected.episodeID))
            sourceLines.append(canonical("incompleteSession", id, cachedSessionPayload(expected)))
            destinationLines.append(canonical("incompleteSession", id, cachedSessionPayload(actual)))
        }
        // Legacy summaries do not migrate one-to-one: they collapse into the
        // frozen per-feed `ListeningBaselineSync` rows, and only the summaries
        // in the baseline period tier that carry positive time produce a row.
        // Comparing the raw summary count against a `listeningSummaries`
        // destination bucket nothing ever writes made this issue permanent for
        // every user with listening history, so `isMigrationVerified` and the
        // cleanup/convergence gate could never pass.
        let legacySummaries = read("legacy_listening_summaries", fallback: [PlaySessionSummary]()) {
            try legacy.fetch(FetchDescriptor<PlaySessionSummary>())
        }
        let baselineFeedKeys = baselineEligibleFeedKeys(in: legacySummaries)
        sourceCounts["listeningSummaries"] = legacySummaries.count
        sourceCounts["listeningBaselines"] = baselineFeedKeys.count
        let expectedBaselines = baselineTotals(in: legacySummaries)
        let destinationBaselinesByFeed = Dictionary(
            destinationBaselines.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, second in
                first.capturedAt >= second.capturedAt ? first : second
            }
        )
        for (feed, baseline) in destinationBaselinesByFeed {
            destinationLines.append(canonical(
                "listeningBaseline", feed, baseline.totalSeconds,
                baseline.silenceGapTimeSavedSeconds,
                baseline.playbackRateTimeSavedSeconds
            ))
        }
        for feed in baselineFeedKeys {
            guard let expected = expectedBaselines[feed],
                  let actual = destinationBaselinesByFeed[feed] else {
                issues.append("missing_listening_baseline:\(feed)")
                continue
            }
            if !approximatelyEqual(actual.totalSeconds, expected.totalSeconds)
                || !approximatelyEqual(actual.silenceGapTimeSavedSeconds, expected.silenceSaved)
                || !approximatelyEqual(actual.playbackRateTimeSavedSeconds, expected.playbackRateSaved)
                || actual.id != feed {
                // Baselines are immutable first-writer snapshots with no update
                // version that can prove which device's value is newer. Preserve
                // the destination row and keep readiness blocked on conflict.
                issues.append("listening_baseline_conflict:\(feed)")
            }
            sourceLines.append(canonical(
                "listeningBaseline", feed, expected.totalSeconds,
                expected.silenceSaved, expected.playbackRateSaved
            ))
        }
        let destinationOnlyBaselineCount = Set(destinationBaselinesByFeed.keys)
            .subtracting(baselineFeedKeys).count
        if destinationOnlyBaselineCount > 0 {
            issues.append("destination_only_listening_baselines:\(destinationOnlyBaselineCount)")
        }

        let cachedFeedKeys = Set(read("cache_podcasts", fallback: [CachedPodcast]()) {
            try cache.fetch(FetchDescriptor<CachedPodcast>())
        }.map(\.feedURL))
        let cachedEpisodeKeys = Set(read("cache_episodes", fallback: [CachedEpisode]()) {
            try cache.fetch(FetchDescriptor<CachedEpisode>())
        }.map(\.id))
        var recoverableCount = 0
        var missingCount = 0
        for feedKey in requiredFeedKeys {
            // This verifier has no evidence that a URL currently resolves to a
            // validated RSS feed (or that private-feed credentials are present).
            // A syntactically valid HTTP URL is not recovery proof.
            if cachedFeedKeys.contains(feedKey) {
                recoverableCount += 1
            } else {
                missingCount += 1
                issues.append("unrecoverable_feed:\(feedKey)")
            }
        }
        for episodeKey in requiredEpisodeKeys {
            if cachedEpisodeKeys.contains(episodeKey) {
                recoverableCount += 1
            } else {
                missingCount += 1
                issues.append("missing_cached_episode:\(episodeKey)")
            }
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
        if persist(report, in: cache) == false {
            return failedReport("verification_persistence_failed")
        }
        return report
    }

    static func latestVerification(
        cacheContainer: ModelContainer
    ) -> StoreSplitMigrationVerification? {
        guard verificationDefaults.bool(forKey: verificationInvalidatedKey) == false else {
            return nil
        }
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

    private static func invalidatePreviousVerification(in context: ModelContext) -> String? {
        let id = verificationID
        var descriptor = FetchDescriptor<StoreSplitMigrationVerification>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            guard let record = try context.fetch(descriptor).first else { return nil }
            guard record.verifiedAt != nil else { return nil }
            record.verifiedAt = nil
            record.issues = ["verification_in_progress"]
            record.updatedAt = .now
            try context.save()
            return nil
        } catch {
            context.rollback()
            return "cache_store_unavailable"
        }
    }

    private static func failedReport(_ issue: String) -> StoreSplitVerificationReport {
        StoreSplitVerificationReport(
            sourceCounts: [:],
            destinationCounts: [:],
            sourceDigest: "",
            destinationDigest: "",
            cacheRecoverableCount: 0,
            cacheMissingCount: 0,
            issues: [issue]
        )
    }

    private static func persist(
        _ report: StoreSplitVerificationReport,
        in context: ModelContext
    ) -> Bool {
        let id = verificationID
        var descriptor = FetchDescriptor<StoreSplitMigrationVerification>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            let existing = try context.fetch(descriptor).first
            let record = existing ?? StoreSplitMigrationVerification(
                id: id,
                migrationVersion: StoreSplitMigrationService.migrationVersion
            )
            if existing == nil { context.insert(record) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            record.sourceCountsJSON = String(decoding: try encoder.encode(report.sourceCounts), as: UTF8.self)
            record.destinationCountsJSON = String(decoding: try encoder.encode(report.destinationCounts), as: UTF8.self)
            record.sourceDigest = report.sourceDigest
            record.destinationDigest = report.destinationDigest
            record.cacheRecoverableCount = report.cacheRecoverableCount
            record.cacheMissingCount = report.cacheMissingCount
            record.issues = report.issues
            record.verifiedAt = report.isLossless ? .now : nil
            record.updatedAt = .now
            try context.save()
            verificationDefaults.set(false, forKey: verificationInvalidatedKey)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    /// The feeds a baseline row is actually expected for, derived exactly the
    /// way `StoreSplitMigrationService` derives them: only the coarsest period
    /// tier the store has, only rows with a period start, and only feeds whose
    /// summed time is positive. Anything else is legitimately dropped, so it
    /// must not count as a source row here.
    private static func baselineEligibleFeedKeys(
        in summaries: [PlaySessionSummary]
    ) -> Set<String> {
        Set(baselineTotals(in: summaries).filter { $0.value.totalSeconds > 0 }.keys)
    }

    private struct BaselineTotals {
        var totalSeconds: Double = 0
        var silenceSaved: Double = 0
        var playbackRateSaved: Double = 0
    }

    private static func baselineTotals(
        in summaries: [PlaySessionSummary]
    ) -> [String: BaselineTotals] {
        guard let baselineKind = StoreSplitMigrationService.baselinePeriodKind(
            in: summaries
        ) else { return [:] }
        var totals: [String: BaselineTotals] = [:]
        for summary in summaries {
            guard summary.periodKind == baselineKind,
                  summary.periodStart != nil else { continue }
            let feedURL = summary.podcastFeed
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? ListeningBaselineSync.allPodcastsFeedURL
            var value = totals[feedURL] ?? BaselineTotals()
            value.totalSeconds += max(0, summary.totalSeconds ?? 0)
            value.silenceSaved += max(0, summary.silenceGapTimeSavedSeconds ?? 0)
            value.playbackRateSaved += max(0, summary.playbackRateTimeSavedSeconds ?? 0)
            totals[feedURL] = value
        }
        return totals
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(0.001, max(abs(lhs), abs(rhs)) * 0.000_001)
    }

    private static func historyPayload(_ record: ListeningHistorySync) -> String {
        canonical(
            record.feedURL,
            record.episodeID,
            record.podcastName ?? "",
            record.episodeTitle ?? "",
            record.startedAt.timeIntervalSince1970,
            record.endedAt.timeIntervalSince1970,
            record.listenedSeconds,
            record.startPosition,
            record.endPosition,
            record.silenceGapTimeSavedSeconds,
            record.playbackRateTimeSavedSeconds,
            record.sourceDeviceID,
            record.sourceDeviceName ?? "",
            record.deviceModel ?? "",
            record.endedCleanly,
            record.isLegacyMigrated
        )
    }

    private static func cachedSessionPayload(_ record: CachedPlaySession) -> String {
        canonical(
            record.feedURL,
            record.episodeID,
            record.podcastName ?? "",
            record.episodeTitle ?? "",
            record.sourceDeviceID,
            record.sourceDeviceName ?? "",
            record.deviceModel ?? "",
            record.osVersion ?? "",
            record.appVersion ?? "",
            record.startedAt.timeIntervalSince1970,
            record.endedAt?.timeIntervalSince1970 ?? 0,
            record.startPosition,
            record.endPosition ?? 0,
            record.silenceGapTimeSavedSeconds,
            record.playbackRateTimeSavedSeconds,
            record.endedCleanly
        )
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
