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
    
    @MainActor static let shared = PlaylistManager()
    var container: ModelContainer = ModelContainerManager().container
    var modelContext:ModelContext?
    public let playNextQueueTitel: String = "de.holgerkrupp.podbay.queue"
    
    
    var playnext: Playlist {
        guard let context = modelContext else {
            print("No modelContext available")
            return Playlist()
        }

        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate {
            $0.title == "de.holgerkrupp.podbay.queue"
        })
        descriptor.fetchLimit = 1

        if let existing = try? context.fetch(descriptor).first {
            print("Found existing playlist")
            return existing
        } else {
            print("Creating new default playlist")
            let playlist = Playlist()
            playlist.title = playNextQueueTitel
            playlist.deleteable = false
            playlist.hidden = true

            context.insert(playlist)

            do {
                try context.save()
            } catch {
                print("Save error: \(error)")
            }

            return playlist
        }
    }

    
    
    private override init() {
        super.init()
        
        modelContext = ModelContext(container)
    }
    
    
}
