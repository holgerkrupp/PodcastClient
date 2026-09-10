//
//  PodcastSchemaEntities.swift
//  PlayerIntentsExtension
//
//  Apple Intelligence audio-domain schema entities. They mirror EpisodeEntity
//  and PodcastEntity rather than replacing them: the schemas are iOS 27-only,
//  and the macro would make those entities (and the intents that take them)
//  unavailable on iOS 26.
//

import AppIntents
import Foundation

// MARK: - Show

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct PodcastShowSchemaEntity {
    static let defaultQuery = PodcastShowSchemaEntityQuery()

    /// The podcast's feed URL, which is the same on every device.
    let id: String

    var title: String
    var showDescription: String?
    var imageURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            image: imageURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init?(podcast: Podcast) {
        guard let feed = podcast.feed else { return nil }
        id = feed.absoluteString
        title = podcast.title
        showDescription = podcast.desc
        imageURL = podcast.imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PodcastShowSchemaEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
struct PodcastShowSchemaEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PodcastShowSchemaEntity.ID]) async throws -> [PodcastShowSchemaEntity] {
        try await LibraryEntityLookup.podcasts(withFeedStrings: identifiers).compactMap(PodcastShowSchemaEntity.init(podcast:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PodcastShowSchemaEntity] {
        try await LibraryEntityLookup.subscribedPodcasts(matching: string).compactMap(PodcastShowSchemaEntity.init(podcast:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PodcastShowSchemaEntity] {
        try await LibraryEntityLookup.subscribedPodcasts().compactMap(PodcastShowSchemaEntity.init(podcast:))
    }
}

// MARK: - Episode

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct PodcastEpisodeSchemaEntity {
    static let defaultQuery = PodcastEpisodeSchemaEntityQuery()

    /// The episode's audio URL. Every device keys the episode by this URL.
    let id: String

    var title: String
    var showName: String?
    var show: PodcastShowSchemaEntity?
    var releaseDate: Date?
    var duration: Double?
    var imageURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: showName.map { "\($0)" },
            image: imageURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init?(episode: Episode) {
        guard let url = episode.url else { return nil }
        id = url.absoluteString
        title = episode.title
        showName = episode.podcast?.title
        show = episode.podcast.flatMap(PodcastShowSchemaEntity.init(podcast:))
        releaseDate = episode.publishDate
        duration = episode.duration
        imageURL = episode.imageURL ?? episode.podcast?.imageURL
    }

    /// Built from the lightweight queue summary, which has no show record,
    /// release date or duration.
    init?(summary: EpisodeSummary) {
        guard let url = summary.url, let title = summary.title, title.isEmpty == false else { return nil }
        id = url.absoluteString
        self.title = title
        showName = summary.podcast
        show = nil
        releaseDate = nil
        duration = nil
        imageURL = summary.cover ?? summary.podcastCover
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PodcastEpisodeSchemaEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
struct PodcastEpisodeSchemaEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PodcastEpisodeSchemaEntity.ID]) async throws -> [PodcastEpisodeSchemaEntity] {
        try await LibraryEntityLookup.episodes(withURLStrings: identifiers).compactMap(PodcastEpisodeSchemaEntity.init(episode:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PodcastEpisodeSchemaEntity] {
        try await LibraryEntityLookup.episodes(matching: string).compactMap(PodcastEpisodeSchemaEntity.init(episode:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PodcastEpisodeSchemaEntity] {
        try await LibraryEntityLookup.upNextEpisodes().compactMap(PodcastEpisodeSchemaEntity.init(episode:))
    }
}

// MARK: - Relevant entities

/// Offers the Up Next queue to Apple Intelligence as candidates for
/// now-playing suggestions, such as during a workout. Uses the schema entity
/// so the system knows these are podcast episodes.
@available(iOS 27.0, macOS 27.0, *)
actor UpNextRelevantEntitiesPublisher {
    static let shared = UpNextRelevantEntitiesPublisher()

    private var publishedIDs: [String]?

    func publish(_ episodes: [EpisodeSummary]) async {
        let entities = episodes.compactMap(PodcastEpisodeSchemaEntity.init(summary:))
        let ids = entities.map(\.id)
        guard ids != publishedIDs else { return }
        publishedIDs = ids

        do {
            if entities.isEmpty {
                try await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
            } else {
                try await RelevantEntities.shared.updateEntities(entities, for: .audio(.nowPlaying))
            }
        } catch {
            publishedIDs = nil
        }
    }
}
