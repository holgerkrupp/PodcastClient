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
    static var title: LocalizedStringResource = "Resume Playback"
   
    func perform() async throws -> some IntentResult {
        await Player.shared.play()
        return .result()
    }
}

struct PlayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        
            AppShortcut(
                intent: ResumePlaybackIntent(),
                phrases: ["Resume playback", "Play last episode"],
                shortTitle: "Resume",
                systemImageName: "play.circle"
            )
        
    }
}
