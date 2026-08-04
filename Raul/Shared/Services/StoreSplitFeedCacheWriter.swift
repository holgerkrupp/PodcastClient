import Foundation
import SwiftData

/// Mirrors feed-derivable data from the legacy store into the local-only
/// `PodcastCache.sqlite`. Phase 2 introduced podcast/episode metadata; Phase 3
/// adds chapters, transcript data, transcription history and download indexing.
///
/// Nothing reads these cache rows yet — the versioned projection fills them so a
/// later repository cutover has complete data. User state (subscription, play
/// position, bookmarks) is deliberately NOT written here; it lives in
/// `UserState.sqlite`.
///
/// Every function is self-contained: it takes `ModelContainer`s (which are
/// `Sendable`) and creates its own `ModelContext`s, so no non-`Sendable` model
/// instance ever crosses an isolation boundary.
enum StoreSplitFeedCacheWriter {
    /// Phase 2 wrote podcast/episode metadata as version 1. Phase 3 adds the
    /// cache-local records required before repository reads can be cut over.
    static let currentCacheSchemaVersion = 2

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
        upsert(
            podcast: podcast,
            transcriptionRecordsByEpisodeURL: transcriptionRecordsByEpisodeURL(in: legacyContext),
            into: cacheContext
        )
        try? cacheContext.save()
    }

    /// Bounded bootstrap: copies new feeds and upgrades older cache projections,
    /// up to `limit` feeds per call. `CachedPodcast.cacheSchemaVersion` is the
    /// checkpoint, so feeds with no chapters/transcripts are still marked done.
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
        let transcriptionRecords = transcriptionRecordsByEpisodeURL(in: legacyContext)
        var processed = 0
        for podcast in podcasts {
            guard processed < limit else { break }
            guard let feed = podcast.feed else { continue }
            let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
            if let cached = fetchCachedPodcast(id: feedKey, in: cacheContext),
               cached.cacheSchemaVersion >= currentCacheSchemaVersion {
                continue
            }
            upsert(
                podcast: podcast,
                transcriptionRecordsByEpisodeURL: transcriptionRecords,
                into: cacheContext
            )
            try? cacheContext.save()
            processed += 1
        }
        return processed
    }

    /// Records an accepted feed move without rewriting synchronized state keys.
    /// The upcoming repository layer will resolve this mapping while composing
    /// cache metadata with user state.
    static func upsertFeedAlias(
        from oldURL: URL,
        to newURL: URL,
        reason: FeedAliasReason,
        cacheContainer: ModelContainer
    ) {
        let oldKey = PodcastFeedIdentity.normalizedFeedURLString(oldURL)
        let newKey = PodcastFeedIdentity.normalizedFeedURLString(newURL)
        guard oldKey != newKey else { return }

        let aliasID = StableIdentityKey.make(oldKey)
        let context = ModelContext(cacheContainer)
        var descriptor = FetchDescriptor<FeedAlias>(
            predicate: #Predicate { $0.id == aliasID }
        )
        descriptor.fetchLimit = 1
        let alias = (try? context.fetch(descriptor).first)
            ?? {
                let created = FeedAlias(
                    oldFeedURL: oldKey,
                    newFeedURL: newKey,
                    reason: reason
                )
                context.insert(created)
                return created
            }()
        alias.oldFeedURL = oldKey
        alias.newFeedURL = newKey
        alias.reasonRawValue = reason.rawValue
        alias.updatedAt = .now
        try? context.save()
    }

    // MARK: - Upsert

    private static func upsert(
        podcast: Podcast,
        transcriptionRecordsByEpisodeURL: [URL: [TranscriptionRecord]],
        into cacheContext: ModelContext
    ) {
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

            upsertChapters(
                episode.chapters ?? [],
                feedKey: feedKey,
                episodeID: episodeID,
                into: cacheContext
            )
            upsertTranscriptLines(
                episode.transcriptLines ?? [],
                feedKey: feedKey,
                episodeID: episodeID,
                into: cacheContext
            )
            upsertDownloadRecord(
                episode: episode,
                feedKey: feedKey,
                episodeID: episodeID,
                into: cacheContext
            )
            let transcriptionRecords = episode.url.flatMap {
                transcriptionRecordsByEpisodeURL[$0]
            } ?? []
            upsertTranscriptionRecords(
                transcriptionRecords,
                feedKey: feedKey,
                episodeID: episodeID,
                into: cacheContext
            )
        }

        // Prune cache episodes no longer present in the legacy feed so the cache
        // stays a faithful projection.
        for (episodeID, staleEpisode) in existingByID where seenIDs.contains(episodeID) == false {
            cacheContext.delete(staleEpisode)
        }

        pruneSupplementalRows(
            feedKey: feedKey,
            validEpisodeIDs: seenIDs,
            in: cacheContext
        )
        cached.cacheSchemaVersion = currentCacheSchemaVersion
    }

    private static func upsertChapters(
        _ legacyChapters: [Marker],
        feedKey: String,
        episodeID: String,
        into context: ModelContext
    ) {
        let chapters = legacyChapters.filter { $0.type != .bookmark }
        let existing = fetchCachedChapters(episodeID: episodeID, in: context)
        var existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()

        for (ordinal, chapter) in chapters.enumerated() {
            let fallback = StableIdentityKey.make(
                chapter.type.rawValue,
                String(Int(((chapter.start ?? 0) * 1_000).rounded())),
                chapter.title,
                String(ordinal)
            )
            let sourceID = chapter.uuid?.uuidString ?? fallback
            let id = StableIdentityKey.make(episodeID, sourceID)
            seenIDs.insert(id)
            let cached = existingByID[id]
                ?? {
                    let created = CachedChapter(
                        id: id,
                        feedURL: feedKey,
                        episodeID: episodeID
                    )
                    context.insert(created)
                    existingByID[id] = created
                    return created
                }()
            cached.feedURL = feedKey
            cached.episodeID = episodeID
            cached.sourceUUID = chapter.uuid?.uuidString
            cached.title = chapter.title
            cached.link = chapter.link
            cached.imageURL = chapter.image
            cached.imageData = chapter.imageData
            cached.start = chapter.start
            cached.endTime = chapter.endTime
            cached.duration = chapter.duration
            cached.creationTime = chapter.creationtime
            cached.progress = chapter.progress
            cached.typeRawValue = chapter.type.rawValue
            cached.shouldPlay = chapter.shouldPlay
            cached.ordinal = ordinal
            cached.updatedAt = .now
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func upsertTranscriptLines(
        _ legacyLines: [TranscriptLineAndTime],
        feedKey: String,
        episodeID: String,
        into context: ModelContext
    ) {
        let existing = fetchCachedTranscriptLines(episodeID: episodeID, in: context)
        var existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()

        for (ordinal, line) in legacyLines.enumerated() {
            let sourceID = line.id.uuidString
            let id = StableIdentityKey.make(episodeID, sourceID)
            seenIDs.insert(id)
            let cached = existingByID[id]
                ?? {
                    let created = CachedTranscriptLine(
                        id: id,
                        feedURL: feedKey,
                        episodeID: episodeID
                    )
                    context.insert(created)
                    existingByID[id] = created
                    return created
                }()
            cached.feedURL = feedKey
            cached.episodeID = episodeID
            cached.sourceUUID = sourceID
            cached.speaker = line.speaker
            cached.text = line.text
            cached.startTime = line.startTime
            cached.endTime = line.endTime
            cached.ordinal = ordinal
            cached.updatedAt = .now
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func upsertDownloadRecord(
        episode: Episode,
        feedKey: String,
        episodeID: String,
        into context: ModelContext
    ) {
        var descriptor = FetchDescriptor<CachedDownloadRecord>(
            predicate: #Predicate { $0.id == episodeID }
        )
        descriptor.fetchLimit = 1
        let record = (try? context.fetch(descriptor).first)
            ?? {
                let created = CachedDownloadRecord(
                    id: episodeID,
                    feedURL: feedKey,
                    episodeID: episodeID
                )
                context.insert(created)
                return created
            }()

        let localFileURL = episode.localFile
        let isAvailable = localFileURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let localFileSize = localFileURL.flatMap { url -> Int64? in
            guard isAvailable,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return nil
            }
            return Int64(size)
        }

        record.feedURL = feedKey
        record.episodeID = episodeID
        record.remoteURL = episode.url
        record.localFileURL = localFileURL
        record.isAvailableLocally = isAvailable
        record.fileSize = localFileSize
        record.updatedAt = .now
    }

    private static func upsertTranscriptionRecords(
        _ legacyRecords: [TranscriptionRecord],
        feedKey: String,
        episodeID: String,
        into context: ModelContext
    ) {
        let existing = fetchCachedTranscriptionRecords(episodeID: episodeID, in: context)
        var existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()

        for legacy in legacyRecords {
            let id = legacy.id.uuidString
            seenIDs.insert(id)
            let cached = existingByID[id]
                ?? {
                    let created = CachedTranscriptionRecord(
                        id: id,
                        feedURL: feedKey,
                        episodeID: episodeID
                    )
                    context.insert(created)
                    existingByID[id] = created
                    return created
                }()
            cached.feedURL = feedKey
            cached.episodeID = episodeID
            cached.episodeURL = legacy.episodeURL
            cached.episodeTitle = legacy.episodeTitle
            cached.podcastTitle = legacy.podcastTitle
            cached.localeIdentifier = legacy.localeIdentifier
            cached.startedAt = legacy.startedAt
            cached.finishedAt = legacy.finishedAt
            cached.audioDuration = legacy.audioDuration
            cached.transcriptionDuration = legacy.transcriptionDuration
            cached.updatedAt = .now
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func pruneSupplementalRows(
        feedKey: String,
        validEpisodeIDs: Set<String>,
        in context: ModelContext
    ) {
        for chapter in fetchCachedChapters(feedKey: feedKey, in: context)
            where validEpisodeIDs.contains(chapter.episodeID) == false {
            context.delete(chapter)
        }
        for line in fetchCachedTranscriptLines(feedKey: feedKey, in: context)
            where validEpisodeIDs.contains(line.episodeID) == false {
            context.delete(line)
        }
        for record in fetchCachedTranscriptionRecords(feedKey: feedKey, in: context)
            where validEpisodeIDs.contains(record.episodeID) == false {
            context.delete(record)
        }
        for download in fetchCachedDownloadRecords(feedKey: feedKey, in: context)
            where validEpisodeIDs.contains(download.episodeID) == false {
            context.delete(download)
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

    private static func fetchCachedChapters(
        episodeID: String,
        in context: ModelContext
    ) -> [CachedChapter] {
        let descriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedChapters(
        feedKey: String,
        in context: ModelContext
    ) -> [CachedChapter] {
        let descriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedTranscriptLines(
        episodeID: String,
        in context: ModelContext
    ) -> [CachedTranscriptLine] {
        let descriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedTranscriptLines(
        feedKey: String,
        in context: ModelContext
    ) -> [CachedTranscriptLine] {
        let descriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedTranscriptionRecords(
        episodeID: String,
        in context: ModelContext
    ) -> [CachedTranscriptionRecord] {
        let descriptor = FetchDescriptor<CachedTranscriptionRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedTranscriptionRecords(
        feedKey: String,
        in context: ModelContext
    ) -> [CachedTranscriptionRecord] {
        let descriptor = FetchDescriptor<CachedTranscriptionRecord>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedDownloadRecords(
        feedKey: String,
        in context: ModelContext
    ) -> [CachedDownloadRecord] {
        let descriptor = FetchDescriptor<CachedDownloadRecord>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func transcriptionRecordsByEpisodeURL(
        in context: ModelContext
    ) -> [URL: [TranscriptionRecord]] {
        let records = (try? context.fetch(FetchDescriptor<TranscriptionRecord>())) ?? []
        var recordsByURL: [URL: [TranscriptionRecord]] = [:]
        for record in records {
            guard let episodeURL = record.episodeURL else { continue }
            recordsByURL[episodeURL, default: []].append(record)
        }
        return recordsByURL
    }
}
