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
        
    }
}

