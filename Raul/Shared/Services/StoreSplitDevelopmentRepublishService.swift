#if DEBUG
import Foundation
import SwiftData

struct StoreSplitDevelopmentRepublishResult: Sendable {
    var subscriptions = 0
    var episodeStates = 0
    var playlists = 0
    var bookmarks = 0
    var listeningSessions = 0
    var storedCounts = StoreSplitDevelopmentStoreCounts()
}

enum StoreSplitDevelopmentRepublishScope: Sendable {
    case subscriptions
    case episodeStates
    case playlists
    case bookmarks
    case listeningHistory
}

struct StoreSplitDevelopmentStoreCounts: Sendable {
    var subscriptions = 0
    var episodeStates = 0
    var playlists = 0
    var playlistEntries = 0
    var queueEntries = 0
    var bookmarks = 0
    var listeningSessions = 0

    var summary: String {
        "subscriptions \(subscriptions), states \(episodeStates), playlists \(playlists), entries \(playlistEntries), queue \(queueEntries), bookmarks \(bookmarks), history \(listeningSessions)"
    }

    static func read(from container: ModelContainer) -> Self {
        let context = ModelContext(container)
        return Self(
            subscriptions: count(SubscriptionSync.self, in: context),
            episodeStates: count(EpisodeStateSync.self, in: context),
            playlists: count(PlaylistSync.self, in: context),
            playlistEntries: count(PlaylistEntrySync.self, in: context),
            queueEntries: count(QueueEntrySync.self, in: context),
            bookmarks: count(BookmarkSync.self, in: context),
            listeningSessions: count(ListeningHistorySync.self, in: context)
        )
    }

    private static func count<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext
    ) -> Int {
        (try? context.fetchCount(FetchDescriptor<Model>())) ?? 0
    }
}

actor StoreSplitDevelopmentRepublishService {
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let episodePageSize = 100
    private let historyPageSize = 25

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
    }

    nonisolated static func republish(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        scope: StoreSplitDevelopmentRepublishScope
    ) async -> StoreSplitDevelopmentRepublishResult {
        let service = StoreSplitDevelopmentRepublishService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        return await service.run(scope: scope)
    }

    private func run(
        scope: StoreSplitDevelopmentRepublishScope
    ) async -> StoreSplitDevelopmentRepublishResult {
        var result = StoreSplitDevelopmentRepublishResult()
        let now = Date()
        switch scope {
        case .subscriptions:
            await republishSubscriptions(now: now, result: &result)
        case .episodeStates:
            await republishEpisodeStates(now: now, result: &result)
        case .playlists:
            await republishPlaylists(now: now, result: &result)
        case .bookmarks:
            await republishBookmarks(now: now, result: &result)
        case .listeningHistory:
            await republishListeningHistory(result: &result)
        }
        result.storedCounts = StoreSplitDevelopmentStoreCounts.read(
            from: userStateContainer
        )
        return result
    }

    private func republishSubscriptions(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let subscriptionWriter = StoreSplitSubscriptionSyncWriter(
            modelContainer: userStateContainer
        )
        let context = ModelContext(legacyContainer)
        for podcast in (try? context.fetch(FetchDescriptor<Podcast>())) ?? [] {
            guard let feed = podcast.feed else { continue }
            await subscriptionWriter.setSubscribed(
                feedURL: feed,
                isSubscribed: podcast.metaData?.isSubscribed != false,
                at: now
            )
            result.subscriptions += 1
        }
    }

    private func republishEpisodeStates(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        var episodeOffset = 0
        while true {
            let page = episodeStateSnapshots(
                offset: episodeOffset,
                limit: episodePageSize
            )
            guard page.fetchedCount > 0 else { break }
            if page.snapshots.isEmpty == false {
                await StoreSplitEpisodeStateSyncWriter(
                    modelContainer: userStateContainer
                ).upsert(page.snapshots, at: now)
                result.episodeStates += page.snapshots.count
            }
            episodeOffset += page.fetchedCount
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func republishPlaylists(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let context = ModelContext(legacyContainer)
        let playlistWriter = StoreSplitPlaylistSyncWriter(
            modelContainer: userStateContainer
        )
        for playlist in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] {
            removeDuplicateEntries(from: playlist, in: context)
            await playlistWriter.upsert(
                playlist.storeSplitSnapshot,
                at: now,
                authoritative: true
            )
            result.playlists += 1
        }
        context.saveIfNeeded()
    }

    private func republishBookmarks(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let context = ModelContext(legacyContainer)
        let bookmarkWriter = StoreSplitBookmarkSyncWriter(
            modelContainer: userStateContainer
        )
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] {
            guard let episode = bookmark.bookmarkEpisode,
                  let bookmarkID = bookmark.uuid?.uuidString else { continue }
            await bookmarkWriter.upsert(
                StoreSplitBookmarkSnapshot(
                    id: bookmarkID,
                    identity: episode.stableEpisodeIdentity,
                    time: bookmark.start ?? 0,
                    title: bookmark.title,
                    createdAt: bookmark.creationtime ?? now
                ),
                at: now
            )
            result.bookmarks += 1
        }
    }

    private func republishListeningHistory(
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        var historyOffset = 0
        while true {
            let page = listeningHistorySnapshots(
                offset: historyOffset,
                limit: historyPageSize
            )
            guard page.fetchedCount > 0 else { break }
            if page.snapshots.isEmpty == false {
                await StoreSplitListeningHistorySyncWriter(
                    modelContainer: userStateContainer
                ).upsert(page.snapshots)
                result.listeningSessions += page.snapshots.count
            }
            historyOffset += page.fetchedCount
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func episodeStateSnapshots(
        offset: Int,
        limit: Int
    ) -> (fetchedCount: Int, snapshots: [StoreSplitEpisodeStateSnapshot]) {
        autoreleasepool {
            let context = ModelContext(legacyContainer)
            var descriptor = FetchDescriptor<Episode>()
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            let episodes = (try? context.fetch(descriptor)) ?? []
            let snapshots: [StoreSplitEpisodeStateSnapshot] =
                episodes.compactMap { episode in
                guard let metadata = episode.metaData,
                      episode.podcast?.feed != nil else {
                    return nil
                }
                let snapshot = StoreSplitEpisodeStateSnapshot(
                    identity: episode.stableEpisodeIdentity,
                    playPosition: max(0, metadata.playPosition ?? 0),
                    maxPlayPosition: max(
                        0,
                        metadata.maxPlayposition ?? 0,
                        metadata.playPosition ?? 0
                    ),
                    duration: episode.duration,
                    isPlayed: metadata.completionDate != nil
                        || metadata.isHistory == true,
                    isArchived: metadata.isArchived == true
                        || metadata.status == .archived,
                    wasSkipped: metadata.wasSkipped,
                    completedAt: metadata.completionDate,
                    archivedAt: metadata.archivedAt,
                    firstPlayedAt: metadata.firstListenDate,
                    lastPlayedAt: metadata.lastPlayed
                )
                guard snapshot.hasUserOwnedState else { return nil }
                return snapshot
            }
            return (episodes.count, snapshots)
        }
    }

    private func listeningHistorySnapshots(
        offset: Int,
        limit: Int
    ) -> (fetchedCount: Int, snapshots: [StoreSplitListeningHistorySnapshot]) {
        autoreleasepool {
            let context = ModelContext(legacyContainer)
            var descriptor = FetchDescriptor<PlaySession>()
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            let sessions = (try? context.fetch(descriptor)) ?? []
            let snapshots: [StoreSplitListeningHistorySnapshot] =
                sessions.compactMap { session in
                guard let episode = session.episode,
                      let startedAt = session.startTime,
                      let endedAt = session.endTime,
                      endedAt > startedAt else {
                    return nil
                }
                let identity = episode.stableEpisodeIdentity
                return StoreSplitListeningHistorySnapshot(
                    id: ListeningHistoryIdentity.make(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        startPosition: session.startPosition ?? 0,
                        endPosition: session.endPosition ?? 0
                    ),
                    identity: identity,
                    podcastName: session.podcastName
                        ?? episode.displayPodcastTitle
                        ?? "Unknown Podcast",
                    episodeTitle: episode.title,
                    sourceDeviceID: session.sourceDeviceID
                        ?? ListeningDeviceIdentity.current().id,
                    sourceDeviceName: session.sourceDeviceName,
                    deviceModel: session.deviceModel,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: session.startPosition ?? 0,
                    endPosition: session.endPosition ?? 0,
                    listenedSeconds: endedAt.timeIntervalSince(startedAt),
                    silenceGapTimeSavedSeconds:
                        session.silenceGapTimeSavedSeconds ?? 0,
                    playbackRateTimeSavedSeconds:
                        PlaybackRateSavingsCalculator.secondsSaved(in: session),
                    endedCleanly: session.endedCleanly == true
                )
            }
            return (sessions.count, snapshots)
        }
    }

    private func removeDuplicateEntries(
        from playlist: Playlist,
        in context: ModelContext
    ) {
        var seen = Set<String>()
        var survivors: [PlaylistEntry] = []
        for entry in playlist.ordered {
            guard let episode = entry.episode else {
                context.delete(entry)
                continue
            }
            guard seen.insert(episode.stableEpisodeIdentity.key).inserted else {
                context.delete(entry)
                continue
            }
            entry.order = survivors.count
            survivors.append(entry)
        }
        playlist.items = survivors
    }
}

private extension StoreSplitEpisodeStateSnapshot {
    var hasUserOwnedState: Bool {
        playPosition > 0
            || maxPlayPosition > 0
            || isPlayed
            || isArchived
            || wasSkipped
            || completedAt != nil
            || archivedAt != nil
            || firstPlayedAt != nil
            || lastPlayedAt != nil
    }
}
#endif
