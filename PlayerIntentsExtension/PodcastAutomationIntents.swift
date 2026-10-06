//
//  PodcastAutomationIntents.swift
//  PlayerIntentsExtension
//
//  Podcast-aware App Intents.  These intents deliberately delegate to the
//  same Player, model actors, feed resolver, and live-podcast discovery used by
//  the application UI.
//

import AppIntents
import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Shared enums and helpers

struct PodcastIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: LocalizedStringResource

    init(_ message: LocalizedStringResource) {
        self.message = message
    }

    var localizedStringResource: LocalizedStringResource {
        message
    }
}

enum PlaybackSpeedAppEnum: String, AppEnum {
    case half = "0.5"
    case threeQuarters = "0.75"
    case normal = "1.0"
    case oneAndAQuarter = "1.25"
    case oneAndAHalf = "1.5"
    case oneAndThreeQuarters = "1.75"
    case double = "2.0"
    case twoAndAHalf = "2.5"
    case triple = "3.0"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Speed")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .half: "0.5×",
        .threeQuarters: "0.75×",
        .normal: "1×",
        .oneAndAQuarter: "1.25×",
        .oneAndAHalf: "1.5×",
        .oneAndThreeQuarters: "1.75×",
        .double: "2×",
        .twoAndAHalf: "2.5×",
        .triple: "3×"
    ]

    var value: Float { Float(rawValue) ?? 1.0 }
}

enum SleepTimerMode: String, AppEnum {
    case minutes
    case afterEpisode

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer Mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .minutes: "After a number of minutes",
        .afterEpisode: "After this episode"
    ]
}

enum TranscriptOutputFormat: String, AppEnum {
    case plainText
    case timestampedText

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Transcript Format")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .plainText: "Plain text",
        .timestampedText: "Timestamped text"
    ]
}

@MainActor
enum PodcastIntentSupport {
    static func episodeURL(for entity: EpisodeEntity?) async throws -> URL {
        if let entity, let url = URL(string: entity.id) {
            return url
        }
        let player = try await preparedIntentPlayer()
        if let url = player.currentEpisodeURL {
            return url
        }
        throw PodcastIntentError("There is no current podcast episode.")
    }

    static func container() async throws -> ModelContainer {
        try await preparedIntentModelContainer()
    }

    static func playlist(for entity: PlaylistEntity, in container: ModelContainer) throws -> Playlist {
        let context = container.mainContext
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        guard let playlist = playlists.first(where: { $0.storeSplitSyncID == entity.id }) else {
            throw PodcastIntentError("That playlist is no longer available.")
        }
        return playlist
    }

    static func playlistActor(for entity: PlaylistEntity, in container: ModelContainer) throws -> PlaylistModelActor {
        let playlist = try playlist(for: entity, in: container)
        return try PlaylistModelActor(modelContainer: container, playlistID: playlist.id)
    }
}

// MARK: - Sleep timer

struct SleepTimerStatusEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer")
    static let defaultQuery = SleepTimerStatusQuery()

    let id = "sleep-timer"
    let isActive: Bool
    let remainingMinutes: Int?
    let stopsAfterEpisode: Bool

    var displayRepresentation: DisplayRepresentation {
        let title = isActive ? "Sleep Timer Active" : "Sleep Timer Off"
        let detail: String
        if stopsAfterEpisode {
            detail = "Stops after this episode"
        } else if let remainingMinutes {
            detail = "\(remainingMinutes) minutes remaining"
        } else {
            detail = "Off"
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }
}

struct SleepTimerStatusQuery: EntityStringQuery {
    func entities(for identifiers: [SleepTimerStatusEntity.ID]) async throws -> [SleepTimerStatusEntity] {
        guard identifiers.contains("sleep-timer") else { return [] }
        _ = try await preparedIntentModelContainer()
        return [await MainActor.run { SleepTimerStatusEntity.current() }]
    }

    func entities(matching string: String) async throws -> [SleepTimerStatusEntity] { [] }

    func suggestedEntities() async throws -> [SleepTimerStatusEntity] {
        _ = try await preparedIntentModelContainer()
        return [await MainActor.run { SleepTimerStatusEntity.current() }]
    }
}

private extension SleepTimerStatusEntity {
    @MainActor
    static func current() -> SleepTimerStatusEntity {
        let player = Player.shared
        let minutes = player.remainingTime.map { max(1, Int(ceil($0 / 60.0))) }
        return SleepTimerStatusEntity(
            isActive: player.stopAfterEpisode || player.remainingTime != nil,
            remainingMinutes: minutes,
            stopsAfterEpisode: player.stopAfterEpisode
        )
    }
}

struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Stop playback after a number of minutes or after the current episode.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Minutes", default: 30)
    var minutes: Int

    @Parameter(title: "Mode", default: .minutes)
    var mode: SleepTimerMode

    static var parameterSummary: some ParameterSummary {
        Summary("Set sleep timer") {
            \.$minutes
            \.$mode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        switch mode {
        case .minutes:
            guard (1...24 * 60).contains(minutes) else {
                throw PodcastIntentError("Choose a duration from 1 minute to 24 hours.")
            }
            player.stopAfterEpisode = false
            player.setSleepTimer(minutes: minutes)
            return .result(dialog: "Sleep timer set for \(minutes) minutes.")
        case .afterEpisode:
            player.setSleepTimer(minutes: 0)
            player.stopAfterEpisode = true
            return .result(dialog: "Playback will stop after this episode.")
        }
    }
}

struct CancelSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Sleep Timer"
    static let description = IntentDescription("Cancel both the minute-based and after-episode sleep timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        player.cancelSleepTimer()
        return .result(dialog: "Sleep timer cancelled.")
    }
}

struct GetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Sleep Timer"
    static let description = IntentDescription("Get the current sleep timer state and remaining time.")

    @MainActor
    func perform() async throws -> some ReturnsValue<SleepTimerStatusEntity> & ProvidesDialog {
        _ = try await preparedIntentModelContainer()
        let status = SleepTimerStatusEntity.current()
        return .result(value: status, dialog: status.isActive ? "Sleep timer is active." : "Sleep timer is off.")
    }
}

// MARK: - Playback rate and chapters

struct SetPlaybackSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Change playback speed using the same setting as the player.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Speed", default: .normal)
    var speed: PlaybackSpeedAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        guard player.currentEpisode != nil else {
            throw PodcastIntentError("There is no episode playing.")
        }
        player.playbackRate = speed.value
        return .result(dialog: "Playback speed set to \(speed.rawValue) times.")
    }
}

struct NextChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Skip to the next chapter of the current episode.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        guard player.currentEpisode != nil, player.chapters?.isEmpty == false else {
            throw PodcastIntentError("The current episode has no chapters.")
        }
        await player.skipToNextChapter(protectLargeSeek: false)
        return .result(dialog: "Moved to the next chapter.")
    }
}

struct PreviousChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Go to the previous chapter of the current episode.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        guard player.currentEpisode != nil, player.chapters?.isEmpty == false else {
            throw PodcastIntentError("The current episode has no chapters.")
        }
        await player.skipToPreviousChapter(protectLargeSeek: false)
        return .result(dialog: "Moved to the previous chapter.")
    }
}

struct RestartChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Current Chapter"
    static let description = IntentDescription("Restart the current chapter of the playing episode.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        guard player.currentChapter != nil else {
            throw PodcastIntentError("There is no current chapter.")
        }
        await player.skipToChapterStart(protectLargeSeek: false)
        return .result(dialog: "Chapter restarted.")
    }
}

// MARK: - Now playing and queue queries

struct NowPlayingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Now Playing")
    static let defaultQuery = NowPlayingEntityQuery()

    let id: String
    let title: String
    let podcastTitle: String?
    let chapterTitle: String?
    let position: Double?
    let duration: Double?
    let playbackRate: Double
    let isPlaying: Bool
    let isLive: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: podcastTitle.map { "\($0)" })
    }

    @MainActor
    static func current() -> NowPlayingEntity {
        let player = Player.shared
        let episode = player.currentEpisode
        return NowPlayingEntity(
            id: player.currentEpisodeURL?.absoluteString ?? player.currentLiveItem?.id ?? "none",
            title: episode?.title ?? "Nothing Playing",
            podcastTitle: episode?.podcast?.title ?? episode?.author,
            chapterTitle: player.currentChapter?.title,
            position: player.isLivePlayback ? nil : player.playPosition,
            duration: episode?.duration,
            playbackRate: Double(player.playbackRate),
            isPlaying: player.isPlaying,
            isLive: player.isLivePlayback
        )
    }
}

struct NowPlayingEntityQuery: EntityStringQuery {
    func entities(for identifiers: [NowPlayingEntity.ID]) async throws -> [NowPlayingEntity] {
        guard identifiers.contains(where: { $0 == "none" || !$0.isEmpty }) else { return [] }
        _ = try await preparedIntentModelContainer()
        return [await MainActor.run { NowPlayingEntity.current() }]
    }

    func entities(matching string: String) async throws -> [NowPlayingEntity] {
        _ = try await preparedIntentModelContainer()
        return [await MainActor.run { NowPlayingEntity.current() }]
    }

    func suggestedEntities() async throws -> [NowPlayingEntity] {
        _ = try await preparedIntentModelContainer()
        return [await MainActor.run { NowPlayingEntity.current() }]
    }
}

struct GetNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Now Playing"
    static let description = IntentDescription("Return the current episode, chapter, position, and playback state.")

    @MainActor
    func perform() async throws -> some ReturnsValue<NowPlayingEntity> & ProvidesDialog {
        _ = try await preparedIntentModelContainer()
        let nowPlaying = NowPlayingEntity.current()
        let dialog = nowPlaying.isLive
            ? "You are listening to \(nowPlaying.title) live."
            : (nowPlaying.id == "none" ? "Nothing is playing." : "You are listening to \(nowPlaying.title).")
        return .result(value: nowPlaying, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct GetUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Up Next Queue"
    static let description = IntentDescription("Return episodes in Up Next order without refreshing feeds.")

    @Parameter(title: "Maximum Episodes", default: 10)
    var maximumEpisodes: Int

    @MainActor
    func perform() async throws -> some ReturnsValue<[EpisodeEntity]> & ProvidesDialog {
        let limit = min(max(maximumEpisodes, 1), 50)
        let episodes = try await LibraryEntityLookup.upNextEpisodes(limit: limit)
            .map(EpisodeEntity.init(snapshot:))
        return .result(value: episodes, dialog: episodes.isEmpty ? "Up Next is empty." : "Here are the next \(episodes.count) episodes.")
    }
}

// MARK: - iOS/macOS 26 queue action

struct AddEpisodeToUpNextIntent: UndoableIntent {
    static let title: LocalizedStringResource = "Add Episode to Up Next"
    static let description = IntentDescription("Add one episode to the front or end of Up Next.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    @Parameter(title: "Position", default: .end)
    var position: UpNextQueuePosition

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }
        let player = try await preparedIntentPlayer()
        let container = try await PodcastIntentSupport.container()
        let actor = try PlaylistModelActor(modelContainer: container)
        let original = try await actor.orderedEpisodeURLs()
        try await actor.add(episodeURL: url, to: position.playlistPosition)
        undoManager?.registerUndo(withTarget: player) { _ in
            Task {
                if let index = original.firstIndex(of: url) {
                    try? await actor.add(episodeURL: url, to: .end, index: index)
                } else {
                    try? await actor.remove(episodeURL: url)
                }
            }
        }
        return .result(dialog: position == .front ? "Episode added to play next." : "Episode added to the end of Up Next.")
    }
}

// MARK: - Episode lifecycle

struct MarkEpisodePlayedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Episode Played"
    static let description = IntentDescription("Mark the selected episode, or the current episode, as played.")

    @Parameter(title: "Episode")
    var episode: EpisodeEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = try await PodcastIntentSupport.episodeURL(for: episode)
        await EpisodeActor(modelContainer: try await PodcastIntentSupport.container()).markasPlayed(url)
        return .result(dialog: "Episode marked as played.")
    }
}

struct ArchiveEpisodeIntent: UndoableIntent {
    static let title: LocalizedStringResource = "Archive Episode"
    static let description = IntentDescription("Archive an episode so it is no longer in the inbox.")

    @Parameter(title: "Episode")
    var episode: EpisodeEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = try await PodcastIntentSupport.episodeURL(for: episode)
        let player = try await preparedIntentPlayer()
        let actor = EpisodeActor(modelContainer: try await PodcastIntentSupport.container())
        await actor.archiveEpisode(url)
        undoManager?.registerUndo(withTarget: player) { _ in
            Task { await actor.unarchiveEpisode(url) }
        }
        return .result(dialog: "Episode archived.")
    }
}

struct UnarchiveEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Unarchive Episode"
    static let description = IntentDescription("Restore an archived episode.")

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else { throw PlayPodcastEpisodeError.episodeNotFound }
        await EpisodeActor(modelContainer: try await PodcastIntentSupport.container()).unarchiveEpisode(url)
        return .result(dialog: "Episode restored from the archive.")
    }
}

struct DownloadEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Episode"
    static let description = IntentDescription("Download an episode using Up Next's normal download service.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else { throw PlayPodcastEpisodeError.episodeNotFound }
        let container = try await PodcastIntentSupport.container()
        let stored = try await LibraryEntityLookup.episodes(withURLStrings: [url.absoluteString]).first
        guard let stored else { throw PlayPodcastEpisodeError.episodeNotFound }
        guard stored.isDownloadable else {
            throw PodcastIntentError("This episode cannot be downloaded by Up Next.")
        }
        await EpisodeActor(modelContainer: container).download(episodeURL: url)
        return .result(dialog: "Download started for \(stored.title).")
    }
}

// MARK: - Playlists

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    let id: String
    let title: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init?(playlist: Playlist) {
        guard playlist.hidden == false, playlist.isSmartPlaylist == false else { return nil }
        id = playlist.storeSplitSyncID
        title = playlist.displayTitle
        symbolName = playlist.displaySymbolName
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let container = try await preparedIntentModelContainer()
        return try container.mainContext.fetch(FetchDescriptor<Playlist>())
            .filter { identifiers.contains($0.storeSplitSyncID) }
            .compactMap(PlaylistEntity.init(playlist:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let container = try await preparedIntentModelContainer()
        return try container.mainContext.fetch(FetchDescriptor<Playlist>())
            .filter { $0.hidden == false && $0.isSmartPlaylist == false && $0.displayTitle.localizedStandardContains(string) }
            .prefix(25)
            .compactMap(PlaylistEntity.init(playlist:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        let container = try await preparedIntentModelContainer()
        return try Playlist.visibleSorted(container.mainContext.fetch(FetchDescriptor<Playlist>()))
            .filter { $0.isSmartPlaylist == false }
            .prefix(25)
            .compactMap(PlaylistEntity.init(playlist:))
    }
}

struct AddEpisodeToPlaylistIntent: UndoableIntent {
    static let title: LocalizedStringResource = "Add Episode to Playlist"
    static let description = IntentDescription("Add an episode to a named playlist.")

    @Parameter(title: "Episode")
    var episode: EpisodeEntity
    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity
    @Parameter(title: "Position", default: .end)
    var position: UpNextQueuePosition

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else { throw PlayPodcastEpisodeError.episodeNotFound }
        let player = try await preparedIntentPlayer()
        let container = try await PodcastIntentSupport.container()
        let actor = try PodcastIntentSupport.playlistActor(for: playlist, in: container)
        let before = try await actor.orderedEpisodeURLs()
        try await actor.add(episodeURL: url, to: position.playlistPosition)
        undoManager?.registerUndo(withTarget: player) { _ in
            Task {
                if let index = before.firstIndex(of: url) {
                    try? await actor.add(episodeURL: url, to: .end, index: index)
                } else {
                    try? await actor.remove(episodeURL: url)
                }
            }
        }
        return .result(dialog: "Added \(episode.title) to \(playlist.title).")
    }
}

struct GetPlaylistEpisodesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Episodes in Playlist"
    static let description = IntentDescription("Return the episodes in a named playlist in their saved order.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some ReturnsValue<[EpisodeEntity]> & ProvidesDialog {
        let episodes = try await LibraryEntityLookup.playlistEpisodes(playlistEntityID: playlist.id)
            .map(EpisodeEntity.init(snapshot:))
        return .result(value: episodes, dialog: "\(episodes.count) episodes in \(playlist.title).")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Start playback with the first episode in a named playlist.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actor = try PodcastIntentSupport.playlistActor(for: playlist, in: try await PodcastIntentSupport.container())
        guard let url = try await actor.firstEpisodeURL() else {
            throw PodcastIntentError("That playlist is empty.")
        }
        let player = try await preparedIntentPlayer()
        await player.playEpisode(url, playDirectly: true)
        return .result(dialog: "Playing \(playlist.title).")
    }
}

struct RemoveEpisodeFromPlaylistIntent: UndoableIntent {
    static let title: LocalizedStringResource = "Remove Episode from Playlist"
    static let description = IntentDescription("Remove an episode from a named playlist.")

    @Parameter(title: "Episode")
    var episode: EpisodeEntity
    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else { throw PlayPodcastEpisodeError.episodeNotFound }
        let player = try await preparedIntentPlayer()
        let actor = try PodcastIntentSupport.playlistActor(for: playlist, in: try await PodcastIntentSupport.container())
        let before = try await actor.orderedEpisodeURLs()
        guard let index = before.firstIndex(of: url) else {
            return .result(dialog: "That episode is not in \(playlist.title).")
        }
        try await actor.remove(episodeURL: url)
        undoManager?.registerUndo(withTarget: player) { _ in
            Task { try? await actor.add(episodeURL: url, to: .end, index: index) }
        }
        return .result(dialog: "Removed \(episode.title) from \(playlist.title).")
    }
}

// MARK: - Podcast feed actions

struct RefreshPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Podcast"
    static let description = IntentDescription("Refresh one subscribed podcast feed.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let feed = URL(string: podcast.id) else { throw PodcastIntentError("That podcast feed is invalid.") }
        let container = try await PodcastIntentSupport.container()
        _ = try await PodcastModelActor(modelContainer: container).updatePodcast(feed, force: true, silent: true)
        return .result(dialog: "Refreshed \(podcast.title).")
    }
}

struct SubscribeToPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Subscribe to Podcast Feed"
    static let description = IntentDescription("Resolve a podcast page or feed URL and subscribe through Up Next.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "URL")
    var url: URL

    @MainActor
    func perform() async throws -> some ReturnsValue<PodcastEntity> & ProvidesDialog {
        let resolution = try await PodcastFeedResolver.resolve(url: url)
        guard case .podcast(let feed) = resolution, let feedURL = feed.url else {
            throw PodcastIntentError("That URL did not resolve to a podcast feed.")
        }
        let container = try await PodcastIntentSupport.container()
        _ = try await SubscriptionManager(modelContainer: container).addToLibrary(feed, subscribe: true)
        guard let podcast = try await LibraryEntityLookup.podcasts(withFeedStrings: [feedURL.absoluteString]).first else {
            throw PodcastIntentError("The podcast was subscribed, but its library entry is not ready yet.")
        }
        let entity = PodcastEntity(snapshot: podcast)
        return .result(value: entity, dialog: "Subscribed to \(entity.title).")
    }
}

// MARK: - Transcripts

struct GetEpisodeTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Episode Transcript"
    static let description = IntentDescription("Return an episode transcript as a text file for use in Shortcuts.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode")
    var episode: EpisodeEntity?
    @Parameter(title: "Format", default: .plainText)
    var format: TranscriptOutputFormat

    @MainActor
    func perform() async throws -> some ReturnsValue<IntentFile> & ProvidesDialog {
        let url = try await PodcastIntentSupport.episodeURL(for: episode)
        let text = try await LibraryEntityLookup.transcriptText(for: url, format: format)
        let filename = "\(episode?.title ?? "UpNext-Transcript").txt"
        let file = IntentFile(data: Data(text.utf8), filename: filename, type: .plainText)
        return .result(value: file, dialog: "Transcript ready.")
    }
}

struct GenerateEpisodeTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Episode Transcript"
    static let description = IntentDescription("Use Up Next's existing transcript import or on-device transcription pipeline.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: episode.id) else { throw PlayPodcastEpisodeError.episodeNotFound }
        let actor = EpisodeActor(modelContainer: try await PodcastIntentSupport.container())
        try await actor.transcribe(url, origin: .manual)
        let ready = try? await LibraryEntityLookup.transcriptText(for: url, format: .plainText)
        return .result(dialog: ready?.isEmpty == false ? "Transcript ready for \(episode.title)." : "Transcript generation was queued for \(episode.title).")
    }
}

// MARK: - Live podcasts

struct LivePodcastEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Live Podcast")
    static let defaultQuery = LivePodcastEntityQuery()

    let id: String
    let feedID: String
    let itemID: String
    let title: String
    let podcastTitle: String
    let status: String
    let start: Date?
    let end: Date?
    let artworkURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(podcastTitle) • \(status)",
            image: artworkURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init?(entry: LivePodcastEntry) {
        guard let feed = entry.podcast.feed else { return nil }
        feedID = feed.absoluteString
        itemID = entry.item.id
        id = "\(feedID)|\(itemID)"
        title = entry.item.title
        podcastTitle = entry.podcast.title
        status = entry.item.status.rawValue
        start = entry.item.start
        end = entry.item.end
        artworkURL = entry.item.artworkURL ?? entry.podcast.imageURL
    }
}

struct LivePodcastEntityQuery: EntityStringQuery {
    @MainActor
    private func liveEntities() async throws -> [LivePodcastEntity] {
        let container = try await preparedIntentModelContainer()
        let settings = try container.mainContext.fetch(FetchDescriptor<PodcastSettings>()).first { $0.title == PodcastSettingsView.defaultSettingsTitle }
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.metaData?.isSubscribed != false },
            sortBy: [SortDescriptor(\.title)]
        )
        let podcasts = try container.mainContext.fetch(descriptor)
        return LivePodcastDiscovery.entries(from: podcasts, isEnabled: settings?.showLivePodcasts != false)
            .compactMap(LivePodcastEntity.init(entry:))
    }

    func entities(for identifiers: [LivePodcastEntity.ID]) async throws -> [LivePodcastEntity] {
        try await liveEntities().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [LivePodcastEntity] {
        try await liveEntities().filter { $0.title.localizedStandardContains(string) || $0.podcastTitle.localizedStandardContains(string) }.prefix(25).map { $0 }
    }

    func suggestedEntities() async throws -> [LivePodcastEntity] {
        try await liveEntities().prefix(25).map { $0 }
    }
}

struct GetLivePodcastsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Live Podcasts"
    static let description = IntentDescription("Return currently live subscribed podcasts.")

    @MainActor
    func perform() async throws -> some ReturnsValue<[LivePodcastEntity]> & ProvidesDialog {
        let entities = try await LivePodcastEntityQuery().suggestedEntities()
        return .result(value: entities, dialog: entities.isEmpty ? "No subscribed podcasts are live right now." : "There are \(entities.count) live podcasts.")
    }
}

struct PlayLivePodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Live Podcast"
    static let description = IntentDescription("Start a currently live podcast stream.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Live Podcast")
    var livePodcast: LivePodcastEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let entities = try await LivePodcastEntityQuery().entities(for: [livePodcast.id])
        guard let entity = entities.first else { throw PodcastIntentError("That live podcast is no longer available.") }
        let container = try await preparedIntentModelContainer()
        guard let feed = URL(string: entity.feedID) else {
            throw PodcastIntentError("That live podcast is no longer available.")
        }
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feed == feed })
        descriptor.fetchLimit = 1
        guard let podcast = try container.mainContext.fetch(descriptor).first,
              let item = podcast.liveItems.first(where: { $0.id == entity.itemID }) else {
            throw PodcastIntentError("That live podcast is no longer available.")
        }
        guard item.preferredStream != nil else { throw PodcastIntentError("This live podcast has no playable stream.") }
        let player = try await preparedIntentPlayer()
        await player.playLiveItem(item, podcastTitle: podcast.title, artworkURL: entity.artworkURL, link: item.link)
        return .result(dialog: "Playing \(entity.title) live.")
    }
}

struct EndLivePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Live Playback"
    static let description = IntentDescription("Stop live playback and return to the previous episode.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try await preparedIntentPlayer()
        guard player.isLivePlayback else { return .result(dialog: "Live playback is not active.") }
        await player.endLivePlayback()
        return .result(dialog: "Live playback stopped.")
    }
}

// MARK: - iOS/macOS 27 Audio App Schema

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum PlaylistOwnerValue {
    case person(IntentPerson)
    case string(String)
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct PlaylistSchemaEntity {
    static let defaultQuery = PlaylistSchemaEntityQuery()

    let id: String
    var title: String
    var owner: PlaylistOwnerValue?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init?(playlist: Playlist) {
        guard let entity = PlaylistEntity(playlist: playlist) else { return nil }
        id = entity.id
        title = entity.title
        owner = nil
        createdByMe = true
        curatedForMe = false
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct PlaylistSchemaEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PlaylistSchemaEntity.ID]) async throws -> [PlaylistSchemaEntity] {
        let container = try await preparedIntentModelContainer()
        return try container.mainContext.fetch(FetchDescriptor<Playlist>())
            .filter { identifiers.contains($0.storeSplitSyncID) }
            .compactMap(PlaylistSchemaEntity.init(playlist:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistSchemaEntity] {
        let container = try await preparedIntentModelContainer()
        return try container.mainContext.fetch(FetchDescriptor<Playlist>())
            .filter { $0.hidden == false && $0.isSmartPlaylist == false && $0.displayTitle.localizedStandardContains(string) }
            .prefix(25)
            .compactMap(PlaylistSchemaEntity.init(playlist:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistSchemaEntity] {
        let container = try await preparedIntentModelContainer()
        return try Playlist.visibleSorted(container.mainContext.fetch(FetchDescriptor<Playlist>()))
            .filter { $0.isSmartPlaylist == false }
            .prefix(25)
            .compactMap(PlaylistSchemaEntity.init(playlist:))
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddPodcastAudioToPlaylistIntent {
    var audioEntity: PodcastAudioItem
    var playlist: PlaylistSchemaEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = try await audioEntity.episodeURL()
        let container = try await PodcastIntentSupport.container()
        guard let custom = try await PlaylistEntityQuery().entities(for: [playlist.id]).first,
              let actorEntity = try await PlaylistEntityQuery().entities(for: [custom.id]).first else {
            throw PodcastIntentError("That playlist is no longer available.")
        }
        let actor = try PodcastIntentSupport.playlistActor(for: actorEntity, in: container)
        try await actor.add(episodeURL: url, to: .end)
        return .result(dialog: "Added the episode to \(playlist.title).")
    }
}

// MARK: - Entity lookup helpers used by intents

@MainActor
extension LibraryEntityLookup {
    static func transcriptText(for url: URL, format: TranscriptOutputFormat) async throws -> String {
        let context = try await preparedIntentModelContainer().mainContext
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == url })
        descriptor.fetchLimit = 1
        guard let episode = try context.fetch(descriptor).first else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }
        let lines = (episode.transcriptLines ?? []).sorted { $0.startTime < $1.startTime }
        guard lines.isEmpty == false else {
            throw PodcastIntentError("This episode does not have a transcript yet.")
        }
        return lines.map { line in
            switch format {
            case .plainText:
                return line.text
            case .timestampedText:
                return "[\(Self.timestamp(line.startTime))] \(line.text)"
            }
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
