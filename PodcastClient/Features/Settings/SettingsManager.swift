//
//  PlaylistManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.01.24.
//

import Foundation
import SwiftData

@Observable


class SettingsManager:NSObject{
    
    static let shared = SettingsManager()
    var modelContext: ModelContext? = PersistanceManager.shared.sharedContext
    let configuration = ModelConfiguration(isStoredInMemoryOnly: false, allowsSave: true)
    
    var defaultSettings: PodcastSettings {
        
        let defaultSettingsTitel = "de.holgerkrupp.podbay.queue"
        
        var defaultSettings = FetchDescriptor<PodcastSettings>(predicate: #Predicate { settings in
            settings.title == defaultSettingsTitel
        })
        defaultSettings.fetchLimit = 1
        
        if let result = try! modelContext?.fetch(defaultSettings).first {
            return result
        } else {
            let newDefaultSettings = PodcastSettings()
            newDefaultSettings.title = defaultSettingsTitel
            modelContext?.insert(newDefaultSettings)
            return newDefaultSettings
        }
    }
    
    
    private override init() {
        super.init()
        

    }
    
    
}

