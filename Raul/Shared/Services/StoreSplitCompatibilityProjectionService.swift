import Foundation
import SwiftData

struct StoreSplitCompatibilityProjectionResult: Sendable {
    var podcasts = 0
    var episodes = 0
    var chapters = 0
    var transcriptLines = 0
    var playSessions = 0
    var hourlyStats = 0
    var transcriptionRecords = 0
    var failed = 0
    var interrupted = false
}

/// Projects PodcastCache rows onto the model-shaped library graph.
///
/// `rebuild` targets the experimental in-memory graph and replaces it wholesale.
/// `recoverMissingLibraryData` targets the durable on-disk library store and is
/// strictly additive — it is the return path for devices that spent time in the
/// in-memory mode and persisted feed refreshes to the cache only.
enum StoreSplitCompatibilityProjectionService {
    /// Builds the runtime graph one feed at a time, each with its own context and
    /// small saves so neither memory nor save time grows with the library. Every
    /// finished feed is reported through `checkpoint`; passing it back as
    /// `resumeAfter` continues there instead of starting over.
    static func rebuild(
        cacheContainer: ModelContainer,
        runtimeContainer: ModelContainer,
        feedPageSize: Int = 25,
        episodePageSize: Int = 100,
        resumeAfter: String? = nil,
        includesTranscripts: Bool = true,
        priorityEpisodes: Set<String>? = nil,
        shouldContinue: @Sendable () -> Bool = { true },
        checkpoint: @Sendable (String) -> Void = { _ in },
        progress: @Sendable (_ episodes: Int, _ total: Int) -> Void = { _, _ in }
    ) -> StoreSplitCompatibilityProjectionResult {
        var result = StoreSplitCompatibilityProjectionResult()
        do {
            let runtime = ModelContext(runtimeContainer)
            runtime.autosaveEnabled = false
            if let resumeAfter {
                // Only a feed that was still in progress can be partial.
                for podcast in try runtime.fetch(FetchDescriptor<Podcast>())
                where (podcast.feed?.absoluteString ?? "") > resumeAfter {
                    runtime.delete(podcast)
                }
            } else {
                // Replacing it makes a fresh build safe after an abandoned one.
                try runtime.delete(model: Podcast.self)
                try runtime.delete(model: Playlist.self)
                try runtime.delete(model: TranscriptionRecord.self)
            }
            try runtime.save()
        } catch {
            result.failed = 1
            return result
        }

        let totalEpisodes = priorityEpisodes?.count
            ?? (try? ModelContext(cacheContainer).fetchCount(FetchDescriptor<CachedEpisode>())) ?? 0
        var doneEpisodes = 0
        if let resumeAfter, priorityEpisodes == nil {
            doneEpisodes = (try? ModelContext(cacheContainer).fetchCount(FetchDescriptor<CachedEpisode>(
                predicate: #Predicate { $0.feedURL <= resumeAfter }
            ))) ?? 0
        }
        progress(doneEpisodes, totalEpisodes)

        var lastFeed = resumeAfter
        while true {
            let cache = ModelContext(cacheContainer)
            var feedDescriptor: FetchDescriptor<CachedPodcast>
            if let lastFeed {
                feedDescriptor = FetchDescriptor(
                    predicate: #Predicate { $0.feedURL > lastFeed },
                    sortBy: [SortDescriptor(\CachedPodcast.feedURL)]
                )
            } else {
                feedDescriptor = FetchDescriptor(sortBy: [SortDescriptor(\CachedPodcast.feedURL)])
            }
            feedDescriptor.fetchLimit = feedPageSize
            let feeds: [CachedPodcast]
            do { feeds = try cache.fetch(feedDescriptor) }
            catch { result.failed += 1; return result }
            guard !feeds.isEmpty else { break }

            for cachedPodcast in feeds {
                guard shouldContinue() else {
                    result.interrupted = true
                    return result
                }
                let feedKey = cachedPodcast.feedURL
                lastFeed = feedKey
                guard let feedURL = URL(string: feedKey) else {
                    result.failed += 1
                    continue
                }
                let runtime = ModelContext(runtimeContainer)
                runtime.autosaveEnabled = false
                let podcast = Podcast(feed: feedURL)
                apply(cachedPodcast, to: podcast)
                // Subscription state belongs to UserState: the importer sets it
                // from SubscriptionSync. A cached feed alone is not a subscription.
                podcast.metaData?.isSubscribed = false
                podcast.metaData?.subscriptionDate = nil
                runtime.insert(podcast)
                result.podcasts += 1
                restoreTranscriptionRecords(
                    feedKey: feedKey,
                    cacheContainer: cacheContainer,
                    runtime: runtime,
                    result: &result
                )

                if let priorityEpisodes {
                    let cache = ModelContext(cacheContainer)
                    let inInbox = (try? cache.fetch(FetchDescriptor<CachedEpisode>(
                        predicate: #Predicate { $0.feedURL == feedKey && $0.localIsInbox == true }
                    ))) ?? []
                    var seen = Set<String>()
                    let wanted = priorityEpisodes.filter { $0.hasPrefix(StableIdentityKey.make(feedKey)) }
                    var rows = inInbox
                    for id in wanted {
                        var descriptor = FetchDescriptor<CachedEpisode>(predicate: #Predicate { $0.id == id })
                        descriptor.fetchLimit = 1
                        if let row = try? cache.fetch(descriptor).first { rows.append(row) }
                    }
                    for row in rows where seen.insert(row.id).inserted {
                        let episode = makeEpisode(
                            from: row,
                            podcast: podcast,
                            cacheContext: cache,
                            includesTranscripts: includesTranscripts,
                            result: &result
                        )
                        runtime.insert(episode)
                        result.episodes += 1
                        doneEpisodes += 1
                    }
                    progress(min(doneEpisodes, totalEpisodes), totalEpisodes)
                }

                var episodeOffset = 0
                while priorityEpisodes == nil {
                    guard shouldContinue() else {
                        result.interrupted = true
                        return result
                    }
                    let outcome: Bool? = autoreleasepool {
                        let episodeCache = ModelContext(cacheContainer)
                        var episodeDescriptor = FetchDescriptor<CachedEpisode>(
                            predicate: #Predicate { $0.feedURL == feedKey },
                            sortBy: [
                                SortDescriptor(\CachedEpisode.publishDate),
                                SortDescriptor(\CachedEpisode.id)
                            ]
                        )
                        episodeDescriptor.fetchOffset = episodeOffset
                        episodeDescriptor.fetchLimit = episodePageSize
                        guard let cachedEpisodes = try? episodeCache.fetch(episodeDescriptor) else {
                            return nil
                        }
                        guard !cachedEpisodes.isEmpty else { return false }
                        for cachedEpisode in cachedEpisodes {
                            let episode = makeEpisode(
                                from: cachedEpisode,
                                podcast: podcast,
                                cacheContext: episodeCache,
                                includesTranscripts: includesTranscripts,
                                result: &result
                            )
                            runtime.insert(episode)
                            result.episodes += 1
                        }
                        episodeOffset += cachedEpisodes.count
                        doneEpisodes += cachedEpisodes.count
                        return (try? runtime.save()) != nil ? true : nil
                    }
                    guard let more = outcome else {
                        result.failed += 1
                        return result
                    }
                    guard more else { break }
                    progress(doneEpisodes, totalEpisodes)
                }
                do {
                    if runtime.hasChanges { try runtime.save() }
                } catch {
                    result.failed += 1
                    return result
                }
                checkpoint(feedKey)
            }
        }

        guard shouldContinue() else {
            result.interrupted = true
            return result
        }
        let runtime = ModelContext(runtimeContainer)
        runtime.autosaveEnabled = false
        do {
            // Analytics are built whole, so an interrupted run just repeats them.
            try runtime.delete(model: RateSegment.self)
            try runtime.delete(model: PlaySession.self)
            try runtime.delete(model: ListeningStat.self)
            try runtime.delete(model: PlaySessionSummary.self)
            try runtime.save()
        } catch {
            result.failed += 1
            return result
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
        let existingPodcasts: [Podcast]
        do {
            existingPodcasts = try runtime.fetch(FetchDescriptor<Podcast>())
        } catch {
            // Treating a failed destination read as an empty library can
            // resurrect cached feeds or create duplicate podcasts. This pass
            // is recovery-only and can be retried when the store is readable.
            result.failed += 1
            return result
        }
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
            let feeds: [CachedPodcast]
            do { feeds = try cache.fetch(feedDescriptor) }
            catch { result.failed += 1; return result }
            guard !feeds.isEmpty else { break }

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
                        sortBy: [
                            SortDescriptor(\CachedEpisode.publishDate),
                            SortDescriptor(\CachedEpisode.id)
                        ]
                    )
                    episodeDescriptor.fetchOffset = episodeOffset
                    episodeDescriptor.fetchLimit = episodePageSize
                    let cachedEpisodes: [CachedEpisode]
                    do { cachedEpisodes = try episodeCache.fetch(episodeDescriptor) }
                    catch { result.failed += 1; return result }
                    guard !cachedEpisodes.isEmpty else { break }

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
        podcast.metaData?.firstConsecutiveFeedFailureDate = cachedPodcast.firstConsecutiveFeedFailureDate
        podcast.metaData?.authenticationRetryAfter = cachedPodcast.authenticationRetryAfter
        podcast.metaData?.nextPredictedReleaseDate = cachedPodcast.nextPredictedReleaseDate
        podcast.metaData?.nextPredictedRefreshStartDate = cachedPodcast.nextPredictedRefreshStartDate
        podcast.metaData?.nextPredictedRefreshEndDate = cachedPodcast.nextPredictedRefreshEndDate
        podcast.metaData?.releasePredictionUpdatedAt = cachedPodcast.releasePredictionUpdatedAt
    }

    private static func restoreTranscriptionRecords(
        feedKey: String,
        cacheContainer: ModelContainer,
        runtime: ModelContext,
        result: inout StoreSplitCompatibilityProjectionResult
    ) {
        let cache = ModelContext(cacheContainer)
        let rows = (try? cache.fetch(FetchDescriptor<CachedTranscriptionRecord>(
            predicate: #Predicate { $0.feedURL == feedKey }
        ))) ?? []
        for row in rows {
            guard let episodeURL = row.episodeURL else { continue }
            let record = TranscriptionRecord(
                episodeURL: episodeURL,
                episodeTitle: row.episodeTitle,
                podcastTitle: row.podcastTitle,
                localeIdentifier: row.localeIdentifier,
                startedAt: row.startedAt,
                finishedAt: row.finishedAt,
                audioDuration: row.audioDuration
            )
            record.id = UUID(uuidString: row.id) ?? record.id
            record.transcriptionDuration = row.transcriptionDuration
            runtime.insert(record)
            result.transcriptionRecords += 1
        }
    }

    /// Builds — but does not insert — the model-shaped episode for one cache row,
    /// including its cache-local chapters, transcript lines, and device-local
    /// inbox/suppression classification.
    private static func makeEpisode(
        from cachedEpisode: CachedEpisode,
        podcast: Podcast,
        cacheContext: ModelContext,
        includesTranscripts: Bool = true,
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
        let restoredStatus = cachedEpisode.localStatusRawValue
            .flatMap(EpisodeStatus.init(rawValue:))
        episode.metaData?.isInbox = cachedEpisode.localIsInbox
        // `status` is derived from these flags; restore them so it round-trips.
        episode.metaData?.isArchived = restoredStatus == .archived
        episode.metaData?.isHistory = restoredStatus == .history
        episode.metaData?.status = restoredStatus
        episode.metaData?.systemSuppressionReasonRawValue =
            cachedEpisode.localSystemSuppressionReasonRawValue
        episode.metaData?.reconcileLegacyStatus()
        episode.metaData?.playbackStartTimes = cachedEpisode.playbackStartTimes ?? .init([])
        episode.metaData?.playbackDurations = cachedEpisode.playbackDurations ?? .init([])
        episode.metaData?.silenceGapTimeSavedDurations =
            cachedEpisode.silenceGapTimeSavedDurations ?? .init([])
        episode.metaData?.playbackSpeeds = cachedEpisode.playbackSpeeds ?? .init([])
        episode.metaData?.totalListenTime = cachedEpisode.totalListenTime
        episode.metaData?.totalSilenceGapTimeSaved = cachedEpisode.totalSilenceGapTimeSaved
        // Resolve the current sandbox path rather than trusting a cached URL or
        // flag from a previous installation. Never redownload an existing file.
        episode.metaData?.isAvailableLocally = episode.localFile.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false


        let rowID = cachedEpisode.id
        let rowFeedKey = cachedEpisode.feedURL
        let chapterDescriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.feedURL == rowFeedKey && $0.episodeID == rowID },
            sortBy: [SortDescriptor(\CachedChapter.ordinal)]
        )
        let cachedChapters = (try? cacheContext.fetch(chapterDescriptor)) ?? []
        episode.chapters = cachedChapters.map { cached in
            let markerType = cached.typeRawValue == "advertisement"
                ? MarkerType.ai
                : (MarkerType(rawValue: cached.typeRawValue) ?? .unknown)
            let marker = Marker(
                start: cached.start ?? 0,
                title: cached.title,
                type: markerType,
                imageData: cached.imageData,
                duration: cached.duration
            )
            marker.uuid = cached.sourceUUID.flatMap(UUID.init(uuidString:))
            marker.link = cached.link
            marker.image = cached.imageURL
            marker.endTime = cached.endTime
            marker.creationtime = cached.creationTime
            marker.analysisVariantID = cached.analysisVariantID
            marker.progress = cached.progress
            marker.shouldPlay = cached.shouldPlay
            marker.episode = episode
            result.chapters += 1
            return marker
        }

        if includesTranscripts {
            let lines = makeTranscriptLines(feedKey: rowFeedKey, episodeID: rowID, cacheContext: cacheContext)
            result.transcriptLines += lines.count
            episode.transcriptLines = lines
        }
        return episode
    }

    private static func makeTranscriptLines(
        feedKey: String,
        episodeID: String,
        cacheContext: ModelContext
    ) -> [TranscriptLineAndTime] {
        let descriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate { $0.feedURL == feedKey && $0.episodeID == episodeID },
            sortBy: [SortDescriptor(\CachedTranscriptLine.ordinal)]
        )
        return ((try? cacheContext.fetch(descriptor)) ?? []).map { cached in
            TranscriptLineAndTime(
                id: cached.sourceUUID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                speaker: cached.speaker,
                text: cached.text,
                startTime: cached.startTime,
                endTime: cached.endTime,
                source: CachedTranscriptSource(rawValue: cached.sourceRawValue) ?? .unknown
            )
        }
    }

    /// What the first build includes, beyond the Inbox: what a person can reach
    /// from the main screens immediately. The rest fills in right after.
    static func priorityEpisodeKeys(userState: ModelContainer, cache: ModelContainer) -> Set<String> {
        let context = ModelContext(userState)
        var keys = Set<String>()
        // A downloaded episode has to stay reachable, whatever else it is.
        for row in (try? ModelContext(cache).fetch(FetchDescriptor<CachedDownloadRecord>(
            predicate: #Predicate { $0.isAvailableLocally == true }
        ))) ?? [] {
            keys.insert(StableIdentityKey.make(row.feedURL, row.episodeID))
        }
        for row in (try? context.fetch(FetchDescriptor<QueueEntrySync>(
            predicate: #Predicate { $0.isDeleted == false }
        ))) ?? [] {
            keys.insert(StableIdentityKey.make(row.feedURL, row.episodeID))
        }
        for row in (try? context.fetch(FetchDescriptor<PlaylistEntrySync>(
            predicate: #Predicate { $0.isDeleted == false }
        ))) ?? [] {
            keys.insert(StableIdentityKey.make(row.feedURL, row.episodeID))
        }
        for row in (try? context.fetch(FetchDescriptor<BookmarkSync>(
            predicate: #Predicate { $0.isDeleted == false }
        ))) ?? [] {
            keys.insert(StableIdentityKey.make(row.feedURL, row.episodeID))
        }
        var recent = FetchDescriptor<EpisodeStateSync>(
            sortBy: [SortDescriptor(\EpisodeStateSync.lastPlayedAt, order: .reverse)]
        )
        recent.fetchLimit = 200
        for row in (try? context.fetch(recent)) ?? [] {
            keys.insert(StableIdentityKey.make(row.feedURL, row.episodeID))
        }
        return keys
    }

    /// Applies the synced state as the episode is added. An episode without it
    /// would look unplayed, and its next write would publish that over the truth.
    static func applySyncedState(to episode: Episode, id: String, userState: ModelContext) {
        var descriptor = FetchDescriptor<EpisodeStateSync>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let state = try? userState.fetch(descriptor).first,
              let metadata = episode.metaData else { return }
        metadata.playPosition = max(0, state.playPosition)
        metadata.maxPlayposition = max(state.maxPlayPosition, state.playPosition)
        metadata.stateUpdatedAt = state.updatedAt
        metadata.lastPlayed = state.lastPlayedAt
        metadata.firstListenDate = state.firstPlayedAt
        metadata.completionDate = state.completedAt
        metadata.archivedAt = state.archivedAt
        metadata.wasSkipped = state.wasSkipped
        metadata.isArchived = state.isArchived
        metadata.isHistory = state.isPlayed
        if state.isArchived || state.isPlayed { metadata.isInbox = false }
        if state.isArchived {
            metadata.status = .archived
        } else if state.isPlayed {
            metadata.status = .history
        }
    }

    /// Re-derives sessions once every episode they belong to is in the graph.
    static func rebuildLocalAnalytics(
        cacheContainer: ModelContainer,
        runtimeContainer: ModelContainer
    ) {
        let runtime = ModelContext(runtimeContainer)
        runtime.autosaveEnabled = false
        var result = StoreSplitCompatibilityProjectionResult()
        do {
            try runtime.delete(model: RateSegment.self)
            try runtime.delete(model: PlaySession.self)
            try runtime.delete(model: ListeningStat.self)
            try runtime.delete(model: PlaySessionSummary.self)
            try runtime.save()
        } catch {
            return
        }
        projectLocalAnalytics(cacheContainer: cacheContainer, runtime: runtime, result: &result)
    }

    /// Adds saved transcripts to the episodes now in the graph, while the app is
    /// in use. Transcripts can't come from a feed, so this one part does read the
    /// cache. One feed at a time and resumable. An episode that already has lines
    /// keeps them: those are newer than the cache's.
    /// Returns false if it should run again.
    static func backfillTranscripts(
        cacheContainer: ModelContainer,
        runtimeContainer: ModelContainer,
        resumeAfter: String?,
        episodePageSize: Int = 25,
        shouldContinue: @Sendable () -> Bool,
        checkpoint: @Sendable (String) -> Void,
        idle: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(100)) }
    ) async -> Bool {
        var lastFeed = resumeAfter
        while true {
            var feedDescriptor: FetchDescriptor<CachedPodcast>
            if let lastFeed {
                feedDescriptor = FetchDescriptor(
                    predicate: #Predicate { $0.feedURL > lastFeed },
                    sortBy: [SortDescriptor(\CachedPodcast.feedURL)]
                )
            } else {
                feedDescriptor = FetchDescriptor(sortBy: [SortDescriptor(\CachedPodcast.feedURL)])
            }
            feedDescriptor.fetchLimit = 1
            guard let feeds = try? ModelContext(cacheContainer).fetch(feedDescriptor) else { return false }
            guard let feedKey = feeds.first?.feedURL else { return true }
            lastFeed = feedKey

            let runtime = ModelContext(runtimeContainer)
            runtime.autosaveEnabled = false
            let feedURL = URL(string: feedKey)
            guard let podcast = try? runtime.fetch(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.feed == feedURL }
            )).first else {
                checkpoint(feedKey)
                continue
            }
            let episodesByID = Dictionary(
                (podcast.episodes ?? []).map { ($0.stableEpisodeIdentityKey, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var offset = 0
            while true {
                guard shouldContinue() else { return false }
                let cache = ModelContext(cacheContainer)
                var descriptor = FetchDescriptor<CachedEpisode>(
                    predicate: #Predicate { $0.feedURL == feedKey },
                    sortBy: [SortDescriptor(\CachedEpisode.id)]
                )
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = episodePageSize
                guard let page = try? cache.fetch(descriptor) else { return false }
                guard page.isEmpty == false else { break }
                autoreleasepool {
                    for cachedEpisode in page {
                        guard let episode = episodesByID[cachedEpisode.id] else { continue }
                        guard episode.transcriptLines?.isEmpty != false else { continue }
                        let lines = makeTranscriptLines(
                            feedKey: feedKey,
                            episodeID: cachedEpisode.id,
                            cacheContext: cache
                        )
                        if lines.isEmpty == false { episode.transcriptLines = lines }
                    }
                }
                do {
                    if runtime.hasChanges { try runtime.save() }
                } catch {
                    return false
                }
                offset += page.count
                await idle()
            }
            checkpoint(feedKey)
        }
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
