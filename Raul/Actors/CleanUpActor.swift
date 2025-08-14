//
//  CleanUpActor.swift
//  Raul
//
//  Created by AI Assistant on 25.07.25.
//

import Foundation
import SwiftData

@ModelActor
actor CleanUpActor {
    lazy var episodeActor: EpisodeActor = EpisodeActor(modelContainer: self.modelContainer)

    /// Deletes downloaded episode files with no attached playlist and lastPlayed >= one week ago
    func cleanUpOldDownloads() async {
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        let fetchDescriptor = FetchDescriptor<Episode>()
        let context = ModelContext(self.modelContainer)
        let episodes: [Episode]
        do {
            episodes = try context.fetch(fetchDescriptor)
        } catch {
            print("❌ Error fetching episodes for cleanup: \(error)")
            return
        }
        
        for episode in episodes {
            // Must have a local file and lastPlayed at least a week ago
            guard 
                let lastPlayed = episode.metaData?.lastPlayed,
                lastPlayed < oneWeekAgo,
                episode.metaData?.isAvailableLocally == true else { continue }
            
            if episode.playlist.count == 0 {
                print("🗑️ Deleting old download for episode: \(episode.title)")
                await episodeActor.deleteFile(episodeID: episode.id)
            }
        }
    }
}
