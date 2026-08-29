import Foundation
import SwiftData

struct EpisodeStateSnapshot: Equatable, Sendable {
    var playPosition = 0.0
    var maxPlayPosition = 0.0
    var duration: Double?
    var isPlayed = false
    var isArchived = false
    var wasSkipped = false
    var completedAt: Date?
    var archivedAt: Date?
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?
    var updatedAt = Date.distantPast
}

struct CachedChapterSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let link: URL?
    let imageURL: URL?
    let imageData: Data?
    let start: Double?
    let endTime: Double?
    let duration: Double?
    let typeRawValue: String
    let shouldPlay: Bool
    let ordinal: Int
}

struct CachedTranscriptLineSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let speaker: String?
    let text: String
    let startTime: Double
    let endTime: Double?
    let sourceRawValue: String
    let revisionID: String?
    let ordinal: Int
}

struct CachedExtensionElementSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let namespaceURI: String
    let qualifiedName: String
    let localName: String
    let payload: Data
    let ordinal: Int
    let contentHash: String
}

struct EpisodeSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let identity: EpisodeStableIdentity
    let title: String
    let author: String?
    let description: String?
    let subtitle: String?
    let content: String?
    let publishDate: Date?
    let mediaURL: URL?
    let link: URL?
    let imageURL: URL?
    let duration: Double?
    let mediaType: String?
    let state: EpisodeStateSnapshot
    let chapters: [CachedChapterSnapshot]
    let transcript: [CachedTranscriptLineSnapshot]
    let extensionElements: [CachedExtensionElementSnapshot]
}

struct PodcastSnapshot: Equatable, Sendable, Identifiable {
    var id: String { feedURL }
    let feedURL: String
    let title: String
    let description: String?
    let author: String?
    let link: URL?
    let language: String?
    let copyright: String?
    let imageURL: URL?
    let lastBuildDate: Date?
    let isSubscribed: Bool
    let subscribedAt: Date?
    let updatedAt: Date
}

struct PlaylistSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let sortIndex: Int
    let kindRawValue: String
    let smartFilterRawValue: String?
    let isHidden: Bool
    let entries: [PlaylistEntrySnapshot]
}

struct PlaylistEntrySnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let playlistID: String
    let identity: EpisodeStableIdentity
    let sortIndex: Int
    let addedAt: Date
    let updatedAt: Date
}

struct BookmarkSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let identity: EpisodeStableIdentity
    let time: Double
    let title: String?
    let note: String?
    let createdAt: Date
    let updatedAt: Date
}

/// Store-independent read surface. Every API returns immutable Sendable values;
/// SwiftData model instances and PersistentIdentifier values remain inside the
/// repository actor. Cache metadata and UserState overlays are fetched in
/// batches and joined only by stable logical keys.
actor PodcastCacheRepository {
    private let cacheContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let legacyContainer: ModelContainer?
    private let allowsLegacyFallback: Bool

    init(
        cacheContainer: ModelContainer,
        userStateContainer: ModelContainer,
        legacyContainer: ModelContainer? = nil,
        allowsLegacyFallback: Bool = false
    ) {
        self.cacheContainer = cacheContainer
        self.userStateContainer = userStateContainer
        self.legacyContainer = legacyContainer
        self.allowsLegacyFallback = allowsLegacyFallback
    }

    func podcasts(limit: Int = 500, offset: Int = 0) -> [PodcastSnapshot] {
        let cache = ModelContext(cacheContainer)
        var descriptor = FetchDescriptor<CachedPodcast>(
            sortBy: [SortDescriptor(\CachedPodcast.title)]
        )
        descriptor.fetchLimit = max(1, limit)
        descriptor.fetchOffset = max(0, offset)
        let cached = (try? cache.fetch(descriptor)) ?? []
        if cached.isEmpty, allowsLegacyFallback {
            return legacyPodcasts(limit: limit, offset: offset)
        }

        let aliases = aliasMap(in: cache)
        let requestedSubscriptionKeys = Set(cached.flatMap {
            equivalentFeedKeys(for: $0.feedURL, aliases: aliases)
        })
        let subscriptions = newestSubscriptions(feedKeys: requestedSubscriptionKeys)
        return cached.compactMap { podcast in
            let keys = equivalentFeedKeys(for: podcast.feedURL, aliases: aliases)
            let subscription = keys.compactMap { subscriptions[$0] }
                .max(by: syncRecordIsOlder)
            guard subscription?.isSubscribed != false else { return nil }
            return PodcastSnapshot(
                feedURL: podcast.feedURL,
                title: podcast.title,
                description: podcast.desc,
                author: podcast.author,
                link: podcast.link,
                language: podcast.language,
                copyright: podcast.copyright,
                imageURL: podcast.imageURL,
                lastBuildDate: podcast.lastBuildDate,
                isSubscribed: subscription?.isSubscribed ?? false,
                subscribedAt: subscription?.subscribedAt,
                updatedAt: max(podcast.updatedAt, subscription?.updatedAt ?? .distantPast)
            )
        }
    }

    func episodes(
        feedURL: URL,
        limit: Int = 500,
        offset: Int = 0
    ) -> [EpisodeSnapshot] {
        let requestedKey = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let cache = ModelContext(cacheContainer)
        let aliases = aliasMap(in: cache)
        let keys = equivalentFeedKeys(for: requestedKey, aliases: aliases)
        var all: [CachedEpisode] = []
        for key in keys {
            var descriptor = FetchDescriptor<CachedEpisode>(
                predicate: #Predicate { $0.feedURL == key },
                sortBy: [SortDescriptor(\CachedEpisode.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = max(1, limit)
            descriptor.fetchOffset = max(0, offset)
            all.append(contentsOf: (try? cache.fetch(descriptor)) ?? [])
        }
        if all.isEmpty, allowsLegacyFallback {
            return legacyEpisodes(feedKeys: keys, limit: limit, offset: offset)
        }
        let state = newestEpisodeStates(feedKeys: keys)
        return all.prefix(limit).map { makeEpisodeSnapshot($0, state: state[$0.id], cache: cache) }
    }

    func episode(identity: EpisodeStableIdentity) -> EpisodeSnapshot? {
        let cache = ModelContext(cacheContainer)
        let aliases = aliasMap(in: cache)
        let feedKeys = equivalentFeedKeys(for: identity.feedURL, aliases: aliases)
        let state = newestEpisodeStates(feedKeys: feedKeys)
        for feedKey in feedKeys {
            let identityKey = StableIdentityKey.make(feedKey, identity.episodeID)
            var descriptor = FetchDescriptor<CachedEpisode>(
                predicate: #Predicate { $0.id == identityKey }
            )
            descriptor.fetchLimit = 1
            if let episode = try? cache.fetch(descriptor).first {
                return makeEpisodeSnapshot(
                    episode,
                    state: state[episode.id],
                    cache: cache
                )
            }
        }
        guard allowsLegacyFallback else { return nil }
        return legacyEpisode(identity: identity)
    }

    func playlists() -> [PlaylistSnapshot] {
        let context = ModelContext(userStateContainer)
        let playlists = newestByID(
            fetchAllBatched(PlaylistSync.self, in: context),
            id: \PlaylistSync.id,
            updatedAt: \PlaylistSync.updatedAt,
            tieBreaker: { $0.sourceDeviceID ?? "" }
        ).values.filter { !$0.isDeleted && $0.deletedAt == nil }
        let entries = newestByID(
            fetchAllBatched(PlaylistEntrySync.self, in: context),
            id: \PlaylistEntrySync.id,
            updatedAt: \PlaylistEntrySync.updatedAt,
            tieBreaker: { $0.sourceDeviceID ?? "" }
        ).values.filter { !$0.isDeleted && $0.deletedAt == nil }
        let byPlaylist = Dictionary(grouping: entries, by: \.playlistID)
        return playlists.sorted {
            ($0.sortIndex, $0.title, $0.id) < ($1.sortIndex, $1.title, $1.id)
        }.map { playlist in
            let values = (byPlaylist[playlist.id] ?? []).map {
                PlaylistEntrySnapshot(
                    id: $0.id,
                    playlistID: $0.playlistID,
                    identity: EpisodeStableIdentity(
                        feedURL: $0.feedURL,
                        episodeID: $0.episodeID
                    ),
                    sortIndex: $0.sortIndex,
                    addedAt: $0.addedAt,
                    updatedAt: $0.updatedAt
                )
            }.sorted { ($0.sortIndex, $0.updatedAt, $0.id) < ($1.sortIndex, $1.updatedAt, $1.id) }
            return PlaylistSnapshot(
                id: playlist.id,
                title: playlist.title,
                symbolName: playlist.symbolName,
                sortIndex: playlist.sortIndex,
                kindRawValue: playlist.kindRawValue,
                smartFilterRawValue: playlist.smartFilterRawValue,
                isHidden: playlist.isHidden,
                entries: values
            )
        }
    }

    func bookmarks() -> [BookmarkSnapshot] {
        let context = ModelContext(userStateContainer)
        return newestByID(
            fetchAllBatched(BookmarkSync.self, in: context),
            id: \BookmarkSync.id,
            updatedAt: \BookmarkSync.updatedAt,
            tieBreaker: { $0.sourceDeviceID ?? "" }
        ).values.filter { !$0.isDeleted && $0.deletedAt == nil }.map {
            BookmarkSnapshot(
                id: $0.id,
                identity: EpisodeStableIdentity(feedURL: $0.feedURL, episodeID: $0.episodeID),
                time: $0.time,
                title: $0.title,
                note: $0.note,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    private func makeEpisodeSnapshot(
        _ episode: CachedEpisode,
        state record: EpisodeStateSync?,
        cache: ModelContext
    ) -> EpisodeSnapshot {
        let rowID = episode.id
        let feedURL = episode.feedURL
        let chapters = ((try? cache.fetch(FetchDescriptor<CachedChapter>(
            predicate: #Predicate { $0.episodeID == rowID }
        ))) ?? []).map {
            CachedChapterSnapshot(
                id: $0.id, title: $0.title, link: $0.link,
                imageURL: $0.imageURL, imageData: $0.imageData,
                start: $0.start, endTime: $0.endTime, duration: $0.duration,
                typeRawValue: $0.typeRawValue, shouldPlay: $0.shouldPlay,
                ordinal: $0.ordinal
            )
        }.sorted { $0.ordinal < $1.ordinal }
        let transcript = ((try? cache.fetch(FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate { $0.episodeID == rowID }
        ))) ?? []).map {
            CachedTranscriptLineSnapshot(
                id: $0.id, speaker: $0.speaker, text: $0.text,
                startTime: $0.startTime, endTime: $0.endTime,
                sourceRawValue: $0.sourceRawValue, revisionID: $0.revisionID,
                ordinal: $0.ordinal
            )
        }.sorted { $0.ordinal < $1.ordinal }
        let stableEpisodeID = episode.episodeID.isEmpty
            ? StableIdentityKey.components(from: episode.id)?.last ?? episode.id
            : episode.episodeID
        let extensions = ((try? cache.fetch(FetchDescriptor<CachedFeedExtensionElement>(
            predicate: #Predicate {
                $0.feedURL == feedURL && $0.episodeID == stableEpisodeID
            }
        ))) ?? []).map {
            CachedExtensionElementSnapshot(
                id: $0.id, namespaceURI: $0.namespaceURI,
                qualifiedName: $0.qualifiedName, localName: $0.localName,
                payload: $0.payload, ordinal: $0.ordinal,
                contentHash: $0.contentHash
            )
        }
        let state = record.map {
            EpisodeStateSnapshot(
                playPosition: $0.playPosition,
                maxPlayPosition: $0.maxPlayPosition,
                duration: $0.duration,
                isPlayed: $0.isPlayed,
                isArchived: $0.isArchived,
                wasSkipped: $0.wasSkipped,
                completedAt: $0.completedAt,
                archivedAt: $0.archivedAt,
                firstPlayedAt: $0.firstPlayedAt,
                lastPlayedAt: $0.lastPlayedAt,
                updatedAt: $0.updatedAt
            )
        } ?? EpisodeStateSnapshot()
        return EpisodeSnapshot(
            id: episode.id,
            identity: EpisodeStableIdentity(feedURL: episode.feedURL, episodeID: stableEpisodeID),
            title: episode.title, author: episode.author,
            description: episode.desc, subtitle: episode.subtitle,
            content: episode.content, publishDate: episode.publishDate,
            mediaURL: episode.url, link: episode.link, imageURL: episode.imageURL,
            duration: episode.duration, mediaType: episode.mediaType,
            state: state, chapters: chapters, transcript: transcript,
            extensionElements: extensions
        )
    }

    private func newestSubscriptions(
        feedKeys: Set<String>
    ) -> [String: SubscriptionSync] {
        let context = ModelContext(userStateContainer)
        var records: [SubscriptionSync] = []
        for key in feedKeys {
            var descriptor = FetchDescriptor<SubscriptionSync>(
                predicate: #Predicate { $0.feedURL == key }
            )
            descriptor.fetchLimit = 10
            records.append(contentsOf: (try? context.fetch(descriptor)) ?? [])
        }
        return newestByID(
            records,
            id: \SubscriptionSync.id,
            updatedAt: \SubscriptionSync.updatedAt,
            tieBreaker: { $0.sourceDeviceID ?? "" }
        )
    }

    private func newestEpisodeStates(feedKeys: Set<String>) -> [String: EpisodeStateSync] {
        let context = ModelContext(userStateContainer)
        var records: [EpisodeStateSync] = []
        for key in feedKeys {
            let descriptor = FetchDescriptor<EpisodeStateSync>(
                predicate: #Predicate { $0.feedURL == key }
            )
            records.append(contentsOf: (try? context.fetch(descriptor)) ?? [])
        }
        let byEpisodeID = newestByID(
            records,
            id: \EpisodeStateSync.episodeID,
            updatedAt: \EpisodeStateSync.updatedAt,
            tieBreaker: { $0.sourceDeviceID ?? "" }
        )
        var result: [String: EpisodeStateSync] = [:]
        for record in byEpisodeID.values {
            for feedKey in feedKeys {
                result[StableIdentityKey.make(feedKey, record.episodeID)] = record
            }
        }
        return result
    }

    private func aliasMap(in context: ModelContext) -> [String: String] {
        let aliases = fetchAllBatched(FeedAlias.self, in: context)
        return newestByID(
            aliases,
            id: \FeedAlias.id,
            updatedAt: \FeedAlias.updatedAt,
            tieBreaker: { $0.newFeedURL }
        ).values.reduce(into: [:]) { $0[$1.oldFeedURL] = $1.newFeedURL }
    }

    private func equivalentFeedKeys(
        for feedURL: String,
        aliases: [String: String]
    ) -> Set<String> {
        var result: Set<String> = [feedURL]
        var changed = true
        while changed {
            changed = false
            for (old, new) in aliases where result.contains(old) || result.contains(new) {
                changed = result.insert(old).inserted || changed
                changed = result.insert(new).inserted || changed
            }
        }
        return result
    }

    private func newestByID<Model, ID: Hashable>(
        _ records: [Model],
        id: KeyPath<Model, ID>,
        updatedAt: KeyPath<Model, Date>,
        tieBreaker: (Model) -> String
    ) -> [ID: Model] {
        records.reduce(into: [:]) { result, record in
            let key = record[keyPath: id]
            guard let current = result[key] else {
                result[key] = record
                return
            }
            let currentDate = current[keyPath: updatedAt]
            let incomingDate = record[keyPath: updatedAt]
            if incomingDate > currentDate
                || (incomingDate == currentDate && tieBreaker(record) > tieBreaker(current)) {
                result[key] = record
            }
        }
    }

    private func fetchAllBatched<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext,
        pageSize: Int = 200
    ) -> [Model] {
        var values: [Model] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Model>()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }
            values.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }
        return values
    }

    private func syncRecordIsOlder(_ lhs: SubscriptionSync, _ rhs: SubscriptionSync) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return (lhs.sourceDeviceID ?? "") < (rhs.sourceDeviceID ?? "")
    }

    private func legacyPodcasts(limit: Int, offset: Int) -> [PodcastSnapshot] {
        guard let legacyContainer else { return [] }
        let context = ModelContext(legacyContainer)
        var descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\Podcast.title)])
        descriptor.fetchLimit = max(1, limit)
        descriptor.fetchOffset = max(0, offset)
        return ((try? context.fetch(descriptor)) ?? []).compactMap { podcast in
            guard let feed = podcast.feed else { return nil }
            return PodcastSnapshot(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
                title: podcast.title, description: podcast.desc,
                author: podcast.author, link: podcast.link,
                language: podcast.language, copyright: podcast.copyright,
                imageURL: podcast.imageURL, lastBuildDate: podcast.lastBuildDate,
                isSubscribed: podcast.metaData?.isSubscribed != false,
                subscribedAt: podcast.metaData?.subscriptionDate,
                updatedAt: podcast.metaData?.subscriptionDate ?? .distantPast
            )
        }
    }

    private func legacyEpisodes(
        feedKeys: Set<String>, limit: Int, offset: Int
    ) -> [EpisodeSnapshot] {
        guard let legacyContainer else { return [] }
        let context = ModelContext(legacyContainer)
        var descriptor = FetchDescriptor<Episode>(
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        descriptor.fetchOffset = max(0, offset)
        return ((try? context.fetch(descriptor)) ?? []).filter {
            feedKeys.contains($0.stableEpisodeIdentity.feedURL)
        }.map { legacySnapshot($0) }
    }

    private func legacyEpisode(identity: EpisodeStableIdentity) -> EpisodeSnapshot? {
        guard let legacyContainer else { return nil }
        let context = ModelContext(legacyContainer)
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Episode>()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = 100
            let page = (try? context.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { return nil }
            if let episode = page.first(where: { $0.stableEpisodeIdentity == identity }) {
                return legacySnapshot(episode)
            }
            offset += page.count
        }
    }

    private func legacySnapshot(_ episode: Episode) -> EpisodeSnapshot {
        let identity = episode.stableEpisodeIdentity
        let metadata = episode.metaData
        return EpisodeSnapshot(
            id: identity.key, identity: identity, title: episode.title,
            author: episode.author, description: episode.desc,
            subtitle: episode.subtitle, content: episode.content,
            publishDate: episode.publishDate, mediaURL: episode.url,
            link: episode.link, imageURL: episode.imageURL,
            duration: episode.duration, mediaType: episode.mediaType,
            state: EpisodeStateSnapshot(
                playPosition: metadata?.playPosition ?? 0,
                maxPlayPosition: metadata?.maxPlayposition ?? 0,
                duration: episode.duration,
                isPlayed: metadata?.isHistory == true || metadata?.status == .history,
                isArchived: metadata?.isArchived == true || metadata?.status == .archived,
                wasSkipped: metadata?.wasSkipped ?? false,
                completedAt: metadata?.completionDate,
                archivedAt: metadata?.archivedAt,
                firstPlayedAt: metadata?.firstListenDate,
                lastPlayedAt: metadata?.lastPlayed,
                updatedAt: metadata?.lastPlayed ?? .distantPast
            ),
            chapters: [], transcript: [], extensionElements: []
        )
    }
}
