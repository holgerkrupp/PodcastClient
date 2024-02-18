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
    var modelContext: ModelContext? = PersistenceManager.shared.sharedContext
    
    public let playNextQueueTitel = "de.holgerkrupp.podbay.queue"
    
    
    
    var playnext: Playlist {
        
        
        
        var playNextQueue = FetchDescriptor<Playlist>(predicate: #Predicate { playlist in
            playlist.title == playNextQueueTitel
        })
        playNextQueue.fetchLimit = 1
        
        if let result = try! modelContext?.fetch(playNextQueue).first {
            print("found old default Playlist")
            return result
        } else {
            print("create new default Playlist")
            let playNextPlaylist = Playlist()
            playNextPlaylist.title = playNextQueueTitel
            playNextPlaylist.deleteable = false
            playNextPlaylist.hidden = true
            modelContext?.insert(playNextPlaylist)
            return playNextPlaylist
        }
    }
    
    
    private override init() {
        super.init()
        
        modelContext = PersistenceManager.shared.sharedContext
    }
    
    
}
