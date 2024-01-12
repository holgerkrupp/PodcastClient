//
//  PlaylistManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.01.24.
//

import Foundation
import SwiftData

@Observable

class PlaylistManager:NSObject{
    
    static let shared = PlaylistManager()
    var modelContext: ModelContext?
    let configuration = ModelConfiguration(isStoredInMemoryOnly: false, allowsSave: true)
    
    var playnext: Playlist {
        
        let playNextQueueTitel = "de.holgerkrupp.podbay.queue"
        
        var playNextQueue = FetchDescriptor<Playlist>(predicate: #Predicate { playlist in
            playlist.title == playNextQueueTitel
        })
        playNextQueue.fetchLimit = 1
        
        if let result = try! modelContext?.fetch(playNextQueue).first {
            return result
        } else {
            var playNextPlaylist = Playlist()
            playNextPlaylist.deleteable = false
            playNextPlaylist.hidden = true
            modelContext?.insert(playNextPlaylist)
            return playNextPlaylist
        }
    }
    
    
    private override init() {
        super.init()
        
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Chapter.self,
            
            //        Asset.self,
            PodcastSettings.self,
            //     PlayStatus.self,
            
            Playlist.self,
            PlaylistEntry.self
            
        ])
        
        
        if let container = try? ModelContainer(
            for: schema,
            configurations: configuration
        ){
            modelContext = ModelContext(container)
        }
    }
    
    
}
