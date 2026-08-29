import Foundation
import SwiftData

struct StoreSplitCompatibilityProjectionResult: Sendable {
    var podcasts = 0
    var episodes = 0
    var chapters = 0
    var transcriptLines = 0
    var playSessions = 0
    var hourlyStats = 0
    var failed = 0
}

/// Projects PodcastCache rows onto the model-shaped library graph.
///
/// `rebuild` targets the experimental in-memory graph and replaces it wholesale.
/// `recoverMissingLibraryData` targets the durable on-disk library store and is
/// strictly additive — it is the return path for devices that spent time in the
/// in-memory mode and persisted feed refreshes to the cache only.
enum StoreSplitCompatibilityProjectionService {
    static func rebuild(
        cacheContainer: ModelContainer,
        runtimeContainer: ModelContainer,
        feedPageSize: Int = 25,
        episodePageSize: Int = 100
    ) -> StoreSplitCompatibilityProjectionResult {
        var result = StoreSplitCompatibilityProjectionResult()
        let runtime = ModelContext(runtimeContainer)
        runtime.autosaveEnabled = false
        do {
            // The target is a disposable in-memory projection. Replacing it
            // makes a retry safe even if a prior launch saved only some pages.
            try runtime.delete(model: RateSegment.self)
            try runtime.delete(model: PlaySession.self)
            try runtime.delete(model: ListeningStat.self)
            try runtime.delete(model: PlaySessionSummary.self)
            try runtime.delete(model: Podcast.self)
            try runtime.delete(model: Playlist.self)
            try runtime.save()
        } catch {
            runtime.rollback()
            result.failed = 1
            return result
        }
        var feedOffset = 0

        while true {
            let cache = ModelContext(cacheContainer)
            var feedDescriptor = FetchDescriptor<CachedPodcast>(
                sortBy: [SortDescriptor(\CachedPodcast.feedURL)]
            )
            feedDescriptor.fetchOffset = feedOffset
            feedDescriptor.fetchLimit = feedPageSize
            guard let feeds = try? cache.fetch(feedDescriptor), !feeds.isEmpty else {
                break
            }

            for cachedPodcast in feeds {
                guard let feedURL = URL(string: cachedPodcast.feedURL) else {
                    result.failed += 1
                    continue
                }
                let podcast = Podcast(feed: feedURL)
                apply(cachedPodcast, to: podcast)
                runtime.insert(podcast)
                result.podcasts += 1

                var episodeOffset = 0
                while true {
                    let episodeCache = ModelContext(cacheContainer)
                    let feedKey = cachedPodcast.feedURL
                    var episodeDescriptor = FetchDescriptor<CachedEpisode>(
                        predicate: #Predicate { $0.feedURL == feedKey },
                        sortBy: [SortDescriptor(\CachedEpisode.publishDate)]
                    )
                    episodeDescriptor.fetchOffset = episodeOffset
                    episodeDescriptor.fetchLimit = episodePageSize
                    guard let cachedEpisodes = try? episodeCache.fetch(episodeDescriptor),
                          !cachedEpisodes.isEmpty else { break }

                    for cachedEpisode in cachedEpisodes {
                        let episode = makeEpisode(
                            from: cachedEpisode,
                            podcast: podcast,
                            cacheContext: episodeCache,
                            result: &result
                        )
                        runtime.insert(episode)
                        result.episodes += 1
                    }
                    episodeOffset += cachedEpisodes.count
                }
            }

            do {
                if runtime.hasChanges { try runtime.save() }
            } catch {
                result.failed += 1
                runtime.rollback()
            }
            feedOffset += feeds.count
        }

        projectLocalAnalytics(
            cacheContainer: cacheContainer,
            runtime: runtime,
            result: &result
        )
        return result
    }

    /// Additively restores feed data that exists only in `PodcastCache.sqlite`
    /// into the durable on-disk library store.
    ///
    /// This is the return path from the experimental cache-projection mode: a
    /// build that kept the runtime graph in memory persisted feed refreshes to
    /// the cache only, so the durable store can be missing whole podcasts or
    /// recent episodes. Nothing is deleted and nothing already present is
    /// rewritten — RSS and the durable store stay authoritative for everything
    /// they already know, and a partial pass is safe to repeat.
    ///
    /// `recoverableFeedKeys` must list the feeds the caller has proven are still
    /// wanted. Deleting a podcast or an episode removes it from the durable
    /// store but leaves its cache rows behind, so an unfiltered pass would
    /// resurrect content the user deliberately removed.
    static func recoverMissingLibraryData(
        cacheContainer: ModelContainer,
        runtimeContainer: ModelContainer,
        recoverableFeedKeys: Set<String>,
        feedPageSize: Int = 25,
        episodePageSize: Int = 100
    ) -> StoreSplitCompatibilityProjectionResult {
        var result = StoreSplitCompatibilityProjectionResult()
        let runtime = ModelContext(runtimeContainer)
        runtime.autosaveEnabled = false

        // Index the durable store once by feed comparison key so a redirected or
        // differently-normalized feed URL is not recovered as a duplicate.
        let existingPodcasts = (try? runtime.fetch(FetchDescriptor<Podcast>())) ?? []
        var podcastsByComparisonKey: [String: Podcast] = [:]
        for podcast in existingPodcasts {
            guard let feed = podcast.feed else { continue }
            for key in feed.podcastFeedComparisonKeys where podcastsByComparisonKey[key] == nil {
                podcastsByComparisonKey[key] = podcast
            }
        }

        var feedOffset = 0
        while true {
            let cache = ModelContext(cacheContainer)
            var feedDescriptor = FetchDescriptor<CachedPodcast>(
                sortBy: [SortDescriptor(\CachedPodcast.feedURL)]
            )
            feedDescriptor.fetchOffset = feedOffset
            feedDescriptor.fetchLimit = feedPageSize
            guard let feeds = try? cache.fetch(feedDescriptor), !feeds.isEmpty else {
                break
            }

            for cachedPodcast in feeds {
                guard recoverableFeedKeys.contains(cachedPodcast.feedURL) else {
                    continue
                }
                guard let feedURL = URL(string: cachedPodcast.feedURL) else {
                    result.failed += 1
                    continue
                }

                let podcast: Podcast
                if let existing = feedURL.podcastFeedComparisonKeys
                    .compactMap({ podcastsByComparisonKey[$0] })
                    .first {
                    podcast = existing
                } else {
                    let recovered = Podcast(feed: feedURL)
                    apply(cachedPodcast, to: recovered)
                    runtime.insert(recovered)
                    for key in feedURL.podcastFeedComparisonKeys {
                        podcastsByComparisonKey[key] = recovered
                    }
                    podcast = recovered
                    result.podcasts += 1
                }

                var knownEpisodeKeys = Set(
                    (podcast.episodes ?? []).map(\.stableEpisodeIdentityKey)
                )
                var episodeOffset = 0
                while true {
                    let episodeCache = ModelContext(cacheContainer)
                    let feedKey = cachedPodcast.feedURL
                    var episodeDescriptor = FetchDescriptor<CachedEpisode>(
                        predicate: #Predicate { $0.feedURL == feedKey },
                        sortBy: [SortDescriptor(\CachedEpisode.publishDate)]
                    )
                    episodeDescriptor.fetchOffset = episodeOffset
                    episodeDescriptor.fetchLimit = episodePageSize
                    guard let cachedEpisodes = try? episodeCache.fetch(episodeDescriptor),
                          !cachedEpisodes.isEmpty else { break }

                    for cachedEpisode in cachedEpisodes {
                        guard knownEpisodeKeys.contains(cachedEpisode.id) == false else {
                            continue
                        }
                        let episode = makeEpisode(
                            from: cachedEpisode,
                            podcast: podcast,
                            cacheContext: episodeCache,
                            result: &result
                        )
                        runtime.insert(episode)
                        knownEpisodeKeys.insert(cachedEpisode.id)
                        result.episodes += 1
                    }
                    episodeOffset += cachedEpisodes.count
                }
            }

            do {
                if runtime.hasChanges { try runtime.save() }
            } catch {
                result.failed += 1
                runtime.rollback()
            }
            feedOffset += feeds.count
        }

        return result
    }

    private static func apply(_ cachedPodcast: CachedPodcast, to podcast: Podcast) {
        podcast.title = cachedPodcast.title
        podcast.desc = cachedPodcast.desc
        podcast.author = cachedPodcast.author
        podcast.link = cachedPodcast.link
        podcast.language = cachedPodcast.language
        podcast.copyright = cachedPodcast.copyright
        podcast.imageURL = cachedPodcast.imageURL
        podcast.lastBuildDate = cachedPodcast.lastBuildDate
        podcast.funding = cachedPodcast.funding
        podcast.social = cachedPodcast.social
        podcast.people = cachedPodcast.people
        podcast.alternativeFeeds = cachedPodcast.alternativeFeeds
        podcast.optionalTags = cachedPodcast.optionalTags
        podcast.metaData?.lastRefresh = cachedPodcast.lastRefresh
        podcast.metaData?.feedUpdated = cachedPodcast.feedUpdated
        podcast.metaData?.feedUpdateCheckDate = cachedPodcast.feedUpdateCheckDate
        podcast.metaData?.consecutiveFeedFailureCount = cachedPodcast.consecutiveFeedFailureCount
        podcast.metaData?.lastFeedFailureDate = cachedPodcast.lastFeedFailureDate
        podcast.metaData?.lastFeedFailureStatusCode = cachedPodcast.lastFeedFailureStatusCode
        podcast.metaData?.lastFeedFailureMessage = cachedPodcast.lastFeedFailureMessage
    }

    /// Builds — but does not insert — the model-shaped episode for one cache row,
    /// including its cache-local chapters, transcript lines, and device-local
    /// inbox/suppression classification.
    private static func makeEpisode(
        from cachedEpisode: CachedEpisode,
        podcast: Podcast,
        cacheContext: ModelContext,
        result: inout StoreSplitCompatibilityProjectionResult
    ) -> Episode {
        let placeholderURL = cachedEpisode.url
            ?? cachedEpisode.link
            ?? URL(string: "about:blank")!
        let source = EpisodeSource(rawValue: cachedEpisode.sourceRawValue)
            ?? .feedDownload
        let episode = Episode(
            guid: cachedEpisode.guid,
            title: cachedEpisode.title,
            publishDate: cachedEpisode.publishDate,
            url: placeholderURL,
            podcast: podcast,
            duration: cachedEpisode.duration,
            author: cachedEpisode.author,
            source: source
        )
        episode.url = cachedEpisode.url
        episode.desc = cachedEpisode.desc
        episode.subtitle = cachedEpisode.subtitle
        episode.content = cachedEpisode.content
        episode.deeplinks = cachedEpisode.deeplinks
        episode.fileSize = cachedEpisode.fileSize
        episode.mediaType = cachedEpisode.mediaType
        episode.link = cachedEpisode.link
        episode.imageURL = cachedEpisode.imageURL
        episode.number = cachedEpisode.number
        episode.type = cachedEpisode.typeRawValue.flatMap(EpisodeType.init(rawValue:))
        episode.externalFiles = cachedEpisode.externalFiles
        episode.funding = cachedEpisode.funding
        episode.social = cachedEpisode.social
        episode.people = cachedEpisode.people
        episode.optionalTags = cachedEpisode.optionalTags
        episode.metaData?.isInbox = cachedEpisode.localIsInbox
        episode.metaData?.status = cachedEpisode.localStatusRawValue
            .flatMap(EpisodeStatus.init(rawValue:))
        episode.metaData?.systemSuppressionReasonRawValue =
            cachedEpisode.localSystemSuppressionReasonRawValue
        episode.metaData?.reconcileLegacyStatus()

        let rowID = cachedEpisode.id
        let chapterDescriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.episodeID == rowID },
            sortBy: [SortDescriptor(\CachedChapter.ordinal)]
        )
        let cachedChapters = (try? cacheContext.fetch(chapterDescriptor)) ?? []
        episode.chapters = cachedChapters.map { cached in
            let marker = Marker(
                start: cached.start ?? 0,
                title: cached.title,
                type: MarkerType(rawValue: cached.typeRawValue) ?? .unknown,
                imageData: cached.imageData,
                duration: cached.duration
            )
            marker.uuid = cached.sourceUUID.flatMap(UUID.init(uuidString:))
            marker.link = cached.link
            marker.image = cached.imageURL
            marker.endTime = cached.endTime
            marker.creationtime = cached.creationTime
            marker.progress = cached.progress
            marker.shouldPlay = cached.shouldPlay
            marker.episode = episode
            result.chapters += 1
            return marker
        }

        let transcriptDescriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate { $0.episodeID == rowID },
            sortBy: [SortDescriptor(\CachedTranscriptLine.ordinal)]
        )
        let cachedLines = (try? cacheContext.fetch(transcriptDescriptor)) ?? []
        episode.transcriptLines = cachedLines.map { cached in
            result.transcriptLines += 1
            return TranscriptLineAndTime(
                speaker: cached.speaker,
                text: cached.text,
                startTime: cached.startTime,
                endTime: cached.endTime
            )
        }
        return episode
    }

    private static func projectLocalAnalytics(
        cacheContainer: ModelContainer,
        runtime: ModelContext,
        result: inout StoreSplitCompatibilityProjectionResult
    ) {
        let episodes = (try? runtime.fetch(FetchDescriptor<Episode>())) ?? []
        let episodesByIdentity = episodes.reduce(into: [String: Episode]()) {
            $0[$1.stableEpisodeIdentityKey] = $1
        }
        let cache = ModelContext(cacheContainer)
        let pageSize = 250
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<CachedPlaySession>(
                sortBy: [SortDescriptor(\CachedPlaySession.startedAt)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? cache.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }

            for cached in page {
                let identity = EpisodeStableIdentity(
                    feedURL: cached.feedURL,
                    episodeID: cached.episodeID
                )
                let projectedID: UUID
                if let endedAt = cached.endedAt {
                    projectedID = StableIdentityKey.uuid(for:
                        ListeningHistoryIdentity.canonicalAggregationKey(
                            feedURL: cached.feedURL,
                            episodeID: cached.episodeID,
                            startedAt: cached.startedAt,
                            endedAt: endedAt,
                            listenedSeconds: endedAt.timeIntervalSince(cached.startedAt)
                        )
                    )
                } else {
                    projectedID = UUID(uuidString: cached.id)
                        ?? StableIdentityKey.uuid(for: cached.id)
                }
                let session = PlaySession(
                    id: projectedID,
                    episode: episodesByIdentity[identity.key],
                    sourceDeviceID: cached.sourceDeviceID,
                    sourceDeviceName: cached.sourceDeviceName,
                    deviceModel: cached.deviceModel,
                    osVersion: cached.osVersion,
                    appVersion: cached.endedAt == nil
                        ? cached.appVersion
                        : ListeningDeviceIdentity.splitStoreProjectionAppVersion,
                    startTime: cached.startedAt,
                    endTime: cached.endedAt,
                    startPosition: cached.startPosition,
                    endPosition: cached.endPosition,
                    silenceGapTimeSavedSeconds: cached.silenceGapTimeSavedSeconds,
                    endedCleanly: cached.endedCleanly
                )
                session.podcastName = cached.podcastName
                let sessionID = cached.id
                let rateDescriptor = FetchDescriptor<CachedRateSegment>(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\CachedRateSegment.ordinal)]
                )
                session.segments = ((try? cache.fetch(rateDescriptor)) ?? []).map {
                    RateSegment(
                        rate: $0.rate,
                        startTime: $0.startTime,
                        startPosition: $0.startPosition,
                        endTime: $0.endTime,
                        endPosition: $0.endPosition,
                        parentSession: session
                    )
                }
                runtime.insert(session)
                result.playSessions += 1
            }

            do {
                if runtime.hasChanges { try runtime.save() }
            } catch {
                runtime.rollback()
                result.failed += 1
            }
            offset += page.count
            if page.count < pageSize { break }
        }

        struct HourKey: Hashable {
            let feedURL: String
            let startOfHour: Date
        }
        struct HourValue {
            var podcastName: String?
            var total = 0.0
            var silence = 0.0
            var rate = 0.0
        }
        var hours: [HourKey: HourValue] = [:]
        offset = 0
        while true {
            var descriptor = FetchDescriptor<CachedHourlyListeningStat>(
                sortBy: [SortDescriptor(\CachedHourlyListeningStat.startOfHour)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? cache.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }
            for row in page {
                let key = HourKey(feedURL: row.feedURL, startOfHour: row.startOfHour)
                var value = hours[key] ?? HourValue()
                value.podcastName = row.podcastName ?? value.podcastName
                value.total += max(0, row.totalSeconds)
                value.silence += max(0, row.silenceGapTimeSavedSeconds)
                value.rate += max(0, row.playbackRateTimeSavedSeconds)
                hours[key] = value
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        for (key, value) in hours where value.total > 0 {
            runtime.insert(ListeningStat(
                id: StableIdentityKey.uuid(for: StableIdentityKey.make(
                    key.feedURL,
                    String(Int(key.startOfHour.timeIntervalSince1970))
                )),
                startOfHour: key.startOfHour,
                podcastFeed: URL(string: key.feedURL),
                podcastName: value.podcastName,
                totalSeconds: value.total,
                silenceGapTimeSavedSeconds: value.silence,
                playbackRateTimeSavedSeconds: value.rate
            ))
            result.hourlyStats += 1
        }
        do {
            if runtime.hasChanges { try runtime.save() }
        } catch {
            runtime.rollback()
            result.failed += 1
        }
    }
}
