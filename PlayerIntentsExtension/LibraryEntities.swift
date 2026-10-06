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

    init(snapshot: IntentEpisodeSnapshot) {
        id = snapshot.id
        title = snapshot.title
        podcastTitle = snapshot.podcastTitle
        imageURL = snapshot.imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension EpisodeEntity: SyncableEntity {}

struct EpisodeEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [EpisodeEntity.ID]) async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.episodes(withURLStrings: identifiers).map(EpisodeEntity.init(snapshot:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.episodes(matching: string).map(EpisodeEntity.init(snapshot:))
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        try await LibraryEntityLookup.upNextEpisodes().map(EpisodeEntity.init(snapshot:))
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

    init(snapshot: IntentPodcastSnapshot) {
        id = snapshot.id
        title = snapshot.title
        author = snapshot.author
        imageURL = snapshot.imageURL
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PodcastEntity: SyncableEntity {}

struct PodcastEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PodcastEntity.ID]) async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.podcasts(withFeedStrings: identifiers).map(PodcastEntity.init(snapshot:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.subscribedPodcasts(matching: string).map(PodcastEntity.init(snapshot:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PodcastEntity] {
        try await LibraryEntityLookup.subscribedPodcasts().map(PodcastEntity.init(snapshot:))
    }
}

// MARK: - Lookup

/// Value data extracted inside `AppIntentLibraryQueryActor`. App Intents must
/// never carry SwiftData models beyond the context that fetched them.
struct IntentEpisodeSnapshot: Sendable, Hashable {
    let id: String
    let title: String
    let podcastTitle: String?
    let podcastFeedID: String?
    let podcastDescription: String?
    let imageURL: URL?
    let publishDate: Date?
    let duration: Double?
    let isDownloadable: Bool
}

struct IntentPodcastSnapshot: Sendable, Hashable {
    let id: String
    let title: String
    let author: String?
    let description: String?
    let imageURL: URL?
}

/// The persistence boundary for App Entity discovery. Every method extracts
/// the property values it needs before returning, which avoids faulting a live
/// SwiftData relationship from App Intents after a concurrent store update.
@ModelActor
actor AppIntentLibraryQueryActor {
    func upNextEpisodes(limit: Int) throws -> [IntentEpisodeSnapshot] {
        guard limit > 0,
              let queue = Playlist.existingDefaultQueue(in: modelContext)
        else {
            return []
        }

        return try playlistEpisodes(playlistID: queue.id, limit: limit)
    }

    func playlistEpisodes(playlistID: UUID, limit: Int) throws -> [IntentEpisodeSnapshot] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sortBy: [
                SortDescriptor(\PlaylistEntry.order, order: .forward),
                SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
            ]
        )
        descriptor.fetchLimit = limit

        return try modelContext.fetch(descriptor).compactMap { entry in
            guard let episode = entry.episode else { return nil }
            return makeEpisodeSnapshot(from: episode)
        }
    }

    func playlistEpisodes(playlistEntityID: String, limit: Int) throws -> [IntentEpisodeSnapshot] {
        guard let playlistID = try playlistID(forEntityID: playlistEntityID) else { return [] }
        return try playlistEpisodes(playlistID: playlistID, limit: limit)
    }

    func episodes(withURLStrings identifiers: [String]) throws -> [IntentEpisodeSnapshot] {
        identifiers.compactMap { identifier in
            guard let url = URL(string: identifier) else { return nil }
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == url })
            descriptor.fetchLimit = 1
            guard let episode = try? modelContext.fetch(descriptor).first else { return nil }
            return makeEpisodeSnapshot(from: episode)
        }
    }

    func episodes(matching string: String, limit: Int) throws -> [IntentEpisodeSnapshot] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { episode in
                episode.title.localizedStandardContains(string)
                    || episode.podcast?.title.localizedStandardContains(string) == true
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap(makeEpisodeSnapshot)
    }

    func latestEpisode(ofFeedString feedString: String) throws -> IntentEpisodeSnapshot? {
        guard let feed = URL(string: feedString) else { return nil }
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.feed == feed },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.flatMap(makeEpisodeSnapshot)
    }

    func podcasts(withFeedStrings identifiers: [String]) throws -> [IntentPodcastSnapshot] {
        identifiers.compactMap { identifier in
            guard let feed = URL(string: identifier) else { return nil }
            var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feed == feed })
            descriptor.fetchLimit = 1
            guard let podcast = try? modelContext.fetch(descriptor).first else { return nil }
            return makePodcastSnapshot(from: podcast)
        }
    }

    func subscribedPodcasts(matching string: String?, limit: Int) throws -> [IntentPodcastSnapshot] {
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.metaData?.isSubscribed != false },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        let podcasts = try modelContext.fetch(descriptor)
        return podcasts.compactMap { podcast in
            guard string.map({ podcast.title.localizedStandardContains($0) }) ?? true else { return nil }
            return makePodcastSnapshot(from: podcast)
        }
    }

    private func makeEpisodeSnapshot(from episode: Episode) -> IntentEpisodeSnapshot? {
        guard let url = episode.url else { return nil }
        let podcast = episode.podcast
        return IntentEpisodeSnapshot(
            id: url.absoluteString,
            title: episode.title,
            podcastTitle: podcast?.title,
            podcastFeedID: podcast?.feed?.absoluteString,
            podcastDescription: podcast?.desc,
            imageURL: episode.imageURL ?? podcast?.imageURL,
            publishDate: episode.publishDate,
            duration: episode.duration,
            isDownloadable: episode.source != .sideLoaded
        )
    }

    private func makePodcastSnapshot(from podcast: Podcast) -> IntentPodcastSnapshot? {
        guard let feed = podcast.feed else { return nil }
        return IntentPodcastSnapshot(
            id: feed.absoluteString,
            title: podcast.title,
            author: podcast.author,
            description: podcast.desc,
            imageURL: podcast.imageURL
        )
    }

    private func playlistID(forEntityID entityID: String) throws -> UUID? {
        if entityID == Playlist.defaultQueueSyncID {
            return Playlist.existingDefaultQueue(in: modelContext)?.id
        }

        let syncID: String? = entityID
        var syncIDDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.syncID == syncID
            }
        )
        syncIDDescriptor.fetchLimit = 1
        if let playlist = try modelContext.fetch(syncIDDescriptor).first {
            return playlist.id
        }

        guard let localID = UUID(uuidString: entityID) else { return nil }
        var localIDDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.id == localID
            }
        )
        localIDDescriptor.fetchLimit = 1
        return try modelContext.fetch(localIDDescriptor).first?.id
    }
}

/// Library fetches shared by the entity queries here and the iOS 27 schema
/// entity queries in PodcastSchemaEntities.swift.
@MainActor
enum LibraryEntityLookup {
    private static let resultLimit = 25
    private static let maximumQueueResultLimit = 50

    static func episodes(withURLStrings identifiers: [String]) async throws -> [IntentEpisodeSnapshot] {
        try await queryActor().episodes(withURLStrings: identifiers)
    }

    static func episodes(matching string: String) async throws -> [IntentEpisodeSnapshot] {
        try await queryActor().episodes(matching: string, limit: resultLimit)
    }

    /// The Up Next queue, which is what people act on most.
    static func upNextEpisodes(limit: Int = resultLimit) async throws -> [IntentEpisodeSnapshot] {
        try await queryActor().upNextEpisodes(limit: min(max(limit, 0), maximumQueueResultLimit))
    }

    static func playlistEpisodes(playlistEntityID: String, limit: Int = maximumQueueResultLimit) async throws -> [IntentEpisodeSnapshot] {
        try await queryActor().playlistEpisodes(
            playlistEntityID: playlistEntityID,
            limit: min(max(limit, 0), maximumQueueResultLimit)
        )
    }

    static func latestEpisode(ofFeedString feedString: String) async throws -> IntentEpisodeSnapshot? {
        try await queryActor().latestEpisode(ofFeedString: feedString)
    }

    static func podcasts(withFeedStrings identifiers: [String]) async throws -> [IntentPodcastSnapshot] {
        try await queryActor().podcasts(withFeedStrings: identifiers)
    }

    static func subscribedPodcasts(matching string: String? = nil) async throws -> [IntentPodcastSnapshot] {
        try await queryActor().subscribedPodcasts(matching: string, limit: resultLimit)
    }

    private static func queryActor() async throws -> AppIntentLibraryQueryActor {
        AppIntentLibraryQueryActor(modelContainer: try await preparedIntentModelContainer())
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
        let player = try await preparedIntentPlayer()
        await player.playEpisode(url, playDirectly: true)
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
        let player = try await preparedIntentPlayer()
        guard let episode = try await LibraryEntityLookup.latestEpisode(ofFeedString: podcast.id),
              let episodeURL = URL(string: episode.id)
        else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }

        await player.playEpisode(episodeURL, playDirectly: true)
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
        let player = try await preparedIntentPlayer()
        guard let playlistActor = player.playlistActor else {
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
        undoManager?.registerUndo(withTarget: player) { _ in
            Task {
                for url in newlyQueued {
                    try? await playlistActor.remove(episodeURL: url)
                }
            }
        }

        return .result(dialog: "Added \(urls.count) episodes to Up Next.")
    }
}
