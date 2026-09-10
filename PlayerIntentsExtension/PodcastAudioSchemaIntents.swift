//
//  PodcastAudioSchemaIntents.swift
//  PlayerIntentsExtension
//
//  The audio-domain playAudio and warmupAudioQueue schema intents, which let
//  Siri play podcast content ("play the latest Freak Show in Up Next") using
//  the schema entities from PodcastSchemaEntities.swift. iOS 27 only.
//

import AppIntents
import Foundation

// MARK: - Parameter types

/// What Siri asks the app to play: one episode, or a show (its newest episode).
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum PodcastAudioItem {
    case episode(PodcastEpisodeSchemaEntity)
    case show(PodcastShowSchemaEntity)
}

/// Shuffle and repeat don't apply to podcast episodes; the schema requires the
/// parameter, so the intents accept it and ignore it.
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum PodcastPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum PodcastQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Play Last"
    ]

    var playlistPosition: Playlist.Position {
        switch self {
        case .next:
            return .front
        case .tail:
            return .end
        }
    }
}

/// The episode a warmup loaded, handed back to the play intent.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct PodcastWarmupResult {
    static let defaultQuery = PodcastWarmupResultQuery()

    /// The loaded episode's audio URL.
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Up Next")
    }
}

/// The playAudio schema requires a string query. Warmup results only ever
/// arrive by identifier from the warmup intent, so there is nothing to search.
@available(iOS 27.0, macOS 27.0, *)
struct PodcastWarmupResultQuery: EntityStringQuery {
    func entities(for identifiers: [PodcastWarmupResult.ID]) async throws -> [PodcastWarmupResult] {
        identifiers.map { PodcastWarmupResult(id: $0) }
    }

    func entities(matching string: String) async throws -> [PodcastWarmupResult] {
        []
    }
}

// MARK: - Intents

/// Loads the requested episode into the player without starting playback, so
/// a following play request starts instantly.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.warmupAudioQueue)
struct WarmupPodcastAudioIntent {
    var audioEntity: PodcastAudioItem
    var playbackAttributes: Set<PodcastPlaybackAttributes>

    @MainActor
    func perform() async throws -> some ReturnsValue<PodcastWarmupResult> {
        let episodeURL = try await audioEntity.episodeURL()
        if Player.shared.currentEpisodeURL != episodeURL {
            await Player.shared.playEpisode(episodeURL, playDirectly: false)
        }
        return .result(value: PodcastWarmupResult(id: episodeURL.absoluteString))
    }
}

/// Plays the requested episode now, or queues it in Up Next when Siri asks
/// for a queue position ("play this next").
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayPodcastAudioIntent: AudioPlaybackIntent {
    var audioEntity: PodcastAudioItem
    var playbackAttributes: Set<PodcastPlaybackAttributes>
    var warmupAudioQueueResult: PodcastWarmupResult?
    var queueLocation: PodcastQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        let episodeURL = try await audioEntity.episodeURL()

        if let queueLocation {
            guard let playlistActor = Player.shared.playlistActor else {
                throw AppIntentError(description: "Up Next is unavailable.")
            }
            try await playlistActor.add(episodeURL: episodeURL, to: queueLocation.playlistPosition)
            return .result()
        }

        // A warmup already loaded this episode; just start it.
        if warmupAudioQueueResult?.id == episodeURL.absoluteString,
           Player.shared.currentEpisodeURL == episodeURL {
            Player.shared.play()
        } else {
            await Player.shared.playEpisode(episodeURL, playDirectly: true)
        }
        return .result()
    }
}

// MARK: - Resolution

@available(iOS 27.0, macOS 27.0, *)
private extension PodcastAudioItem {
    /// The audio URL to play: the episode itself, or a show's newest episode.
    @MainActor
    func episodeURL() async throws -> URL {
        switch self {
        case .episode(let episode):
            guard let url = URL(string: episode.id) else {
                throw PlayPodcastEpisodeError.episodeNotFound
            }
            return url
        case .show(let show):
            guard let episode = try await LibraryEntityLookup.latestEpisode(ofFeedString: show.id) else {
                throw PlayPodcastEpisodeError.episodeNotFound
            }
            guard let url = episode.url else {
                throw PlayPodcastEpisodeError.episodeHasNoAudio
            }
            return url
        }
    }
}
