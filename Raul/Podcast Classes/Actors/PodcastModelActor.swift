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
                await BasicLogger.shared.log("\(podcast.title) Server: \(serverLastModified.formatted()) vs Database: \(lastRefresh.formatted())")
                if serverLastModified > lastRefresh{
                    print("feed is new")
                    podcast.metaData?.feedUpdated = true
                    modelContext.saveIfNeeded()
                    return true
                }else{
                    // feed on server is old
                    print("feed is old")
                    podcast.metaData?.feedUpdated = false
                     modelContext.saveIfNeeded()

                    return false
                }
            }else{
                // server is not answering with a lastmodified Date
                print("no last modified date")
                podcast.metaData?.feedUpdated = nil
                modelContext.saveIfNeeded()

                return nil
            }
        }else{
            // feed has never been fetched before, no last modified date is set.
            print("feed is very new")
            await BasicLogger.shared.log("\(podcast.title) feed has never been fetched before")
            podcast.metaData?.feedUpdated = true
            modelContext.saveIfNeeded()
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
         modelContext.saveIfNeeded()
        
        await BasicLogger.shared.log("Updating Podcast \(podcast.title)")
        
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        let parser = XMLParser(data: data)
        let podcastParser = PodcastParser()
        parser.delegate = podcastParser

        if parser.parse() {
            podcast.title = podcastParser.podcastDictArr["title"] as? String ?? ""
            podcast.author = podcastParser.podcastDictArr["itunes:author"] as? String ?? ""
            podcast.desc = podcastParser.podcastDictArr["description"] as? String ?? ""
            podcast.copyright = podcastParser.podcastDictArr["copyright"] as? String ?? ""
            podcast.link = URL(string: podcastParser.podcastDictArr["link"] as? String ?? "")
            if let imageURL = podcastParser.podcastDictArr["coverImage"] as? String {
                podcast.imageURL = URL(string: imageURL)
             //   await downloadCoverArt(podcastID)
            }
            
            podcast.lastBuildDate = Date.dateFromRFC1123(
                dateString: podcastParser.podcastDictArr["lastBuildDate"] as? String ?? ""
            )
            
            // Update episodes
            if let episodesData = podcastParser.podcastDictArr["episodes"] as? [[String: Any]] {
                
                var newEpisodes: [Episode] = []
               
                for episodeData in episodesData {
                    
                    guard  checkIfEpisodeExists(episodeData["guid"] as? String ?? "") ?? 0 < 1 else {
                        print("Episode exists")
                        continue
                    }
                    
                    
                    if let episode = Episode(from: episodeData, podcast: podcast) {
                        newEpisodes.append(episode)
                    }else{
                        print("Episode already exists")

                    }
                }
                modelContext.saveIfNeeded()
                
            }

          
                podcast.metaData?.lastRefresh = Date()

                modelContext.saveIfNeeded()
            
            
          

        } else {
            throw parser.parserError ?? NSError(domain: "ParserError", code: -1, userInfo: nil)
        }
    }
    
    func downloadCoverArt(_ podcastID: PersistentIdentifier) async  {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        guard let coverURL = podcast.imageURL else {
            print("❌ Podcast does not have a cover")
            return }
        let item = await DownloadManager.shared.download(from: coverURL, saveTo: podcast.coverFileLocation)
        print("saving cover to \(String(describing: podcast.coverFileLocation))")
       
    }

    private func checkIfEpisodeExists(_ guid: String) -> Int? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.guid == guid  }
        )
        
        let count = try? modelContext.fetch(descriptor).count
        print("checking if episode exists \(guid) - count: \(count?.description ?? "nil")")
        return count
    }
    
    func createPodcast(from url: URL) async throws -> PersistentIdentifier {
        // Check URL STATUS
        var feedURL = url
        let status = try await url.status()
        
        switch status?.statusCode {
        case 200:
            feedURL = url
        case 404:
            throw SubscriptionManager.SubscribeError.loadfeed
        case 410:
            if let newURL = status?.newURL{
                feedURL = newURL
            }else{
               throw SubscriptionManager.SubscribeError.loadfeed
            }
        default:
            feedURL = url
        }
        
        
        
        
        
        
        
        
        // Check if podcast with this feed URL already exists
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == feedURL }
        )
        
        if let existingPodcasts = try? modelContext.fetch(descriptor),
           let existingPodcast = existingPodcasts.first {
            // If podcast exists, update it and return its ID
            try await updatePodcast(existingPodcast.persistentModelID)
            return existingPodcast.persistentModelID
        }
        
        // Create new podcast if it doesn't exist
        
        
        let podcast = Podcast(feed: feedURL)
        modelContext.insert(podcast)
        modelContext.saveIfNeeded()
        do {
            try await updatePodcast(podcast.persistentModelID)
            try await archiveEpisodes(of: podcast.persistentModelID)
            /*
             
             // The original idea was to keep the newest episode of a newly subscribed podcast in the Inbox, but i think this
            if let lastEpisode = podcast.episodes.sorted(by: { $0.publishDate ?? Date.distantPast < $1.publishDate ?? Date.distantPast }).last {
                try await unarchiveEpisode(lastEpisode.persistentModelID)
            }
             */
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
            episode.metaData?.isInbox = false
            episode.metaData?.status = .archived
        }
        modelContext.saveIfNeeded()

    }
    
    func archiveInboxEpisodes() async throws {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.metaData?.isInbox == true  }
        )
        let episodes = try modelContext.fetch(descriptor)
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episode in episodes {
            await episodeActor.archiveEpisode(episodeID: episode.id)

        }
        modelContext.saveIfNeeded()
    }
    
    func unarchiveEpisode(_ episodeID: PersistentIdentifier) async throws {
        
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        episode.metaData?.isArchived = false
        episode.metaData?.isInbox = true
        episode.metaData?.status = .inbox

        await BasicLogger.shared.log("Unarchiving episode \(episode.title)")
        modelContext.saveIfNeeded()
    }
    
    func deletePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        if let episodeFolder = podcast.directoryURL {
            try? FileManager.default.removeItem(at: episodeFolder)
        }
        modelContext.delete(podcast)
        modelContext.saveIfNeeded()
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

