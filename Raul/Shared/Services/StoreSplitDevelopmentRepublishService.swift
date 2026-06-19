#if DEBUG
import Foundation
import SwiftData

struct StoreSplitDevelopmentRepublishResult: Sendable {
    var subscriptions = 0
    var episodeStates = 0
    var playlists = 0
    var bookmarks = 0
    var listeningSessions = 0
}

actor StoreSplitDevelopmentRepublishService {
    private let legacyContext: ModelContext
    private let userStateContainer: ModelContainer

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        legacyContext = ModelContext(legacyContainer)
        self.userStateContainer = userStateContainer
    }

    nonisolated static func republish(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) async -> StoreSplitDevelopmentRepublishResult {
        let service = StoreSplitDevelopmentRepublishService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        return await service.run()
    }

    private func run() async -> StoreSplitDevelopmentRepublishResult {
        var result = StoreSplitDevelopmentRepublishResult()
        let now = Date()
        let subscriptionWriter = StoreSplitSubscriptionSyncWriter(
            modelContainer: userStateContainer
        )
        for podcast in (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? [] {
            guard let feed = podcast.feed else { continue }
            await subscriptionWriter.setSubscribed(
                feedURL: feed,
                isSubscribed: podcast.metaData?.isSubscribed != false,
                at: now
            )
            result.subscriptions += 1
        }

        let episodeWriter = StoreSplitEpisodeStateSyncWriter(
            modelContainer: userStateContainer
        )
        for episode in (try? legacyContext.fetch(FetchDescriptor<Episode>())) ?? [] {
            guard let metadata = episode.metaData,
                  episode.podcast?.feed != nil else { continue }
            await episodeWriter.upsert(
                StoreSplitEpisodeStateSnapshot(
                    identity: episode.stableEpisodeIdentity,
                    playPosition: max(0, metadata.playPosition ?? 0),
                    maxPlayPosition: max(
                        0,
                        metadata.maxPlayposition ?? 0,
                        metadata.playPosition ?? 0
                    ),
                    duration: episode.duration,
                    isPlayed: metadata.completionDate != nil || metadata.isHistory == true,
                    isArchived: metadata.isArchived == true || metadata.status == .archived,
                    wasSkipped: metadata.wasSkipped,
                    completedAt: metadata.completionDate,
                    archivedAt: metadata.archivedAt,
                    firstPlayedAt: metadata.firstListenDate,
                    lastPlayedAt: metadata.lastPlayed
                ),
                at: now
            )
            result.episodeStates += 1
        }

        let playlistWriter = StoreSplitPlaylistSyncWriter(
            modelContainer: userStateContainer
        )
        for playlist in (try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? [] {
            await playlistWriter.upsert(playlist.storeSplitSnapshot, at: now)
            result.playlists += 1
        }

        let bookmarkWriter = StoreSplitBookmarkSyncWriter(
            modelContainer: userStateContainer
        )
        for bookmark in (try? legacyContext.fetch(FetchDescriptor<Bookmark>())) ?? [] {
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

        let historyWriter = StoreSplitListeningHistorySyncWriter(
            modelContainer: userStateContainer
        )
        for session in (try? legacyContext.fetch(FetchDescriptor<PlaySession>())) ?? [] {
            guard let episode = session.episode,
                  let startedAt = session.startTime,
                  let endedAt = session.endTime,
                  endedAt > startedAt else { continue }
            let id = ListeningHistoryIdentity.make(
                feedURL: episode.stableEpisodeIdentity.feedURL,
                episodeID: episode.stableEpisodeIdentity.episodeID,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0
            )
            await historyWriter.upsert(
                StoreSplitListeningHistorySnapshot(
                    id: id,
                    identity: episode.stableEpisodeIdentity,
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
                    silenceGapTimeSavedSeconds: session.silenceGapTimeSavedSeconds ?? 0,
                    playbackRateTimeSavedSeconds: PlaybackRateSavingsCalculator.secondsSaved(
                        in: session
                    ),
                    endedCleanly: session.endedCleanly == true
                )
            )
            result.listeningSessions += 1
        }
        return result
    }
}
#endif
