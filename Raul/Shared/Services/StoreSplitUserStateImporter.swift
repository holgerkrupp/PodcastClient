import Foundation
import SwiftData
import CryptoKit

struct StoreSplitUserStateImportResult: Sendable {
    var subscriptionsApplied = 0
    var episodeStatesApplied = 0
    var playlistsApplied = 0
    var playlistEntriesApplied = 0
    var bookmarksApplied = 0
    var listeningHistoryApplied = 0
    var duplicatePodcastsHidden = 0
    var feedsToBootstrap: [URL] = []
    var failed = 0
    var interruptedByPlayback = false
}

actor StoreSplitUserStateImporter {
    private let sourcePageSize = 200
    private let historyPageSize = 100
    /// Page size for the last-resort feed scan. Kept small so each batch of
    /// faulted episodes is released before the next one loads.
    private let episodeScanPageSize = 200
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private var legacyContext: ModelContext
    private var userStateContext: ModelContext
    private var podcastsByComparisonKey: [String: PersistentIdentifier] = [:]
    private var resolvedEpisodeIDsByIdentity: [String: PersistentIdentifier?] = [:]

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
    }

    nonisolated static func apply(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        authoritativePlaylists: Bool = false,
        projectListeningHistoryToLegacy: Bool = true,
        episodeStateProjectionRecencyCutoff: Date? = nil
    ) async -> StoreSplitUserStateImportResult {
        // Run inline (not detached) so cancellation from the caller's task
        // propagates into the importer. A detached task would keep scanning the
        // legacy store after the app is backgrounded, holding the app-group
        // SQLite lock across suspension and triggering an 0xdead10cc kill.
        let importer = StoreSplitUserStateImporter(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        return await importer.run(
            authoritativePlaylists: authoritativePlaylists,
            projectListeningHistoryToLegacy: projectListeningHistoryToLegacy,
            episodeStateProjectionRecencyCutoff: episodeStateProjectionRecencyCutoff
        )
    }

    private func run(
        authoritativePlaylists: Bool,
        projectListeningHistoryToLegacy: Bool,
        episodeStateProjectionRecencyCutoff: Date?
    ) async -> StoreSplitUserStateImportResult {
        var result = StoreSplitUserStateImportResult()
        guard Task.isCancelled == false else {
            result.interruptedByPlayback = true
            return result
        }
        await awaitIdleWindow()
        let podcasts = (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? []
        podcastsByComparisonKey = podcasts.reduce(into: [String: PersistentIdentifier]()) { values, podcast in
            guard let feed = podcast.feed else { return }
            for key in feed.podcastFeedComparisonKeys {
                if let existing = values[key] {
                    guard let existingPodcast = legacyContext.model(for: existing) as? Podcast else {
                        values[key] = podcast.persistentModelID
                        continue
                    }
                    values[key] = preferredPodcast(existingPodcast, podcast).persistentModelID
                } else {
                    values[key] = podcast.persistentModelID
                }
            }
        }

        let subscriptions = deduplicatedSubscriptions(
            (try? userStateContext.fetch(FetchDescriptor<SubscriptionSync>())) ?? [],
        )
        for subscription in subscriptions.values {
            guard let feedURL = URL(string: subscription.feedURL) else {
                result.failed += 1
                continue
            }
            let podcast = feedURL.podcastFeedComparisonKeys.compactMap {
                podcastsByComparisonKey[$0]
                    .flatMap { legacyContext.model(for: $0) as? Podcast }
            }.first ?? {
                guard subscription.isSubscribed else { return nil }
                let podcast = Podcast(feed: feedURL)
                legacyContext.insert(podcast)
                for key in feedURL.podcastFeedComparisonKeys {
                    self.podcastsByComparisonKey[key] = podcast.persistentModelID
                }
                result.feedsToBootstrap.append(feedURL)
                return podcast
            }()
            guard let podcast else { continue }

            let metadata = ensureMetadata(for: podcast)
            metadata.isSubscribed = subscription.isSubscribed
            if subscription.isSubscribed {
                metadata.subscriptionDate = metadata.subscriptionDate ?? subscription.subscribedAt
                if let titleOverride = nonEmpty(subscription.titleOverride) {
                    podcast.title = titleOverride
                }
            }
            result.subscriptionsApplied += 1
        }
        if StoreDevelopmentConfiguration.modeAllowsDuplicateCleanupDuringProjection {
            result.duplicatePodcastsHidden = hideDuplicatePodcasts(podcasts)
        }
        saveLegacyChanges(phase: "subscriptions", result: &result)
        refreshContexts()
        if await shouldStop() {
            result.interruptedByPlayback = true
            return result
        }

        await awaitIdleWindow()
        await applyEpisodeStates(
            recencyCutoff: episodeStateProjectionRecencyCutoff,
            result: &result
        )
        await awaitIdleWindow()
        await applyPlaylists(
            authoritative: authoritativePlaylists,
            result: &result
        )
        await awaitIdleWindow()
        await applyBookmarks(
            result: &result
        )
        saveLegacyChanges(phase: "user_state", result: &result)
        if await shouldStop() {
            result.interruptedByPlayback = true
            return result
        }
        if projectListeningHistoryToLegacy {
            await awaitIdleWindow()
            await applyListeningHistory(
                result: &result
            )
            saveLegacyChanges(phase: "listening_history_final", result: &result)
        } else {
            clearProjectedListeningHistory(result: &result)
        }

        result.feedsToBootstrap = Array(Set(result.feedsToBootstrap)).sorted {
            $0.absoluteString < $1.absoluteString
        }
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_completed",
            details: "subscriptions=\(result.subscriptionsApplied),episodes=\(result.episodeStatesApplied),playlists=\(result.playlistsApplied),entries=\(result.playlistEntriesApplied),bookmarks=\(result.bookmarksApplied),history=\(result.listeningHistoryApplied),duplicates=\(result.duplicatePodcastsHidden),feeds=\(result.feedsToBootstrap.count),failed=\(result.failed)"
        )
#if DEBUG
        logProjectionAudit(result: result)
#endif
        return result
    }

    private func applyEpisodeStates(
        recencyCutoff: Date?,
        result: inout StoreSplitUserStateImportResult
    ) async {
        var offset = 0
        var seenStateIDs = Set<String>()

        while true {
            await awaitIdleWindow()
            let page = fetchPage(
                EpisodeStateSync.self,
                offset: offset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\EpisodeStateSync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            let freshStates = page.filter {
                seenStateIDs.insert($0.id).inserted
                && shouldProjectEpisodeState($0, recencyCutoff: recencyCutoff)
            }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshStates.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )

            for state in freshStates {
                let identityKey = stableIdentityKey(
                    feedURL: state.feedURL,
                    episodeID: state.episodeID
                )
                guard let episode = episodesByIdentity[identityKey] else {
                    appendMissingFeed(state.feedURL, to: &result)
                    continue
                }
                let metadata = ensureMetadata(for: episode)
                setIfChanged(metadata, \.playPosition, max(0, state.playPosition))
                setIfChanged(
                    metadata,
                    \.maxPlayposition,
                    max(0, state.maxPlayPosition, state.playPosition)
                )
                setIfChanged(metadata, \.lastPlayed, state.lastPlayedAt)
                setIfChanged(metadata, \.firstListenDate, state.firstPlayedAt)
                setIfChanged(metadata, \.completionDate, state.completedAt)
                setIfChanged(metadata, \.archivedAt, state.archivedAt)
                setIfChanged(metadata, \.wasSkipped, state.wasSkipped)
                setIfChanged(metadata, \.isArchived, state.isArchived)
                setIfChanged(metadata, \.isHistory, state.isPlayed)

                if state.isArchived {
                    setIfChanged(metadata, \.status, .archived)
                    setIfChanged(metadata, \.isInbox, false)
                } else if state.isPlayed {
                    setIfChanged(metadata, \.status, .history)
                    setIfChanged(metadata, \.isInbox, false)
                } else if metadata.status == .archived || metadata.status == .history {
                    setIfChanged(metadata, \.status, .inbox)
                    setIfChanged(metadata, \.isInbox, true)
                }
                result.episodeStatesApplied += 1
            }

            saveLegacyChanges(
                phase: "episode_states_batch_\(offset)",
                result: &result
            )
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            offset += page.count
        }
    }

    private func applyPlaylists(
        authoritative: Bool,
        result: inout StoreSplitUserStateImportResult
    ) async {
        var localPlaylists = ((try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? [])
            .reduce(into: [String: Playlist]()) { $0[$1.id.uuidString] = $1 }
        var localPlaylistBySyncedID: [String: Playlist] = [:]
        var seenLogicalPlaylists = Set<String>()
        var playlistOffset = 0

        while true {
            let page = fetchPage(
                PlaylistSync.self,
                offset: playlistOffset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\PlaylistSync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            for record in page {
                let logicalKey = StableIdentityKey.make(
                    record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    record.kindRawValue
                )
                guard seenLogicalPlaylists.insert(logicalKey).inserted else {
                    continue
                }

                guard let playlistID = UUID(uuidString: record.id) else {
                    result.failed += 1
                    continue
                }
                let playlist = localPlaylists[record.id]
                    ?? matchingLocalPlaylist(
                        for: record,
                        among: Array(localPlaylists.values)
                    )
                    ?? {
                        let playlist = Playlist()
                        playlist.id = playlistID
                        legacyContext.insert(playlist)
                        localPlaylists[record.id] = playlist
                        return playlist
                    }()
                localPlaylistBySyncedID[record.id] = playlist

                if record.isDeleted || record.deletedAt != nil {
                    guard playlist.title != Playlist.defaultQueueTitle else { continue }
                    playlist.hidden = true
                    for entry in playlist.items ?? [] {
                        legacyContext.delete(entry)
                    }
                    result.playlistsApplied += 1
                    continue
                }

                playlist.title = record.title
                playlist.symbolName = record.symbolName
                playlist.sortIndex = record.sortIndex
                playlist.kindRawValue = record.kindRawValue
                playlist.hidden = record.isHidden
                playlist.deleteable = record.title != Playlist.defaultQueueTitle
                playlist.smartFilter = record.smartFilterRawValue
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap {
                        try? JSONDecoder().decode(SmartPlaylistFilter.self, from: $0)
                    }
                result.playlistsApplied += 1
            }

            saveLegacyChanges(
                phase: "playlists_batch_\(playlistOffset)",
                result: &result
            )
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            playlistOffset += page.count
        }

        var activeRemoteIdentitiesByPlaylistID: [String: Set<String>] = [:]
        var seenEntryIDs = Set<String>()
        var entryOffset = 0

        while true {
            let page = fetchPage(
                PlaylistEntrySync.self,
                offset: entryOffset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\PlaylistEntrySync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            let freshEntries = page.filter { seenEntryIDs.insert($0.id).inserted }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshEntries.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            let groupedEntries = Dictionary(grouping: freshEntries, by: \.playlistID)

            for (playlistID, records) in groupedEntries {
                guard let playlist = localPlaylistBySyncedID[playlistID],
                      playlist.isSmartPlaylist == false else {
                    continue
                }

                var entriesByIdentity: [String: PlaylistEntry] = [:]
                for entry in playlist.ordered {
                    guard let episode = entry.episode else {
                        legacyContext.delete(entry)
                        continue
                    }
                    let identity = stableIdentityKey(
                        feedURL: episode.stableEpisodeIdentity.feedURL,
                        episodeID: episode.stableEpisodeIdentity.episodeID
                    )
                    if entriesByIdentity[identity] == nil {
                        entriesByIdentity[identity] = entry
                    } else {
                        legacyContext.delete(entry)
                        result.playlistEntriesApplied += 1
                    }
                }

                for record in records {
                    let identityKey = stableIdentityKey(
                        feedURL: record.feedURL,
                        episodeID: record.episodeID
                    )
                    if record.isDeleted || record.deletedAt != nil {
                        if let existing = entriesByIdentity.removeValue(forKey: identityKey) {
                            legacyContext.delete(existing)
                            result.playlistEntriesApplied += 1
                        }
                        continue
                    }
                    activeRemoteIdentitiesByPlaylistID[playlistID, default: []]
                        .insert(identityKey)
                    guard let episode = episodesByIdentity[identityKey] else {
                        appendMissingFeed(record.feedURL, to: &result)
                        continue
                    }
                    let entry: PlaylistEntry
                    if let existing = entriesByIdentity[identityKey] {
                        entry = existing
                    } else {
                        let newEntry = PlaylistEntry(
                            episode: episode,
                            order: record.sortIndex
                        )
                        legacyContext.insert(newEntry)
                        newEntry.playlist = playlist
                        entriesByIdentity[identityKey] = newEntry
                        entry = newEntry
                    }
                    entry.episode = episode
                    entry.playlist = playlist
                    entry.order = record.sortIndex
                    entry.dateAdded = record.addedAt
                    result.playlistEntriesApplied += 1
                }
            }

            saveLegacyChanges(
                phase: "playlist_entries_batch_\(entryOffset)",
                result: &result
            )
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            entryOffset += page.count
        }

        if authoritative {
            for (playlistID, activeRemoteIdentities) in activeRemoteIdentitiesByPlaylistID {
                guard let playlist = localPlaylistBySyncedID[playlistID] else { continue }
                for entry in playlist.ordered {
                    guard let episode = entry.episode else {
                        legacyContext.delete(entry)
                        continue
                    }
                    let identity = stableIdentityKey(
                        feedURL: episode.stableEpisodeIdentity.feedURL,
                        episodeID: episode.stableEpisodeIdentity.episodeID
                    )
                    if activeRemoteIdentities.contains(identity) == false {
                        legacyContext.delete(entry)
                        result.playlistEntriesApplied += 1
                    }
                }
            }
        }
    }

    private func matchingLocalPlaylist(
        for record: PlaylistSync,
        among playlists: [Playlist]
    ) -> Playlist? {
        if record.title == Playlist.defaultQueueTitle {
            return playlists.first { $0.title == Playlist.defaultQueueTitle }
        }
        return playlists.first {
            $0.title.localizedCaseInsensitiveCompare(record.title) == .orderedSame
                && $0.kindRawValue == record.kindRawValue
        }
    }

    private func applyBookmarks(
        result: inout StoreSplitUserStateImportResult
    ) async {
        let existingBookmarks = (try? legacyContext.fetch(FetchDescriptor<Bookmark>())) ?? []
        var bookmarksByID = existingBookmarks.reduce(into: [String: Bookmark]()) {
            guard let uuid = $1.uuid else { return }
            $0[uuid.uuidString] = $1
        }
        var seenBookmarkIDs = Set<String>()
        var offset = 0

        while true {
            let page = fetchPage(
                BookmarkSync.self,
                offset: offset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\BookmarkSync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            let freshRecords = page.filter { seenBookmarkIDs.insert($0.id).inserted }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshRecords.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )

            for record in freshRecords {
                let bookmarkUUID = UUID(uuidString: record.id) ?? stableUUID(record.id)
                if record.isDeleted || record.deletedAt != nil {
                    if let bookmark = bookmarksByID.removeValue(forKey: record.id)
                        ?? bookmarksByID.removeValue(forKey: bookmarkUUID.uuidString) {
                        legacyContext.delete(bookmark)
                        result.bookmarksApplied += 1
                    }
                    continue
                }
                let identityKey = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                guard let episode = episodesByIdentity[identityKey] else {
                    appendMissingFeed(record.feedURL, to: &result)
                    continue
                }
                let bookmark = bookmarksByID[record.id]
                    ?? bookmarksByID[bookmarkUUID.uuidString]
                    ?? {
                        let bookmark = Bookmark(
                            start: record.time,
                            title: record.title ?? episode.title,
                            type: .bookmark
                        )
                        bookmark.uuid = bookmarkUUID
                        legacyContext.insert(bookmark)
                        bookmarksByID[record.id] = bookmark
                        bookmarksByID[bookmarkUUID.uuidString] = bookmark
                        return bookmark
                    }()
                setIfChanged(bookmark, \.start, record.time)
                setIfChanged(bookmark, \.title, record.title ?? episode.title)
                setIfChanged(bookmark, \.creationtime, record.createdAt)
                if bookmark.bookmarkEpisode?.persistentModelID
                    != episode.persistentModelID {
                    bookmark.bookmarkEpisode = episode
                }
                if episode.bookmarks?.contains(where: { $0 === bookmark }) == false {
                    episode.bookmarks?.append(bookmark)
                }
                result.bookmarksApplied += 1
            }

            saveLegacyChanges(
                phase: "bookmarks_batch_\(offset)",
                result: &result
            )
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            offset += page.count
        }
    }

    private func applyListeningHistory(
        result: inout StoreSplitUserStateImportResult
    ) async {
        var activeProjectedSessionIDs = Set<String>()
        var seenHistoryKeys = Set<String>()
        var offset = 0

        while true {
            let page = fetchPage(
                ListeningHistorySync.self,
                offset: offset,
                limit: historyPageSize,
                sortBy: [
                    SortDescriptor(\ListeningHistorySync.updatedAt, order: .reverse),
                    SortDescriptor(\ListeningHistorySync.endedAt, order: .reverse),
                    SortDescriptor(\ListeningHistorySync.listenedSeconds, order: .reverse),
                    SortDescriptor(\ListeningHistorySync.sourceDeviceID, order: .forward)
                ]
            )
            guard page.isEmpty == false else { break }

            let freshRecords = page.filter {
                seenHistoryKeys.insert(
                    ListeningHistoryIdentity.canonicalAggregationKey(for: $0)
                ).inserted
            }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshRecords.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            let deterministicIDs = freshRecords.map {
                stableUUID(ListeningHistoryIdentity.canonicalAggregationKey(for: $0))
            }
            var sessionsByUUID = fetchPlaySessions(ids: deterministicIDs)
                .reduce(into: [UUID: PlaySession]()) { result, session in
                    guard let id = session.id else { return }
                    result[id] = session
                }

            for record in freshRecords {
                let identity = ListeningHistoryIdentity.canonicalAggregationKey(for: record)
                let deterministicID = stableUUID(identity)
                activeProjectedSessionIDs.insert(deterministicID.uuidString)
                let episodeIdentity = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                let episode = episodesByIdentity[episodeIdentity]
                if episode == nil {
                    appendMissingFeed(record.feedURL, to: &result)
                }

                let session = sessionsByUUID[deterministicID] ?? {
                    let session = PlaySession(id: deterministicID)
                    legacyContext.insert(session)
                    sessionsByUUID[deterministicID] = session
                    return session
                }()
                setIfChanged(session, \.id, deterministicID)
                if session.episode?.persistentModelID != episode?.persistentModelID {
                    session.episode = episode
                }
                setIfChanged(
                    session,
                    \.podcastName,
                    record.podcastName ?? episode?.displayPodcastTitle
                )
                setIfChanged(session, \.sourceDeviceID, record.sourceDeviceID)
                setIfChanged(session, \.sourceDeviceName, record.sourceDeviceName)
                setIfChanged(session, \.deviceModel, record.deviceModel)
                setIfChanged(
                    session,
                    \.appVersion,
                    ListeningDeviceIdentity.splitStoreProjectionAppVersion
                )
                setIfChanged(session, \.startTime, record.startedAt)
                setIfChanged(session, \.endTime, record.endedAt)
                setIfChanged(session, \.startPosition, record.startPosition)
                setIfChanged(session, \.endPosition, record.endPosition)
                setIfChanged(
                    session,
                    \.silenceGapTimeSavedSeconds,
                    record.silenceGapTimeSavedSeconds
                )
                setIfChanged(session, \.endedCleanly, record.endedCleanly)
                result.listeningHistoryApplied += 1
            }

            saveLegacyChanges(
                phase: "listening_history_batch_\(offset)",
                result: &result
            )
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            offset += page.count
        }

        pruneStaleProjectedSessions(
            activeProjectedSessionIDs: activeProjectedSessionIDs,
            result: &result
        )
    }

    private func clearProjectedListeningHistory(
        result: inout StoreSplitUserStateImportResult
    ) {
        let projectionMarker: String? =
            ListeningDeviceIdentity.splitStoreProjectionAppVersion

        while true {
            if Task.isCancelled { break }
            var descriptor = FetchDescriptor<PlaySession>(
                predicate: #Predicate<PlaySession> { session in
                    session.appVersion == projectionMarker
                },
                sortBy: [SortDescriptor(\PlaySession.startTime, order: .reverse)]
            )
            descriptor.fetchLimit = historyPageSize
            let page = (try? legacyContext.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }

            for session in page {
                legacyContext.delete(session)
            }

            saveLegacyChanges(
                phase: "clear_projected_listening_history",
                result: &result
            )
            refreshContexts()
        }
    }

    private func saveLegacyChanges(
        phase: String,
        result: inout StoreSplitUserStateImportResult
    ) {
        guard legacyContext.hasChanges else { return }
        do {
            try legacyContext.save()
        } catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_save_failed",
                details: "\(phase):\(error.localizedDescription)"
            )
#if DEBUG
            NSLog(
                "[StoreSplitProjection] save failed phase=%@ error=%@",
                phase,
                error.localizedDescription
            )
#endif
            legacyContext.rollback()
        }
    }

#if DEBUG
    private func logProjectionAudit(
        result: StoreSplitUserStateImportResult
    ) {
        func count<Model: PersistentModel>(
            _ type: Model.Type,
            in context: ModelContext
        ) -> Int {
            (try? context.fetchCount(FetchDescriptor<Model>())) ?? -1
        }

        NSLog(
            """
            [StoreSplitProjection] source subscriptions=%d states=%d playlists=%d entries=%d bookmarks=%d history=%d \
            local podcasts=%d episodes=%d playlists=%d entries=%d bookmarks=%d history=%d \
            applied subscriptions=%d states=%d playlists=%d entries=%d bookmarks=%d history=%d missingFeeds=%d failed=%d
            """,
            count(SubscriptionSync.self, in: userStateContext),
            count(EpisodeStateSync.self, in: userStateContext),
            count(PlaylistSync.self, in: userStateContext),
            count(PlaylistEntrySync.self, in: userStateContext),
            count(BookmarkSync.self, in: userStateContext),
            count(ListeningHistorySync.self, in: userStateContext),
            count(Podcast.self, in: legacyContext),
            count(Episode.self, in: legacyContext),
            count(Playlist.self, in: legacyContext),
            count(PlaylistEntry.self, in: legacyContext),
            count(Bookmark.self, in: legacyContext),
            count(PlaySession.self, in: legacyContext),
            result.subscriptionsApplied,
            result.episodeStatesApplied,
            result.playlistsApplied,
            result.playlistEntriesApplied,
            result.bookmarksApplied,
            result.listeningHistoryApplied,
            result.feedsToBootstrap.count,
            result.failed
        )
    }
#endif

    private func stableIdentityKey(
        feedURL: String,
        episodeID: String
    ) -> String {
        let normalizedFeedURL = URL(string: feedURL).map(
            {
                $0.podcastFeedComparisonKeys.sorted().first
                    ?? PodcastFeedIdentity.normalizedFeedURLString($0)
            }
        ) ?? feedURL
        return StableIdentityKey.make(normalizedFeedURL, episodeID)
    }

    private func appendMissingFeed(
        _ feedURL: String,
        to result: inout StoreSplitUserStateImportResult
    ) {
        guard let feed = URL(string: feedURL) else { return }
        result.feedsToBootstrap.append(feed)
    }

    private func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func setIfChanged<Root: AnyObject, Value: Equatable>(
        _ object: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) {
        guard object[keyPath: keyPath] != value else { return }
        object[keyPath: keyPath] = value
    }

    private func deduplicatedSubscriptions(
        _ records: [SubscriptionSync]
    ) -> [String: SubscriptionSync] {
        var result: [String: SubscriptionSync] = [:]
        for record in records {
            guard let url = URL(string: record.feedURL) else { continue }
            let comparisonKey = url.podcastFeedComparisonKeys.sorted().first
                ?? PodcastFeedIdentity.normalizedFeedURLString(url)
            if let existing = result[comparisonKey],
               existing.updatedAt >= record.updatedAt {
                continue
            }
            result[comparisonKey] = record
        }
        return result
    }

    private func preferredPodcast(_ lhs: Podcast, _ rhs: Podcast) -> Podcast {
        let lhsSubscribed = lhs.metaData?.isSubscribed != false
        let rhsSubscribed = rhs.metaData?.isSubscribed != false
        if lhsSubscribed != rhsSubscribed {
            return lhsSubscribed ? lhs : rhs
        }
        return (lhs.metaData?.lastRefresh ?? .distantPast)
            >= (rhs.metaData?.lastRefresh ?? .distantPast) ? lhs : rhs
    }

    private func hideDuplicatePodcasts(_ podcasts: [Podcast]) -> Int {
        var groups: [[Podcast]] = []
        for podcast in podcasts {
            guard let feed = podcast.feed else { continue }
            if let index = groups.firstIndex(where: { group in
                group.contains { existing in
                    guard let existingFeed = existing.feed else { return false }
                    return existingFeed.podcastFeedComparisonKeys
                        .isDisjoint(with: feed.podcastFeedComparisonKeys) == false
                }
            }) {
                groups[index].append(podcast)
            } else {
                groups.append([podcast])
            }
        }

        var hidden = 0
        for group in groups where group.count > 1 {
            let survivor = group.dropFirst().reduce(group[0], preferredPodcast)
            for duplicate in group where duplicate !== survivor {
                let metadata = ensureMetadata(for: duplicate)
                if metadata.isSubscribed != false {
                    metadata.isSubscribed = false
                    hidden += 1
                }
            }
        }
        return hidden
    }

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metadata = podcast.metaData {
            return metadata
        }
        let metadata = PodcastMetaData()
        legacyContext.insert(metadata)
        podcast.metaData = metadata
        return metadata
    }

    private func ensureMetadata(for episode: Episode) -> EpisodeMetaData {
        if let metadata = episode.metaData {
            return metadata
        }
        let metadata = EpisodeMetaData()
        legacyContext.insert(metadata)
        metadata.episode = episode
        episode.metaData = metadata
        return metadata
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private func shouldPauseForPlayback() async -> Bool {
        await MainActor.run {
            Player.shared.isPlaying
        }
    }

    /// Whether the importer should stop at the next checkpoint: the task was
    /// cancelled (e.g. the app is backgrounding) or playback started. Stopping
    /// promptly releases the shared-container SQLite lock before suspension.
    private func shouldStop() async -> Bool {
        if Task.isCancelled { return true }
        return await shouldPauseForPlayback()
    }

    /// Cooperatively pauses heavy import work while the device is under thermal
    /// or memory pressure, or while the user is actively interacting. Keeps the
    /// importer from competing with the UI for the main thread. Returns promptly
    /// when the task is cancelled.
    private func awaitIdleWindow() async {
        await SystemPressureGate.shared.waitUntilIdle()
    }

    private func shouldProjectEpisodeState(
        _ state: EpisodeStateSync,
        recencyCutoff: Date?
    ) -> Bool {
        let hasActiveProgress = state.playPosition > 0 || state.maxPlayPosition > 0
        if hasActiveProgress {
            return true
        }

        guard let recencyCutoff else {
            return true
        }

        let mostRelevantDate = [
            state.lastPlayedAt,
            state.completedAt,
            state.archivedAt,
            state.firstPlayedAt
        ]
            .compactMap { $0 }
            .max()

        guard let mostRelevantDate else {
            return false
        }

        return mostRelevantDate >= recencyCutoff
    }

    private func refreshContexts() {
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
    }

    private func resolveEpisodesByIdentity(
        identityKeys: [String]
    ) async -> [String: Episode] {
        let uniqueKeys = Set(identityKeys)
        await resolveEpisodeIDsIfNeeded(for: uniqueKeys)

        var episodesByIdentity: [String: Episode] = [:]
        for identityKey in uniqueKeys {
            guard let episodeID = resolvedEpisodeIDsByIdentity[identityKey] ?? nil,
                  let episode = legacyContext.model(for: episodeID) as? Episode else {
                continue
            }
            episodesByIdentity[identityKey] = episode
        }
        return episodesByIdentity
    }

    private func resolveEpisodeIDsIfNeeded(for identityKeys: Set<String>) async {
        let unresolvedKeys = identityKeys.filter { resolvedEpisodeIDsByIdentity[$0] == nil }
        guard unresolvedKeys.isEmpty == false else { return }

        var guidCandidates: [String] = []
        var enclosureCandidates: [URL] = []
        var linkCandidates: [URL] = []
        var unresolvedByFeed: [String: Set<String>] = [:]

        for identityKey in unresolvedKeys {
            guard let components = decodeStableIdentityKey(identityKey) else {
                resolvedEpisodeIDsByIdentity[identityKey] = nil
                continue
            }

            unresolvedByFeed[components.feedURL, default: []].insert(identityKey)

            if components.episodeID.hasPrefix("guid:") {
                guidCandidates.append(String(components.episodeID.dropFirst(5)))
            } else if components.episodeID.hasPrefix("enclosure:") || components.episodeID.hasPrefix("episode:") {
                let prefixLength = components.episodeID.hasPrefix("enclosure:") ? 10 : 8
                if let url = URL(string: String(components.episodeID.dropFirst(prefixLength))) {
                    enclosureCandidates.append(url)
                }
            } else if components.episodeID.hasPrefix("link:") {
                if let url = URL(string: String(components.episodeID.dropFirst(5))) {
                    linkCandidates.append(url)
                }
            }
        }

        cacheResolvedEpisodes(
            fetchEpisodesMatchingGUIDs(Array(Set(guidCandidates))),
            expectedKeys: unresolvedKeys
        )
        cacheResolvedEpisodes(
            fetchEpisodesMatchingURLs(Array(Set(enclosureCandidates))),
            expectedKeys: unresolvedKeys
        )
        cacheResolvedEpisodes(
            fetchEpisodesMatchingLinks(Array(Set(linkCandidates))),
            expectedKeys: unresolvedKeys
        )

        let stillUnresolved = unresolvedKeys.filter { resolvedEpisodeIDsByIdentity[$0] == nil }
        guard stillUnresolved.isEmpty == false else { return }

        let unresolvedFeeds = Set(stillUnresolved.compactMap { decodeStableIdentityKey($0)?.feedURL })
        for feedURL in unresolvedFeeds {
            if Task.isCancelled { return }
            await awaitIdleWindow()
            await resolveEpisodesByScanningFeed(feedURL, expectedKeys: Set(stillUnresolved))
        }

        for identityKey in stillUnresolved where resolvedEpisodeIDsByIdentity[identityKey] == nil {
            resolvedEpisodeIDsByIdentity[identityKey] = nil
        }
    }

    private func fetchEpisodesMatchingGUIDs(_ guids: [String]) -> [Episode] {
        guard guids.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.guid != nil && guids.contains(episode.guid!)
            }
        )
        return (try? legacyContext.fetch(descriptor)) ?? []
    }

    private func fetchEpisodesMatchingURLs(_ urls: [URL]) -> [Episode] {
        guard urls.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.url != nil && urls.contains(episode.url!)
            }
        )
        return (try? legacyContext.fetch(descriptor)) ?? []
    }

    private func fetchEpisodesMatchingLinks(_ urls: [URL]) -> [Episode] {
        guard urls.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.link != nil && urls.contains(episode.link!)
            }
        )
        return (try? legacyContext.fetch(descriptor)) ?? []
    }

    private func cacheResolvedEpisodes(
        _ episodes: [Episode],
        expectedKeys: Set<String>
    ) {
        for episode in episodes {
            let identity = episode.stableEpisodeIdentity
            let key = stableIdentityKey(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID
            )
            guard expectedKeys.contains(key) else { continue }
            resolvedEpisodeIDsByIdentity[key] = episode.persistentModelID
        }
    }

    private func resolveEpisodesByScanningFeed(
        _ normalizedFeedURL: String,
        expectedKeys: Set<String>
    ) async {
        guard let podcastID = podcastsByComparisonKey[normalizedFeedURL],
              let podcast = legacyContext.model(for: podcastID) as? Podcast,
              let feed = podcast.feed else {
            return
        }

        // Last-resort fallback after the targeted GUID/URL/link fetches missed.
        //
        // We deliberately do NOT walk `podcast.episodes`: the relationship getter
        // faults every episode of the feed and pins them on the live `Podcast`
        // object for the importer's lifetime, which materialises (and strongly
        // retains) the entire episode library. Instead we page episodes for the
        // feed with a fetch so each batch is released before the next one loads,
        // and stop as soon as every expected key is resolved or the app backgrounds.
        var remaining = expectedKeys
        var offset = 0
        while remaining.isEmpty == false {
            if Task.isCancelled { return }
            await awaitIdleWindow()
            let reachedEnd = autoreleasepool { () -> Bool in
                var descriptor = FetchDescriptor<Episode>(
                    predicate: #Predicate<Episode> { $0.podcast?.feed == feed }
                )
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = episodeScanPageSize
                guard let batch = try? legacyContext.fetch(descriptor),
                      batch.isEmpty == false else {
                    return true
                }

                for episode in batch {
                    let identity = episode.stableEpisodeIdentity
                    let key = stableIdentityKey(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID
                    )
                    if remaining.remove(key) != nil {
                        resolvedEpisodeIDsByIdentity[key] = episode.persistentModelID
                    }
                    if remaining.isEmpty { break }
                }

                offset += batch.count
                return batch.count < episodeScanPageSize
            }
            if reachedEnd { return }
        }
    }

    private func decodeStableIdentityKey(
        _ value: String
    ) -> (feedURL: String, episodeID: String)? {
        var cursor = value.startIndex
        var components: [String] = []

        while cursor < value.endIndex, components.count < 2 {
            guard let separator = value[cursor...].firstIndex(of: ":"),
                  let length = Int(value[cursor..<separator]) else {
                return nil
            }
            let componentStart = value.index(after: separator)
            guard let componentEnd = value.index(
                componentStart,
                offsetBy: length,
                limitedBy: value.endIndex
            ) else {
                return nil
            }
            components.append(String(value[componentStart..<componentEnd]))
            cursor = componentEnd
        }

        guard components.count == 2 else { return nil }
        return (components[0], components[1])
    }

    private func fetchPlaySessions(ids: [UUID]) -> [PlaySession] {
        guard ids.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<PlaySession>(
            predicate: #Predicate<PlaySession> { session in
                session.id != nil && ids.contains(session.id!)
            }
        )
        return (try? legacyContext.fetch(descriptor)) ?? []
    }

    private func pruneStaleProjectedSessions(
        activeProjectedSessionIDs: Set<String>,
        result: inout StoreSplitUserStateImportResult
    ) {
        var offset = 0
        var staleIDs: [UUID] = []
        let projectionMarker: String? =
            ListeningDeviceIdentity.splitStoreProjectionAppVersion

        while true {
            if Task.isCancelled { break }
            var descriptor = FetchDescriptor<PlaySession>(
                predicate: #Predicate<PlaySession> { session in
                    session.appVersion == projectionMarker
                },
                sortBy: [SortDescriptor(\PlaySession.startTime, order: .reverse)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = historyPageSize
            let page = (try? legacyContext.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }

            for session in page {
                guard let id = session.id,
                      activeProjectedSessionIDs.contains(id.uuidString) == false else {
                    continue
                }
                staleIDs.append(id)
            }

            offset += page.count
            if page.count < historyPageSize {
                break
            }
        }

        for chunkStart in stride(from: 0, to: staleIDs.count, by: historyPageSize) {
            let chunk = Array(
                staleIDs[chunkStart ..< min(chunkStart + historyPageSize, staleIDs.count)]
            )
            for session in fetchPlaySessions(ids: chunk) {
                legacyContext.delete(session)
            }
            saveLegacyChanges(
                phase: "stale_projected_sessions_\(chunkStart)",
                result: &result
            )
        }
    }

    private func fetchPage<Model: PersistentModel>(
        _ type: Model.Type,
        offset: Int,
        limit: Int,
        sortBy: [SortDescriptor<Model>] = []
    ) -> [Model] {
        var descriptor = FetchDescriptor<Model>(sortBy: sortBy)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return (try? context(for: type).fetch(descriptor)) ?? []
    }

    private func context<Model: PersistentModel>(
        for type: Model.Type
    ) -> ModelContext {
        switch type {
        case is Podcast.Type,
            is Episode.Type,
            is Playlist.Type,
            is PlaylistEntry.Type,
            is Bookmark.Type,
            is PlaySession.Type:
            return legacyContext
        default:
            return userStateContext
        }
    }
}
