//
//  EpisodeTranscriptActor.swift
//  Raul
//
//  Created by Holger Krupp on 08.04.25.
//
import SwiftData
import Foundation

@ModelActor
actor EpisodeActor {

    func markEpisodeAvailable(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        episode.downloadStatus.isDownloading = false
        try? modelContext.save()
           
               
        await self.downloadTranscript(episode.persistentModelID)
            
        
    }
    
    
    func downloadTranscript(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }

        if episode.transcriptData == nil {
            if let vttFileString = episode.transcripts.first(where: {$0.type == "text/vtt"})?.url,
               let vttURL = URL(string: vttFileString) {
                if let vttData = try? await URLSession(configuration: .default).data(from: vttURL) {
                   
                    episode.transcriptData = String(decoding: vttData.0, as: UTF8.self)
                    try? modelContext.save()
                }
            }
        }
        return
    }
}
