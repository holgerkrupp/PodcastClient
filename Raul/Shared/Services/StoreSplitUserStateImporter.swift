import Foundation
import SwiftData

struct StoreSplitUserStateImportResult: Sendable {
    var subscriptionsApplied = 0
    var episodeStatesApplied = 0
    var playlistsApplied = 0
    var playlistEntriesApplied = 0
    var bookmarksApplied = 0
    var duplicatePodcastsHidden = 0
    var feedsToBootstrap: [URL] = []
    var failed = 0
}

actor StoreSplitUserStateImporter {
    private let legacyContext: ModelContext
    private let userStateContext: ModelContext

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
    }

    nonisolated static func apply(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        authoritativePlaylists: Bool = false
    ) async -> StoreSplitUserStateImportResult {
        await Task.detached(priority: .utility) {
            let importer = StoreSplitUserStateImporter(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer
            )
            return await importer.run(
                authoritativePlaylists: authoritativePlaylists
            )
        }.value
    }

    private func run(
        authoritativePlaylists: Bool
    ) -> StoreSplitUserStateImportResult {
        var result = StoreSplitUserStateImportResult()
        let podcasts = (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? []
        var podcastsByComparisonKey = podcasts.reduce(into: [String: Podcast]()) { values, podcast in
            guard let feed = podcast.feed else { return }
            for key in feed.podcastFeedComparisonKeys {
                if let existing = values[key] {
                    values[key] = preferredPodcast(existing, podcast)
                } else {
                    values[key] = podcast
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
            }.first ?? {
                guard subscription.isSubscribed else { return nil }
                let podcast = Podcast(feed: feedURL)
                legacyContext.insert(podcast)
                for key in feedURL.podcastFeedComparisonKeys {
                    podcastsByComparisonKey[key] = podcast
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
                if podcast.episodes?.isEmpty != false {
                    result.feedsToBootstrap.append(feedURL)
                }
            }
            result.subscriptionsApplied += 1
        }
        result.duplicatePodcastsHidden = hideDuplicatePodcasts(podcasts)

        let episodes = (try? legacyContext.fetch(FetchDescriptor<Episode>())) ?? []
        let episodesByIdentity = episodes.reduce(into: [String: Episode]()) {
            $0[$1.stableEpisodeIdentityKey] = $1
        }
        let episodeStates = newestRecords(
            (try? userStateContext.fetch(FetchDescriptor<EpisodeStateSync>())) ?? [],
            id: \.id,
            updatedAt: \.updatedAt
        )
        for state in episodeStates.values {
            guard let episode = episodesByIdentity[state.id] else { continue }
            let metadata = ensureMetadata(for: episode)
            metadata.playPosition = max(0, state.playPosition)
            metadata.maxPlayposition = max(
                0,
                state.maxPlayPosition,
                state.playPosition
            )
            metadata.lastPlayed = state.lastPlayedAt
            metadata.firstListenDate = state.firstPlayedAt
            metadata.completionDate = state.completedAt
            metadata.archivedAt = state.archivedAt
            metadata.wasSkipped = state.wasSkipped
            metadata.isArchived = state.isArchived
            metadata.isHistory = state.isPlayed

            if state.isArchived {
                metadata.status = .archived
                metadata.isInbox = false
            } else if state.isPlayed {
                metadata.status = .history
                metadata.isInbox = false
            } else if metadata.status == .archived || metadata.status == .history {
                metadata.status = .inbox
                metadata.isInbox = true
            }
            result.episodeStatesApplied += 1
        }
        applyPlaylists(
            episodesByIdentity: episodesByIdentity,
            authoritative: authoritativePlaylists,
            result: &result
        )
        applyBookmarks(
            episodesByIdentity: episodesByIdentity,
            result: &result
        )

        do {
            if legacyContext.hasChanges {
                try legacyContext.save()
            }
        } catch {
            result.failed += 1
        }

        result.feedsToBootstrap = Array(Set(result.feedsToBootstrap)).sorted {
            $0.absoluteString < $1.absoluteString
        }
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_completed",
            details: "subscriptions=\(result.subscriptionsApplied),episodes=\(result.episodeStatesApplied),playlists=\(result.playlistsApplied),entries=\(result.playlistEntriesApplied),bookmarks=\(result.bookmarksApplied),duplicates=\(result.duplicatePodcastsHidden),feeds=\(result.feedsToBootstrap.count),failed=\(result.failed)"
        )
        return result
    }

    private func applyPlaylists(
        episodesByIdentity: [String: Episode],
        authoritative: Bool,
        result: inout StoreSplitUserStateImportResult
    ) {
        let syncedPlaylists = newestLogicalPlaylists(
            (try? userStateContext.fetch(FetchDescriptor<PlaylistSync>())) ?? []
        )
        let syncedEntries = newestRecords(
            (try? userStateContext.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [],
            id: \.id,
            updatedAt: \.updatedAt
        )
        var localPlaylists = ((try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? [])
            .reduce(into: [String: Playlist]()) { $0[$1.id.uuidString] = $1 }
        var localPlaylistBySyncedID: [String: Playlist] = [:]

        for record in syncedPlaylists.values {
            guard let playlistID = UUID(uuidString: record.id) else {
                result.failed += 1
                continue
            }
            let playlist = localPlaylists[record.id]
                ?? matchingLocalPlaylist(for: record, among: Array(localPlaylists.values))
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
                .flatMap { try? JSONDecoder().decode(SmartPlaylistFilter.self, from: $0) }
            result.playlistsApplied += 1
        }

        for record in syncedPlaylists.values where record.isDeleted == false
            && record.deletedAt == nil {
            guard let playlist = localPlaylistBySyncedID[record.id],
                  playlist.isSmartPlaylist == false else {
                continue
            }
            let records = syncedEntries.values.filter { $0.playlistID == record.id }
            if records.isEmpty && authoritative == false {
                continue
            }

            var entriesByIdentity = (playlist.items ?? []).reduce(
                into: [String: PlaylistEntry]()
            ) { entries, entry in
                guard let episode = entry.episode else { return }
                entries[episode.stableEpisodeIdentityKey] = entry
            }

            for record in records {
                let identityKey = StableIdentityKey.make(record.feedURL, record.episodeID)
                if record.isDeleted || record.deletedAt != nil {
                    if let existing = entriesByIdentity.removeValue(forKey: identityKey) {
                        legacyContext.delete(existing)
                        result.playlistEntriesApplied += 1
                    }
                    continue
                }
                guard let episode = episodesByIdentity[identityKey] else {
                    if let feed = URL(string: record.feedURL) {
                        result.feedsToBootstrap.append(feed)
                    }
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

            if authoritative {
                let activeRemoteIdentities = Set(records.compactMap { record -> String? in
                    guard record.isDeleted == false, record.deletedAt == nil else {
                        return nil
                    }
                    return StableIdentityKey.make(record.feedURL, record.episodeID)
                })
                for (identity, entry) in entriesByIdentity
                    where activeRemoteIdentities.contains(identity) == false {
                    legacyContext.delete(entry)
                    result.playlistEntriesApplied += 1
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

    private func newestLogicalPlaylists(
        _ records: [PlaylistSync]
    ) -> [String: PlaylistSync] {
        var newestByLogicalKey: [String: PlaylistSync] = [:]
        for record in records {
            let key = StableIdentityKey.make(
                record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                record.kindRawValue
            )
            if let existing = newestByLogicalKey[key],
               existing.updatedAt >= record.updatedAt {
                continue
            }
            newestByLogicalKey[key] = record
        }
        return newestByLogicalKey
    }

    private func applyBookmarks(
        episodesByIdentity: [String: Episode],
        result: inout StoreSplitUserStateImportResult
    ) {
        let records = newestRecords(
            (try? userStateContext.fetch(FetchDescriptor<BookmarkSync>())) ?? [],
            id: \.id,
            updatedAt: \.updatedAt
        )
        let existingBookmarks = (try? legacyContext.fetch(FetchDescriptor<Bookmark>())) ?? []
        var bookmarksByID = existingBookmarks.reduce(into: [String: Bookmark]()) {
            guard let uuid = $1.uuid else { return }
            $0[uuid.uuidString] = $1
        }

        for record in records.values {
            if record.isDeleted || record.deletedAt != nil {
                if let bookmark = bookmarksByID.removeValue(forKey: record.id) {
                    legacyContext.delete(bookmark)
                    result.bookmarksApplied += 1
                }
                continue
            }
            let identityKey = StableIdentityKey.make(record.feedURL, record.episodeID)
            guard let episode = episodesByIdentity[identityKey] else { continue }
            let bookmark = bookmarksByID[record.id] ?? {
                let bookmark = Bookmark(
                    start: record.time,
                    title: record.title ?? episode.title,
                    type: .bookmark
                )
                bookmark.uuid = UUID(uuidString: record.id) ?? UUID()
                legacyContext.insert(bookmark)
                bookmarksByID[record.id] = bookmark
                return bookmark
            }()
            bookmark.start = record.time
            bookmark.title = record.title ?? episode.title
            bookmark.creationtime = record.createdAt
            bookmark.bookmarkEpisode = episode
            if episode.bookmarks?.contains(where: { $0 === bookmark }) == false {
                episode.bookmarks?.append(bookmark)
            }
            result.bookmarksApplied += 1
        }
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

    private func newestRecords<Record>(
        _ records: [Record],
        id: KeyPath<Record, String>,
        updatedAt: KeyPath<Record, Date>
    ) -> [String: Record] {
        records.reduce(into: [String: Record]()) { result, record in
            let recordID = record[keyPath: id]
            guard let existing = result[recordID],
                  existing[keyPath: updatedAt] >= record[keyPath: updatedAt] else {
                result[recordID] = record
                return
            }
        }
    }
}
