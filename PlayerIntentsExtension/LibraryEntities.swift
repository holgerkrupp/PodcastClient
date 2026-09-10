//
//  LibraryEntities.swift
//  PlayerIntentsExtension
//
//  App entities for library content, and the intents that act on them.
//

import AppIntents
import Foundation
import SwiftData

// MARK: - Episode

struct EpisodeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = EpisodeEntityQuery()

    /// The episode's audio URL. Every device keys the episode by this URL,
    /// so the identifier is the same across the user's devices.
    let id: String
    let title: String
    let podcastTitle: String?
    let imageURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: podcastTitle.map { "\($0)" },
            image: imageURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init?(episode: Episode) {
        guard let url = episode.url else { return nil }
        id = url.absoluteString
        title = episode.title
        podcastTitle = episode.podcast?.title
        imageURL = episode.imageURL ?? episode.podcast?.imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EpisodeEntity: SyncableEntity {}

struct EpisodeEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [EpisodeEntity.ID]) async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.episodes(withURLStrings: identifiers).compactMap(EpisodeEntity.init(episode:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.episodes(matching: string).compactMap(EpisodeEntity.init(episode:))
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.upNextEpisodes().compactMap(EpisodeEntity.init(episode:))
    }
}

// MARK: - Podcast

struct PodcastEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static let defaultQuery = PodcastEntityQuery()

    /// The podcast's feed URL, which is the same on every device.
    let id: String
    let title: String
    let author: String?
    let imageURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.map { "\($0)" },
            image: imageURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init?(podcast: Podcast) {
        guard let feed = podcast.feed else { return nil }
        id = feed.absoluteString
        title = podcast.title
        author = podcast.author
        imageURL = podcast.imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PodcastEntity: SyncableEntity {}

struct PodcastEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PodcastEntity.ID]) async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.podcasts(withFeedStrings: identifiers).compactMap(PodcastEntity.init(podcast:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.subscribedPodcasts(matching: string).compactMap(PodcastEntity.init(podcast:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.subscribedPodcasts().compactMap(PodcastEntity.init(podcast:))
    }
}

// MARK: - Lookup

/// Library fetches shared by the entity queries here and the iOS 27 schema
/// entity queries in PodcastSchemaEntities.swift.
@MainActor
enum LibraryEntityLookup {
    private static let resultLimit = 25

    static func episodes(withURLStrings identifiers: [String]) async throws -> [Episode] {
        let context = try await preparedIntentModelContainer().mainContext
        return identifiers.compactMap { identifier in
            guard let url = URL(string: identifier) else { return nil }
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == url })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
    }

    static func episodes(matching string: String) async throws -> [Episode] {
        let context = try await preparedIntentModelContainer().mainContext
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.title.localizedStandardContains(string)
                    || episode.podcast?.title.localizedStandardContains(string) == true
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = resultLimit
        return try context.fetch(descriptor)
    }

    /// The Up Next queue, which is what people act on most.
    static func upNextEpisodes() async throws -> [Episode] {
        guard let playlistActor = Player.shared.playlistActor else { return [] }
        let urls = (try? await playlistActor.orderedEpisodeURLs()) ?? []
        return try await episodes(withURLStrings: urls.prefix(resultLimit).map(\.absoluteString))
    }

    static func latestEpisode(ofFeedString feedString: String) async throws -> Episode? {
        guard let feed = URL(string: feedString) else { return nil }
        let context = try await preparedIntentModelContainer().mainContext
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.feed == feed },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func podcasts(withFeedStrings identifiers: [String]) async throws -> [Podcast] {
        let context = try await preparedIntentModelContainer().mainContext
        return identifiers.compactMap { identifier in
            guard let feed = URL(string: identifier) else { return nil }
            var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feed == feed })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
    }

    static func subscribedPodcasts(matching string: String? = nil) async throws -> [Podcast] {
        let context = try await preparedIntentModelContainer().mainContext
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.metaData?.isSubscribed != false },
            sortBy: [SortDescriptor(\.title)]
        )
        let podcasts = try context.fetch(descriptor)
        guard let string else { return podcasts }
        return podcasts.filter { $0.title.localizedStandardContains(string) }
    }
}

// MARK: - Intents

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode"
    static let description = IntentDescription("Play an episode from your library.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$episode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: episode.id) else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }
        await Player.shared.playEpisode(url, playDirectly: true)
        return .result()
    }
}

struct PlayLatestEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Latest Episode"
    static let description = IntentDescription("Play the newest episode of a podcast.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Podcast", requestValueDialog: "Which podcast?")
    var podcast: PodcastEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play the latest episode of \(\.$podcast)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let episode = try await LibraryEntityLookup.latestEpisode(ofFeedString: podcast.id) else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }
        guard let episodeURL = episode.url else {
            throw PlayPodcastEpisodeError.episodeHasNoAudio
        }

        await Player.shared.playEpisode(episodeURL, playDirectly: true)
        return .result(dialog: "Playing \(episode.title).")
    }
}

enum UpNextQueuePosition: String, AppEnum {
    case front
    case end

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Queue Position")
    static let caseDisplayRepresentations: [UpNextQueuePosition: DisplayRepresentation] = [
        .front: "Play Next",
        .end: "Play Last"
    ]

    var playlistPosition: Playlist.Position {
        switch self {
        case .front:
            return .front
        case .end:
            return .end
        }
    }
}

/// Takes an `EntityCollection`, so picking a whole podcast's back catalogue
/// passes identifiers only; nothing is resolved until the intent runs.
@available(iOS 27.0, macOS 27.0, *)
struct AddEpisodesToUpNextIntent: UndoableIntent {
    static let title: LocalizedStringResource = "Add Episodes to Up Next"
    static let description = IntentDescription("Add one or more episodes to your Up Next queue.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episodes")
    var episodes: EntityCollection<EpisodeEntity>

    @Parameter(title: "Position", default: .end)
    var position: UpNextQueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$episodes) to Up Next") {
            \.$position
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let playlistActor = Player.shared.playlistActor else {
            throw AppIntentError(description: "Up Next is unavailable.")
        }

        let urls = episodes.compactMap { URL(string: $0) }
        let alreadyQueued = Set(try await playlistActor.orderedEpisodeURLs())
        // Each front insertion lands ahead of the previous one, so insert in
        // reverse to keep the order the episodes were given in.
        let insertionOrder = position == .front ? Array(urls.reversed()) : urls
        for url in insertionOrder {
            try await playlistActor.add(episodeURL: url, to: position.playlistPosition)
        }

        // Undo only removes what this run added; episodes that were already
        // queued stay where they now are.
        let newlyQueued = urls.filter { alreadyQueued.contains($0) == false }
        undoManager?.registerUndo(withTarget: Player.shared) { _ in
            Task {
                for url in newlyQueued {
                    try? await playlistActor.remove(episodeURL: url)
                }
            }
        }

        return .result(dialog: "Added \(urls.count) episodes to Up Next.")
    }
}
