//
//  PlayerIntentsExtension.swift
//  PlayerIntentsExtension
//
//  Created by Holger Krupp on 20.06.25.
//

import AppIntents

struct PlayerIntentsExtension: AppIntent {
    static var title: LocalizedStringResource { "PlayerIntentsExtension" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}


struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Playback"
   
    func perform() async throws -> some IntentResult {
        await Player.shared.play()
        return .result()
    }
}

struct BookmarkCurrentPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark This"
    static let description = IntentDescription("Create a bookmark at the current playback position.")
    
    func perform() async throws -> some IntentResult {
        await Player.shared.createBookmark()
        return .result()
    }
}

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pause the current episode.")

    func perform() async throws -> some IntentResult {
        await Player.shared.pause()
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward by your configured duration.")

    func perform() async throws -> some IntentResult {
        await Player.shared.skipforward()
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward by your configured duration.")

    func perform() async throws -> some IntentResult {
        await Player.shared.skipback()
        return .result()
    }
}

struct PlayFirstUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Up Next"
    static let description = IntentDescription("Start playback with the first episode in your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }

        let urls = (try? await playlistActor.orderedEpisodeURLs()) ?? []
        guard let firstURL = urls.first else {
            return .result()
        }

        await Player.shared.playEpisode(firstURL, playDirectly: true)
        return .result()
    }
}

struct PlayNextUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Next Up Next Episode"
    static let description = IntentDescription("Play the next episode from your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }

        guard let nextURL = try? await playlistActor.nextEpisodeURL() else {
            return .result()
        }

        await Player.shared.playEpisode(nextURL, playDirectly: true)
        return .result()
    }
}

struct MoveCurrentEpisodeToEndIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Current To End"
    static let description = IntentDescription("Move the current episode to the end of your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }
        guard let currentEpisodeURL = await Player.shared.currentEpisodeURL else {
            return .result()
        }

        try? await playlistActor.add(episodeURL: currentEpisodeURL, to: .end)
        return .result()
    }
}

struct RemoveCurrentFromUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Current From Up Next"
    static let description = IntentDescription("Remove the current episode from your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }
        guard let currentEpisodeURL = await Player.shared.currentEpisodeURL else {
            return .result()
        }

        try? await playlistActor.remove(episodeURL: currentEpisodeURL)
        return .result()
    }
}


struct BookmarkCurrentPlaybackShortcut: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BookmarkCurrentPlaybackIntent(),
            phrases: ["Bookmark this in ${applicationName}", "Save a bookmark in ${applicationName}", "Bookmark the current position in ${applicationName}"],
            shortTitle: "Bookmark",
            systemImageName: "bookmark"
        )

        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: ["Resume playback in ${applicationName}", "Play last episode in ${applicationName}"],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: ["Pause playback in ${applicationName}", "Pause ${applicationName}"],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )

        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["Skip forward in ${applicationName}", "Jump ahead in ${applicationName}"],
            shortTitle: "Forward",
            systemImageName: "arrow.forward.circle"
        )

        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: ["Skip back in ${applicationName}", "Jump back in ${applicationName}"],
            shortTitle: "Back",
            systemImageName: "arrow.backward.circle"
        )

        AppShortcut(
            intent: PlayFirstUpNextIntent(),
            phrases: ["Play Up Next in ${applicationName}", "Start Up Next in ${applicationName}"],
            shortTitle: "Play Up Next",
            systemImageName: "text.line.first.and.arrowtriangle.forward"
        )

        AppShortcut(
            intent: PlayNextUpNextIntent(),
            phrases: ["Play next episode in ${applicationName}", "Play what's next in ${applicationName}"],
            shortTitle: "Play Next",
            systemImageName: "forward.end"
        )

        AppShortcut(
            intent: MoveCurrentEpisodeToEndIntent(),
            phrases: ["Move this episode to the end in ${applicationName}", "Send current episode to the end in ${applicationName}"],
            shortTitle: "Move To End",
            systemImageName: "text.line.last.and.arrowtriangle.forward"
        )

        AppShortcut(
            intent: RemoveCurrentFromUpNextIntent(),
            phrases: ["Remove this from Up Next in ${applicationName}", "Remove current episode in ${applicationName}"],
            shortTitle: "Remove Current",
            systemImageName: "minus.circle"
        )
    }
}
