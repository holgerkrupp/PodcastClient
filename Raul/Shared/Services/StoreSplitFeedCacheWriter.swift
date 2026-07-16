import Foundation
import SwiftData

/// Phase 2 dual-write: mirrors feed-derivable podcast/episode data from the legacy
/// store into the local-only `PodcastCache.sqlite` (`CachedPodcast`/`CachedEpisode`).
///
/// Nothing reads these cache rows yet — this only starts *filling* the cache so a
/// later read cutover has data to read, and so the legacy store's feed data can
/// eventually stop syncing to iCloud. User state (subscription, play position,
/// bookmarks) is deliberately NOT written here; it lives in `UserState.sqlite`.
///
/// Every function is self-contained: it takes `ModelContainer`s (which are
/// `Sendable`) and creates its own `ModelContext`s, so no non-`Sendable` model
/// instance ever crosses an isolation boundary.
enum StoreSplitFeedCacheWriter {
    /// Upserts a single feed's cache rows from the legacy store. Call after a feed
    /// refresh/create has been written to the legacy container.
    static func upsertFeed(
        feedURL: URL,
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        let legacyContext = ModelContext(legacyContainer)
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feed == feedURL }
        )
        descriptor.fetchLimit = 1
        guard let podcast = try? legacyContext.fetch(descriptor).first else { return }

        let cacheContext = ModelContext(cacheContainer)
        upsert(podcast: podcast, into: cacheContext)
        try? cacheContext.save()
    }

    /// Bounded bootstrap: copies feeds that have no `CachedPodcast` yet, up to
    /// `limit` feeds per call. Presence of a `CachedPodcast` row is the checkpoint,
    /// so repeated calls make progress and become a cheap no-op once caught up.
    /// Returns the number of feeds copied this pass.
    @discardableResult
    static func bootstrapMissingFeeds(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer,
        limit: Int
    ) -> Int {
        let legacyContext = ModelContext(legacyContainer)
        guard let podcasts = try? legacyContext.fetch(FetchDescriptor<Podcast>()) else {
            return 0
        }
        let cacheContext = ModelContext(cacheContainer)
        var processed = 0
        for podcast in podcasts {
            guard processed < limit else { break }
            guard let feed = podcast.feed else { continue }
            let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
            if fetchCachedPodcast(id: feedKey, in: cacheContext) != nil { continue }
            upsert(podcast: podcast, into: cacheContext)
            try? cacheContext.save()
            processed += 1
        }
        return processed
    }

    // MARK: - Upsert

    private static func upsert(podcast: Podcast, into cacheContext: ModelContext) {
        guard let feed = podcast.feed else { return }
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)

        let cached = fetchCachedPodcast(id: feedKey, in: cacheContext)
            ?? {
                let created = CachedPodcast(id: feedKey, feedURL: feedKey)
                cacheContext.insert(created)
                return created
            }()

        cached.feedURL = feedKey
        cached.title = podcast.title
        cached.desc = podcast.desc
        cached.author = podcast.author
        cached.feed = podcast.feed
        cached.link = podcast.link
        cached.language = podcast.language
        cached.copyright = podcast.copyright
        cached.imageURL = podcast.imageURL
        cached.lastBuildDate = podcast.lastBuildDate
        cached.funding = podcast.funding
        cached.social = podcast.social
        cached.people = podcast.people
        cached.alternativeFeeds = podcast.alternativeFeeds
        cached.optionalTags = podcast.optionalTags

        let meta = podcast.metaData
        cached.lastRefresh = meta?.lastRefresh
        cached.feedUpdated = meta?.feedUpdated
        cached.feedUpdateCheckDate = meta?.feedUpdateCheckDate
        cached.consecutiveFeedFailureCount = meta?.consecutiveFeedFailureCount ?? 0
        cached.lastFeedFailureDate = meta?.lastFeedFailureDate
        cached.lastFeedFailureStatusCode = meta?.lastFeedFailureStatusCode
        cached.lastFeedFailureMessage = meta?.lastFeedFailureMessage
        cached.updatedAt = .now

        let existingEpisodes = fetchCachedEpisodes(feedKey: feedKey, in: cacheContext)
        var existingByID = Dictionary(
            existingEpisodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()

        for episode in podcast.episodes ?? [] {
            let identity = episode.stableEpisodeIdentity
            let episodeID = identity.key
            seenIDs.insert(episodeID)

            let cachedEpisode = existingByID[episodeID]
                ?? {
                    let created = CachedEpisode(id: episodeID, feedURL: feedKey)
                    cacheContext.insert(created)
                    existingByID[episodeID] = created
                    return created
                }()

            cachedEpisode.feedURL = feedKey
            cachedEpisode.guid = episode.guid
            cachedEpisode.title = episode.title
            cachedEpisode.author = episode.author
            cachedEpisode.desc = episode.desc
            cachedEpisode.subtitle = episode.subtitle
            cachedEpisode.content = episode.content
            cachedEpisode.publishDate = episode.publishDate
            cachedEpisode.url = episode.url
            cachedEpisode.deeplinks = episode.deeplinks
            cachedEpisode.fileSize = episode.fileSize
            cachedEpisode.mediaType = episode.mediaType
            cachedEpisode.link = episode.link
            cachedEpisode.imageURL = episode.imageURL
            cachedEpisode.duration = episode.duration
            cachedEpisode.number = episode.number
            cachedEpisode.typeRawValue = episode.type?.rawValue
            cachedEpisode.sourceRawValue = episode.sourceRawValue
            cachedEpisode.externalFiles = episode.externalFiles
            cachedEpisode.funding = episode.funding
            cachedEpisode.social = episode.social
            cachedEpisode.people = episode.people
            cachedEpisode.optionalTags = episode.optionalTags
            cachedEpisode.updatedAt = .now
            cachedEpisode.podcast = cached
        }

        // Prune cache episodes no longer present in the legacy feed so the cache
        // stays a faithful projection.
        for (episodeID, staleEpisode) in existingByID where seenIDs.contains(episodeID) == false {
            cacheContext.delete(staleEpisode)
        }
    }

    // MARK: - Fetch helpers

    private static func fetchCachedPodcast(
        id: String,
        in context: ModelContext
    ) -> CachedPodcast? {
        var descriptor = FetchDescriptor<CachedPodcast>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchCachedEpisodes(
        feedKey: String,
        in context: ModelContext
    ) -> [CachedEpisode] {
        let descriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
