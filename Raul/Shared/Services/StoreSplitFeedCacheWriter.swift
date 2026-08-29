import Foundation
import SwiftData

private func |= (lhs: inout Bool, rhs: Bool) {
    lhs = lhs || rhs
}

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
    static let currentCacheSchemaVersion = 4

    struct FeedCacheProjectionResult: Sendable {
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var deleted = 0
        var episodesProcessed = 0
        var episodesUnchanged = 0
        var chaptersProcessed = 0
        var transcriptLinesProcessed = 0
        var transcriptionRecordsProcessed = 0
        var downloadRowsProcessed = 0
        var fetchCount = 0
        var saveCount = 0
        var completed = true
    }

    /// Upserts a single feed's cache rows from the legacy store. Call after a feed
    /// refresh/create has been written to the legacy container.
    @discardableResult
    static func upsertFeed(
        feedURL: URL,
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer,
        deadline: Date? = nil
    ) -> Bool {
        projectFeed(
            feedURL: feedURL,
            legacyContainer: legacyContainer,
            cacheContainer: cacheContainer,
            deadline: deadline
        ).completed
    }

    /// Test/diagnostic entry point. The result deliberately contains aggregate
    /// counts only; production logging should never emit one line per row.
    static func projectFeed(
        feedURL: URL,
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer,
        deadline: Date? = nil
    ) -> FeedCacheProjectionResult {
        var result = FeedCacheProjectionResult()
        guard shouldContinue(deadline: deadline) else {
            result.completed = false
            return result
        }
        let legacyContext = ModelContext(legacyContainer)
        
        let optionalFeedURL: URL? = feedURL
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feed == optionalFeedURL }
        )
        descriptor.fetchLimit = 1
        result.fetchCount += 1
        guard let podcast = try? legacyContext.fetch(descriptor).first,
              shouldContinue(deadline: deadline) else {
            result.completed = false
            return result
        }

        let cacheContext = ModelContext(cacheContainer)
        guard upsert(
            podcast: podcast,
            transcriptionRecordsByEpisodeURL: transcriptionRecordsByEpisodeURL(
                for: podcast,
                in: legacyContext,
                result: &result
            ),
            into: cacheContext,
            deadline: deadline,
            result: &result
        ) else {
            result.completed = false
            return result
        }
        do {
            if cacheContext.hasChanges {
                try cacheContext.save()
                result.saveCount += 1
            }
            return result
        } catch {
            result.completed = false
            return result
        }
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
        var processed = 0
        var offset = 0
        let pageSize = 25
        while processed < limit {
            let legacyContext = ModelContext(legacyContainer)
            let requestedLimit = min(pageSize, max(1, limit - processed))
            var descriptor = FetchDescriptor<Podcast>(
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = requestedLimit
            guard let podcasts = try? legacyContext.fetch(descriptor),
                  podcasts.isEmpty == false else { break }

            for podcast in podcasts {
                guard shouldContinue(deadline: nil), processed < limit else { break }
                guard let feed = podcast.feed else { continue }
                let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
                let lookupContext = ModelContext(cacheContainer)
                if let cached = fetchCachedPodcast(id: feedKey, in: lookupContext),
                   cached.cacheSchemaVersion >= currentCacheSchemaVersion {
                    continue
                }
                // Keep each feed's registered-object graph short-lived. A single
                // context for a large library retains every projected episode and
                // supplemental row until bootstrap finishes.
                let cacheContext = ModelContext(cacheContainer)
                var result = FeedCacheProjectionResult()
                guard upsert(
                    podcast: podcast,
                    transcriptionRecordsByEpisodeURL: transcriptionRecordsByEpisodeURL(
                        for: podcast,
                        in: legacyContext,
                        result: &result
                    ),
                    into: cacheContext,
                    deadline: nil,
                    result: &result
                ) else {
                    return processed
                }
                do {
                    if cacheContext.hasChanges { try cacheContext.save() }
                } catch {
                    return processed
                }
                processed += 1
            }
            offset += podcasts.count
            if podcasts.count < requestedLimit { break }
        }
        return processed
    }

    /// Force-projects the feeds needed to render synchronized playlists before
    /// the generic cache bootstrap. Unlike `bootstrapMissingFeeds`, this does
    /// not skip an already-versioned feed: an older cache may have pruned an
    /// episode that is still protected by a queue or custom-playlist entry.
    @discardableResult
    static func bootstrapPriorityFeeds(
        _ requestedFeeds: [URL],
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer,
        limit: Int = 50
    ) -> Int {
        guard requestedFeeds.isEmpty == false, limit > 0 else { return 0 }
        let legacyContext = ModelContext(legacyContainer)
        let podcasts = (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? []
        var podcastsByComparisonKey: [String: URL] = [:]
        for podcast in podcasts {
            guard let feed = podcast.feed else { continue }
            for key in feed.podcastFeedComparisonKeys {
                podcastsByComparisonKey[key] = feed
            }
        }

        var processed = 0
        var seen = Set<String>()
        for requestedFeed in requestedFeeds where processed < limit {
            let requestedKey = PodcastFeedIdentity.normalizedFeedURLString(requestedFeed)
            guard seen.insert(requestedKey).inserted else { continue }
            let sourceFeed = requestedFeed.podcastFeedComparisonKeys
                .sorted()
                .compactMap { podcastsByComparisonKey[$0] }
                .first ?? requestedFeed
            guard projectFeed(
                feedURL: sourceFeed,
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            ).completed else { continue }
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

    /// Replaces the raw namespace projection only after a complete parse has
    /// succeeded. IDs include the canonical subtree hash, so retries are
    /// idempotent and a changed payload cannot be confused with its predecessor.
    @discardableResult
    static func replaceParsedExtensionElements(
        feedURL: URL,
        parsedFeed: [String: Any],
        cacheContainer: ModelContainer
    ) -> Int {
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let feedElements = parsedFeed["rawExtensionElements"]
            as? [ParsedFeedExtensionElement] ?? []
        let episodeRows: [(EpisodeStableIdentity, [ParsedFeedExtensionElement])] =
            (parsedFeed["episodes"] as? [[String: Any]] ?? []).compactMap { data in
                guard let draft = PodcastEpisodeDraft(episodeData: data) else { return nil }
                let identity = EpisodeStableIdentity.make(
                    feedURL: feedURL,
                    episodeGUID: draft.guid,
                    enclosureURL: draft.episodeURL,
                    episodeURL: draft.episodeURL,
                    linkURL: draft.link,
                    title: draft.title,
                    publishDate: draft.publishDate
                )
                return (identity, draft.extensionElements)
            }

        let context = ModelContext(cacheContainer)
        let descriptor = FetchDescriptor<CachedFeedExtensionElement>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        var existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()
        var written = 0

        func store(
            _ elements: [ParsedFeedExtensionElement],
            scope: String,
            episodeID: String?
        ) {
            var ordinalByName: [String: Int] = [:]
            for element in elements {
                let ordinal = ordinalByName[element.qualifiedName, default: 0]
                ordinalByName[element.qualifiedName] = ordinal + 1
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let payload = try? encoder.encode(element.node) else { continue }
                let hash = AIContentSyncCodec.sha256Hex(payload)
                let candidate = CachedFeedExtensionElement(
                    feedURL: feedKey,
                    episodeID: episodeID,
                    scope: scope,
                    namespaceURI: element.namespaceURI,
                    qualifiedName: element.qualifiedName,
                    localName: element.localName,
                    payload: payload,
                    ordinal: ordinal,
                    contentHash: hash
                )
                seenIDs.insert(candidate.id)
                if let current = existingByID.removeValue(forKey: candidate.id) {
                    current.payload = payload
                    current.contentHash = hash
                    current.updatedAt = .now
                } else {
                    context.insert(candidate)
                }
                written += 1
            }
        }

        store(feedElements, scope: "feed", episodeID: nil)
        for (identity, elements) in episodeRows {
            store(elements, scope: "episode", episodeID: identity.episodeID)
        }
        for stale in existing where seenIDs.contains(stale.id) == false {
            context.delete(stale)
        }

        do {
            if context.hasChanges { try context.save() }
            return written
        } catch {
            context.rollback()
            return 0
        }
    }

    // MARK: - Upsert

    private static func upsert(
        podcast: Podcast,
        transcriptionRecordsByEpisodeURL: [URL: [TranscriptionRecord]],
        into cacheContext: ModelContext,
        deadline: Date?,
        result: inout FeedCacheProjectionResult
    ) -> Bool {
        guard let feed = podcast.feed,
              shouldContinue(deadline: deadline) else {
            return false
        }
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)

        result.fetchCount += 1
        let cached = fetchCachedPodcast(id: feedKey, in: cacheContext)
            ?? {
                let created = CachedPodcast(id: feedKey, feedURL: feedKey)
                cacheContext.insert(created)
                result.inserted += 1
                return created
            }()

        var podcastChanged = false
        podcastChanged |= assignIfChanged(cached, \.feedURL, feedKey)
        podcastChanged |= assignIfChanged(cached, \.title, podcast.title)
        podcastChanged |= assignIfChanged(cached, \.desc, podcast.desc)
        podcastChanged |= assignIfChanged(cached, \.author, podcast.author)
        podcastChanged |= assignIfChanged(cached, \.feed, podcast.feed)
        podcastChanged |= assignIfChanged(cached, \.link, podcast.link)
        podcastChanged |= assignIfChanged(cached, \.language, podcast.language)
        podcastChanged |= assignIfChanged(cached, \.copyright, podcast.copyright)
        podcastChanged |= assignIfChanged(cached, \.imageURL, podcast.imageURL)
        podcastChanged |= assignIfChanged(cached, \.lastBuildDate, podcast.lastBuildDate)
        podcastChanged |= assignIfChanged(cached, \.funding, podcast.funding)
        podcastChanged |= assignIfChanged(cached, \.social, podcast.social)
        podcastChanged |= assignIfChanged(cached, \.people, podcast.people)
        podcastChanged |= assignIfChanged(cached, \.alternativeFeeds, podcast.alternativeFeeds)
        podcastChanged |= assignIfChanged(cached, \.optionalTags, podcast.optionalTags)

        upsertTypedExtensionElements(
            podcast.optionalTags?.allNodes ?? [],
            feedKey: feedKey,
            episodeID: nil,
            scope: "feed",
            into: cacheContext,
            result: &result
        )

        let meta = podcast.metaData
        podcastChanged |= assignIfChanged(cached, \.lastRefresh, meta?.lastRefresh)
        podcastChanged |= assignIfChanged(cached, \.feedUpdated, meta?.feedUpdated)
        podcastChanged |= assignIfChanged(cached, \.feedUpdateCheckDate, meta?.feedUpdateCheckDate)
        podcastChanged |= assignIfChanged(cached, \.consecutiveFeedFailureCount, meta?.consecutiveFeedFailureCount ?? 0)
        podcastChanged |= assignIfChanged(cached, \.lastFeedFailureDate, meta?.lastFeedFailureDate)
        podcastChanged |= assignIfChanged(cached, \.lastFeedFailureStatusCode, meta?.lastFeedFailureStatusCode)
        podcastChanged |= assignIfChanged(cached, \.lastFeedFailureMessage, meta?.lastFeedFailureMessage)
        if podcastChanged { cached.updatedAt = .now; result.updated += 1 }

        // Fetch each related table once per feed. The old implementation fetched
        // chapters, transcript lines, downloads, and transcription records in
        // every episode loop (4N queries); dictionaries make the loop O(1).
        // These feed-scoped fetches also avoid loading unrelated feeds.
        let existingEpisodes = fetchCachedEpisodes(feedKey: feedKey, in: cacheContext)
        result.fetchCount += 1
        let existingChapters = fetchCachedChapters(feedKey: feedKey, in: cacheContext)
        result.fetchCount += 1
        let existingTranscriptLines = fetchCachedTranscriptLines(feedKey: feedKey, in: cacheContext)
        result.fetchCount += 1
        let existingDownloads = fetchCachedDownloadRecords(feedKey: feedKey, in: cacheContext)
        result.fetchCount += 1
        let existingTranscriptions = fetchCachedTranscriptionRecords(feedKey: feedKey, in: cacheContext)
        result.fetchCount += 1
        guard shouldContinue(deadline: deadline) else { return false }

        var existingByID = Dictionary(
            existingEpisodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIDs = Set<String>()
        let chaptersByEpisodeID = Dictionary(grouping: existingChapters) { $0.episodeID }
        let transcriptLinesByEpisodeID = Dictionary(grouping: existingTranscriptLines) { $0.episodeID }
        let downloadsByEpisodeID = Dictionary(existingDownloads.map { ($0.episodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let transcriptionsByEpisodeID = Dictionary(grouping: existingTranscriptions) { $0.episodeID }

        for episode in podcast.episodes ?? [] {
            guard shouldContinue(deadline: deadline) else { return false }
            let identity = episode.stableEpisodeIdentity
            let episodeID = identity.key
            seenIDs.insert(episodeID)

            let cachedEpisode = existingByID[episodeID]
                ?? {
                let created = CachedEpisode(id: episodeID, feedURL: feedKey)
                    cacheContext.insert(created)
                    existingByID[episodeID] = created
                    result.inserted += 1
                    return created
                }()
            var episodeChanged = false
            episodeChanged |= assignIfChanged(cachedEpisode, \.episodeID, identity.episodeID)
            episodeChanged |= assignIfChanged(cachedEpisode, \.feedURL, feedKey)
            episodeChanged |= assignIfChanged(cachedEpisode, \.guid, episode.guid)
            episodeChanged |= assignIfChanged(cachedEpisode, \.title, episode.title)
            episodeChanged |= assignIfChanged(cachedEpisode, \.author, episode.author)
            episodeChanged |= assignIfChanged(cachedEpisode, \.desc, episode.desc)
            episodeChanged |= assignIfChanged(cachedEpisode, \.subtitle, episode.subtitle)
            episodeChanged |= assignIfChanged(cachedEpisode, \.content, episode.content)
            episodeChanged |= assignIfChanged(cachedEpisode, \.publishDate, episode.publishDate)
            episodeChanged |= assignIfChanged(cachedEpisode, \.url, episode.url)
            episodeChanged |= assignIfChanged(cachedEpisode, \.deeplinks, episode.deeplinks)
            episodeChanged |= assignIfChanged(cachedEpisode, \.fileSize, episode.fileSize)
            episodeChanged |= assignIfChanged(cachedEpisode, \.mediaType, episode.mediaType)
            episodeChanged |= assignIfChanged(cachedEpisode, \.link, episode.link)
            episodeChanged |= assignIfChanged(cachedEpisode, \.imageURL, episode.imageURL)
            episodeChanged |= assignIfChanged(cachedEpisode, \.duration, episode.duration)
            episodeChanged |= assignIfChanged(cachedEpisode, \.number, episode.number)
            episodeChanged |= assignIfChanged(cachedEpisode, \.typeRawValue, episode.type?.rawValue)
            episodeChanged |= assignIfChanged(cachedEpisode, \.sourceRawValue, episode.sourceRawValue)
            episodeChanged |= assignIfChanged(cachedEpisode, \.externalFiles, episode.externalFiles)
            episodeChanged |= assignIfChanged(cachedEpisode, \.funding, episode.funding)
            episodeChanged |= assignIfChanged(cachedEpisode, \.social, episode.social)
            episodeChanged |= assignIfChanged(cachedEpisode, \.people, episode.people)
            episodeChanged |= assignIfChanged(cachedEpisode, \.optionalTags, episode.optionalTags)
            episodeChanged |= assignIfChanged(
                cachedEpisode,
                \.localIsInbox,
                episode.metaData?.isInbox == true
            )
            episodeChanged |= assignIfChanged(
                cachedEpisode,
                \.localStatusRawValue,
                episode.metaData?.status?.rawValue
            )
            episodeChanged |= assignIfChanged(
                cachedEpisode,
                \.localSystemSuppressionReasonRawValue,
                episode.metaData?.systemSuppressionReasonRawValue
            )
            upsertTypedExtensionElements(
                episode.optionalTags?.allNodes ?? [],
                feedKey: feedKey,
                episodeID: identity.episodeID,
                scope: "episode",
                into: cacheContext,
                result: &result
            )
            if cachedEpisode.podcast?.persistentModelID != cached.persistentModelID {
                cachedEpisode.podcast = cached
                episodeChanged = true
            }
            if episodeChanged { cachedEpisode.updatedAt = .now; result.updated += 1 }
            else { result.unchanged += 1; result.episodesUnchanged += 1 }
            result.episodesProcessed += 1

            upsertChapters(
                episode.chapters ?? [],
                feedKey: feedKey,
                episodeID: episodeID,
                existing: chaptersByEpisodeID[episodeID] ?? [],
                into: cacheContext,
                result: &result
            )
            let transcriptionRecords = episode.url.flatMap {
                transcriptionRecordsByEpisodeURL[$0]
            } ?? []
            upsertTranscriptLines(
                episode.transcriptLines ?? [],
                feedKey: feedKey,
                episodeID: episodeID,
                source: transcriptionRecords.isEmpty ? .publisher : .localAI,
                existing: transcriptLinesByEpisodeID[episodeID] ?? [],
                into: cacheContext,
                result: &result
            )
            upsertDownloadRecord(
                episode: episode,
                feedKey: feedKey,
                episodeID: episodeID,
                existing: downloadsByEpisodeID[episodeID],
                into: cacheContext,
                result: &result
            )
            upsertTranscriptionRecords(
                transcriptionRecords,
                feedKey: feedKey,
                episodeID: episodeID,
                existing: transcriptionsByEpisodeID[episodeID] ?? [],
                into: cacheContext,
                result: &result
            )
        }

        // Prune cache episodes no longer present in the legacy feed so the cache
        // stays a faithful projection.
        for (episodeID, staleEpisode) in existingByID where seenIDs.contains(episodeID) == false {
            for row in chaptersByEpisodeID[episodeID] ?? [] { cacheContext.delete(row); result.deleted += 1 }
            for row in transcriptLinesByEpisodeID[episodeID] ?? [] { cacheContext.delete(row); result.deleted += 1 }
            for row in transcriptionsByEpisodeID[episodeID] ?? [] { cacheContext.delete(row); result.deleted += 1 }
            if let row = downloadsByEpisodeID[episodeID] { cacheContext.delete(row); result.deleted += 1 }
            cacheContext.delete(staleEpisode)
            result.deleted += 1
            guard shouldContinue(deadline: deadline) else { return false }
        }
        _ = assignIfChanged(cached, \.cacheSchemaVersion, currentCacheSchemaVersion)
        return shouldContinue(deadline: deadline)
    }

    private static func upsertChapters(
        _ legacyChapters: [Marker],
        feedKey: String,
        episodeID: String,
        existing: [CachedChapter],
        into context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) {
        let chapters = legacyChapters.filter { $0.type != .bookmark }
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
                    result.inserted += 1
                    return created
                }()
            var changed = false
            changed |= assignIfChanged(cached, \.feedURL, feedKey)
            changed |= assignIfChanged(cached, \.episodeID, episodeID)
            changed |= assignIfChanged(cached, \.sourceUUID, chapter.uuid?.uuidString)
            changed |= assignIfChanged(cached, \.title, chapter.title)
            changed |= assignIfChanged(cached, \.link, chapter.link)
            changed |= assignIfChanged(cached, \.imageURL, chapter.image)
            changed |= assignIfChanged(cached, \.imageData, chapter.imageData)
            changed |= assignIfChanged(cached, \.start, chapter.start)
            changed |= assignIfChanged(cached, \.endTime, chapter.endTime)
            changed |= assignIfChanged(cached, \.duration, chapter.duration)
            changed |= assignIfChanged(cached, \.creationTime, chapter.creationtime)
            changed |= assignIfChanged(cached, \.progress, chapter.progress)
            changed |= assignIfChanged(cached, \.typeRawValue, chapter.type.rawValue)
            changed |= assignIfChanged(cached, \.shouldPlay, chapter.shouldPlay)
            changed |= assignIfChanged(cached, \.ordinal, ordinal)
            if changed { cached.updatedAt = .now; result.updated += 1 }
            else { result.unchanged += 1 }
            result.chaptersProcessed += 1
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func upsertTypedExtensionElements(
        _ nodes: [NamespaceNode],
        feedKey: String,
        episodeID: String?,
        scope: String,
        into context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) {
        for (ordinal, node) in nodes.enumerated() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let payload = try? encoder.encode(node) else { continue }
            let hash = AIContentSyncCodec.sha256Hex(payload)
            let row = CachedFeedExtensionElement(
                feedURL: feedKey,
                episodeID: episodeID,
                scope: scope,
                namespaceURI: "https://podcastindex.org/namespace/1.0",
                qualifiedName: node.name,
                localName: node.name.split(separator: ":").last.map(String.init) ?? node.name,
                payload: payload,
                ordinal: ordinal,
                contentHash: hash
            )
            let rowID = row.id
            var descriptor = FetchDescriptor<CachedFeedExtensionElement>(
                predicate: #Predicate { $0.id == rowID }
            )
            descriptor.fetchLimit = 1
            result.fetchCount += 1
            if (try? context.fetch(descriptor).first) == nil {
                context.insert(row)
                result.inserted += 1
            }
        }
    }

    private static func upsertTranscriptLines(
        _ legacyLines: [TranscriptLineAndTime],
        feedKey: String,
        episodeID: String,
        source: CachedTranscriptSource,
        existing: [CachedTranscriptLine],
        into context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) {
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
                    result.inserted += 1
                    return created
                }()
            var changed = false
            changed |= assignIfChanged(cached, \.feedURL, feedKey)
            changed |= assignIfChanged(cached, \.episodeID, episodeID)
            changed |= assignIfChanged(cached, \.sourceUUID, sourceID)
            changed |= assignIfChanged(cached, \.speaker, line.speaker)
            changed |= assignIfChanged(cached, \.text, line.text)
            changed |= assignIfChanged(cached, \.startTime, line.startTime)
            changed |= assignIfChanged(cached, \.endTime, line.endTime)
            changed |= assignIfChanged(cached, \.ordinal, ordinal)
            changed |= assignIfChanged(cached, \.sourceRawValue, source.rawValue)
            if changed { cached.updatedAt = .now; result.updated += 1 }
            else { result.unchanged += 1 }
            result.transcriptLinesProcessed += 1
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func upsertDownloadRecord(
        episode: Episode,
        feedKey: String,
        episodeID: String,
        existing: CachedDownloadRecord?,
        into context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) {
        let record = existing
            ?? {
                let created = CachedDownloadRecord(
                    id: episodeID,
                    feedURL: feedKey,
                    episodeID: episodeID
                )
                context.insert(created)
                result.inserted += 1
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

        var changed = false
        changed |= assignIfChanged(record, \.feedURL, feedKey)
        changed |= assignIfChanged(record, \.episodeID, episodeID)
        changed |= assignIfChanged(record, \.remoteURL, episode.url)
        changed |= assignIfChanged(record, \.localFileURL, localFileURL)
        changed |= assignIfChanged(record, \.isAvailableLocally, isAvailable)
        changed |= assignIfChanged(record, \.fileSize, localFileSize)
        if changed { record.updatedAt = .now; result.updated += 1 }
        else { result.unchanged += 1 }
        result.downloadRowsProcessed += 1
    }

    private static func upsertTranscriptionRecords(
        _ legacyRecords: [TranscriptionRecord],
        feedKey: String,
        episodeID: String,
        existing: [CachedTranscriptionRecord],
        into context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) {
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
                    result.inserted += 1
                    return created
                }()
            var changed = false
            changed |= assignIfChanged(cached, \.feedURL, feedKey)
            changed |= assignIfChanged(cached, \.episodeID, episodeID)
            changed |= assignIfChanged(cached, \.episodeURL, legacy.episodeURL)
            changed |= assignIfChanged(cached, \.episodeTitle, legacy.episodeTitle)
            changed |= assignIfChanged(cached, \.podcastTitle, legacy.podcastTitle)
            changed |= assignIfChanged(cached, \.localeIdentifier, legacy.localeIdentifier)
            changed |= assignIfChanged(cached, \.startedAt, legacy.startedAt)
            changed |= assignIfChanged(cached, \.finishedAt, legacy.finishedAt)
            changed |= assignIfChanged(cached, \.audioDuration, legacy.audioDuration)
            changed |= assignIfChanged(cached, \.transcriptionDuration, legacy.transcriptionDuration)
            if changed { cached.updatedAt = .now; result.updated += 1 }
            else { result.unchanged += 1 }
            result.transcriptionRecordsProcessed += 1
        }

        for (id, stale) in existingByID where seenIDs.contains(id) == false {
            context.delete(stale)
        }
    }

    private static func deleteSupplementalRows(
        feedKey: String,
        episodeID: String,
        in context: ModelContext
    ) {
        for chapter in fetchCachedChapters(
            feedKey: feedKey,
            episodeID: episodeID,
            in: context
        ) {
            context.delete(chapter)
        }
        for line in fetchCachedTranscriptLines(
            feedKey: feedKey,
            episodeID: episodeID,
            in: context
        ) {
            context.delete(line)
        }
        for record in fetchCachedTranscriptionRecords(
            feedKey: feedKey,
            episodeID: episodeID,
            in: context
        ) {
            context.delete(record)
        }
        if let download = fetchCachedDownloadRecord(
            feedKey: feedKey,
            episodeID: episodeID,
            in: context
        ) {
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
        feedKey: String,
        in context: ModelContext
    ) -> [CachedChapter] {
        let descriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.feedURL == feedKey }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedChapters(
        feedKey: String,
        episodeID: String,
        in context: ModelContext
    ) -> [CachedChapter] {
        let descriptor = FetchDescriptor<CachedChapter>(
            predicate: #Predicate {
                $0.feedURL == feedKey && $0.episodeID == episodeID
            }
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

    private static func fetchCachedTranscriptLines(
        feedKey: String,
        episodeID: String,
        in context: ModelContext
    ) -> [CachedTranscriptLine] {
        let descriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate {
                $0.feedURL == feedKey && $0.episodeID == episodeID
            }
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

    private static func fetchCachedTranscriptionRecords(
        feedKey: String,
        episodeID: String,
        in context: ModelContext
    ) -> [CachedTranscriptionRecord] {
        let descriptor = FetchDescriptor<CachedTranscriptionRecord>(
            predicate: #Predicate {
                $0.feedURL == feedKey && $0.episodeID == episodeID
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchCachedDownloadRecord(
        feedKey: String,
        episodeID: String,
        in context: ModelContext
    ) -> CachedDownloadRecord? {
        var descriptor = FetchDescriptor<CachedDownloadRecord>(
            predicate: #Predicate {
                $0.feedURL == feedKey && $0.episodeID == episodeID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
        for podcast: Podcast,
        in context: ModelContext,
        result: inout FeedCacheProjectionResult
    ) -> [URL: [TranscriptionRecord]] {
        let episodeURLs = Set((podcast.episodes ?? []).compactMap(\.url))
        guard episodeURLs.isEmpty == false else { return [:] }
        // TranscriptionRecord currently has no feed/episode relationship or
        // feed-key column. SwiftData cannot reliably compile a dynamic OR
        // predicate over optional URLs, so keep this as one table fetch and
        // discard unrelated records immediately. This is still bounded to one
        // fetch per feed (never one fetch per episode); adding a feed key later
        // can make this genuinely store-scoped without changing the projection.
        let descriptor = FetchDescriptor<TranscriptionRecord>()
        result.fetchCount += 1
        let records = (try? context.fetch(descriptor))?.filter {
            guard let episodeURL = $0.episodeURL else { return false }
            return episodeURLs.contains(episodeURL)
        } ?? []
        var recordsByURL: [URL: [TranscriptionRecord]] = [:]
        for record in records {
            guard let episodeURL = record.episodeURL else { continue }
            recordsByURL[episodeURL, default: []].append(record)
        }
        return recordsByURL
    }

    private static func assignIfChanged<Root, Value: Equatable>(
        _ object: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard object[keyPath: keyPath] != value else { return false }
        object[keyPath: keyPath] = value
        return true
    }

    private static func shouldContinue(deadline: Date?) -> Bool {
        let isCancelled = withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
        guard isCancelled == false else { return false }
        guard let deadline else { return true }
        return Date() < deadline
    }
}
