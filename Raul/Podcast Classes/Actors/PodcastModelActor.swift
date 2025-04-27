//
//  PodcastModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//

import SwiftData
import Foundation
import BasicLogger

@ModelActor
actor PodcastModelActor {
    
    func checkIfFeedHasBeenUpdated(_ podcastID: PersistentIdentifier) async ->Bool?{
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return nil}

        podcast.metaData?.feedUpdateCheckDate = Date()
        
        if let lastRefresh = podcast.metaData?.lastRefresh{
            if let serverLastModified = try? await podcast.feed?.status()?.lastModified {
                print("Server: \(serverLastModified.formatted()) vs Database: \(lastRefresh.formatted())")
      
                if serverLastModified > lastRefresh{
                    print("feed is new")
                    return true
                }else{
                    // feed on server is old
                    print("feed is old")
                    return false
                }
            }else{
                // server is not answering with a lastmodified Date
                print("no last modified date")
                
                return nil
            }
        }else{
            // feed has never been fetched before, no last modified date is set.
            print("feed is very new")
            return true
        }
    }

    func updatePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        guard let feedURL = podcast.feed else { return }
        
       guard await checkIfFeedHasBeenUpdated(podcastID) != false else { return }
        if podcast.metaData == nil {
            podcast.metaData = PodcastMetaData()
        }
        try modelContext.save()
        
        await BasicLogger.shared.log("Updating Podcast \(podcast.title)")
        
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        let parser = XMLParser(data: data)
        let podcastParser = PodcastParser()
        parser.delegate = podcastParser

        if parser.parse() {
            podcast.title = podcastParser.podcastDictArr["title"] as? String ?? ""
            podcast.author = podcastParser.podcastDictArr["author"] as? String ?? ""
            podcast.desc = podcastParser.podcastDictArr["description"] as? String ?? ""
            
            if let imageURL = podcastParser.podcastDictArr["coverImage"] as? String {
                podcast.coverImageURL = URL(string: imageURL)
            }
            
            podcast.lastBuildDate = Date.dateFromRFC1123(
                dateString: podcastParser.podcastDictArr["lastBuildDate"] as? String ?? ""
            )
            
            // Update episodes
            if let episodesData = podcastParser.podcastDictArr["episodes"] as? [[String: Any]] {
                
                
                
                
                var newEpisodes: [Episode] = []
               
                for episodeData in episodesData {
                    
                    guard  checkIfEpisodeExists(episodeData["guid"] as? String ?? "") ?? 0 < 1 else { continue }
                    
                    
                    if let episode = Episode(from: episodeData, podcast: podcast) {
                        newEpisodes.append(episode)
                    }else{
                        print("Episode already exists")

                    }
                }
                
            }

            do {
                podcast.metaData?.lastRefresh = Date()

                try modelContext.save()
            } catch {
                print("could not save modelContext")
            }
            
            podcast.metaData?.feedUpdated = true

        } else {
            throw parser.parserError ?? NSError(domain: "ParserError", code: -1, userInfo: nil)
        }
    }
    

    private func checkIfEpisodeExists(_ guid: String) -> Int? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.guid == guid  }
        )
        
        return try? modelContext.fetch(descriptor).count
    }
    
    func createPodcast(from url: URL) async throws -> PersistentIdentifier {
        // Check if podcast with this feed URL already exists
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == url }
        )
        
        if let existingPodcasts = try? modelContext.fetch(descriptor),
           let existingPodcast = existingPodcasts.first {
            // If podcast exists, update it and return its ID
            try await updatePodcast(existingPodcast.persistentModelID)
            return existingPodcast.persistentModelID
        }
        
        // Create new podcast if it doesn't exist
        let podcast = Podcast(feed: url)
        modelContext.insert(podcast)
        try modelContext.save()
        do {
            try await updatePodcast(podcast.persistentModelID)
            try await archiveEpisodes(of: podcast.persistentModelID)
            if let lastEpisode = podcast.episodes.sorted(by: { $0.publishDate ?? Date.distantPast < $1.publishDate ?? Date.distantPast }).last {
                try await unarchiveEpisode(lastEpisode.persistentModelID)
            }
        } catch {
            print("Could not update podcast: \(error)")
        }
        
        return podcast.persistentModelID
    }
    
    func archiveEpisodes(of podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        
        for episode in podcast.episodes {
            if episode.metaData == nil { episode.metaData = EpisodeMetaData() }
            episode.metaData?.isArchived = true
        }
        try modelContext.save()
        do {
            try await updatePodcast(podcast.persistentModelID)
        } catch {
            print("Could not update podcast: \(error)")
        }
        
        try modelContext.save()
    }
    
    func unarchiveEpisode(_ episodeID: PersistentIdentifier) async throws {
        guard var episode = modelContext.model(for: episodeID) as? Episode else { return }
        episode.metaData?.isArchived = false
        try modelContext.save()
    }
    
    func deletePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        if let episodeFolder = podcast.directoryURL {
            try? FileManager.default.removeItem(at: episodeFolder)
        }
        modelContext.delete(podcast)
        try modelContext.save()
    }
    
    func refreshAllPodcasts() async throws {
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try modelContext.fetch(descriptor)
        
        for podcast in podcasts {
            do {
                try await updatePodcast(podcast.persistentModelID)
            } catch {
                print("Failed to update podcast \(podcast.title): \(error)")
            }
        }
    }
}

