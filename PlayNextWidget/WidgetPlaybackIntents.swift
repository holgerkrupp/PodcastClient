import AppIntents
import Foundation

/// Shared declaration keeps the intent discoverable in both the app and the
/// widget. AudioPlaybackIntent routes execution to the app process, where the
/// authoritative Player lives.
struct WidgetPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Control Up Next playback.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        return .result()
        #else
        let player = try await preparedIntentPlayer()
        if player.isPlaying {
            player.pause()
        } else if player.currentEpisodeURL != nil {
            player.play()
        } else if let playlistActor = player.playlistActor,
                  let firstURL = (try? await playlistActor.orderedEpisodeURLs())?.first {
            await player.playEpisode(firstURL, playDirectly: true)
        }
        await PlayNextWidgetSync.publishPlaybackState()
        return .result()
        #endif
    }
}

struct WidgetPlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode"
    static let description = IntentDescription("Start the selected Up Next episode.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Episode ID")
    var episodeID: String

    init() {}

    init(episodeID: String) {
        self.episodeID = episodeID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        return .result()
        #else
        guard let url = URL(string: episodeID) else { return .result() }
        let player = try await preparedIntentPlayer()
        await player.playEpisode(url, playDirectly: true)
        await PlayNextWidgetSync.publishPlaybackState()
        return .result()
        #endif
    }
}
