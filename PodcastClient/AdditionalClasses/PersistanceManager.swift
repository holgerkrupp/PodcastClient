//
//  persistanceManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 22.01.24.
//

import Foundation
import SwiftData

class PersistanceManager{
    static let shared = PersistanceManager()
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Chapter.self,
            
            PodcastSettings.self,
            
            Playlist.self,
            PlaylistEntry.self
            
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    
    var sharedContext:ModelContext
    
    
    private init(){

            sharedContext = ModelContext(sharedModelContainer)
        
        
    }
    
}


