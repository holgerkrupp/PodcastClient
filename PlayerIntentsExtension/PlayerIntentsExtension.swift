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
