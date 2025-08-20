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
    
    func linkEpisodeToPodcast(_ episodeID: UUID, _ podcastID: UUID) {
        // Fetch fresh in the ModelActor
        let podcastdescriptor = FetchDescriptor<Podcast>(predicate: #Predicate<Podcast> { $0.id == podcastID })
        guard let podcast = try? modelContext.fetch(podcastdescriptor).first else { return }
        let episodedescriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.id == episodeID })

        guard let episode = try? modelContext.fetch(episodedescriptor).first else { return }
        if let episodes = podcast.episodes, !episodes.contains(where: { $0.id == episodeID }) {
            episode.podcast = podcast
        }
      
        modelContext.saveIfNeeded()
    }
    
    func checkIfFeedHasBeenUpdated(_ podcastID: PersistentIdentifier) async ->Bool?{
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return nil}
        podcast.message = "Checking if podcast has been updated."
        podcast.metaData?.feedUpdateCheckDate = Date()
        
        if let lastRefresh = podcast.metaData?.lastRefresh{
            if let serverLastModified = try? await podcast.feed?.status()?.lastModified {
                
                // print("Server: \(serverLastModified.formatted()) vs Database: \(lastRefresh.formatted())")
                if serverLastModified > lastRefresh{
                    // print("feed is new")
                    podcast.message = nil
                    podcast.metaData?.feedUpdated = true
                    modelContext.saveIfNeeded()
                    return true
                }else{
                    // feed on server is old
                    // print("feed is old")
                    podcast.metaData?.feedUpdated = false
                    podcast.message = nil
                     modelContext.saveIfNeeded()

                    return false
                }
            }else{
                // server is not answering with a lastmodified Date
                // print("no last modified date")
                podcast.metaData?.feedUpdated = nil
                podcast.message = nil
                modelContext.saveIfNeeded()

                return nil
            }
        }else{
            // feed has never been fetched before, no last modified date is set.
            // print("feed is very new")
            podcast.metaData?.feedUpdated = true
            podcast.message = nil
            modelContext.saveIfNeeded()
            return true
        }
    }

    func updatePodcast(_ podcastID: PersistentIdentifier, force: Bool? = false, silent: Bool? = false) async throws -> Bool{
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return false }
        guard let feedURL = podcast.feed else { return false }
        print("updatePodcast - \(podcast.title)")

        if podcast.metaData == nil {
            print("updatePodcast - no metadata - \(podcast.title)")
            let metaData = PodcastMetaData()
            
            modelContext.insert(metaData)
            podcast.metaData = metaData
        }

        podcast.metaData?.message = "Refreshing Podcast ..."
        podcast.message = "Refreshing Podcast ..."
        
        podcast.metaData?.isUpdating = true
        modelContext.saveIfNeeded()
        
        podcast.metaData?.message = "Checking if podcast has been updated."
        

        if force == false {
            guard await checkIfFeedHasBeenUpdated(podcastID) != false else {
                podcast.metaData?.isUpdating = false
                podcast.message = nil

                return false }
        }

        podcast.metaData?.message = "Downloading Podcast Feed."
        podcast.message = "Downloading Podcast Feed."

        
        
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        let parser = XMLParser(data: data)
        let podcastParser = PodcastParser()
        parser.delegate = podcastParser
        
        podcast.metaData?.message = "Reading Podcast Feed."
        podcast.message = "Reading Podcast Feed."


        let fullPodcast = try await PodcastParser.fetchAllPages(from: feedURL)

        podcast.metaData?.message = "Updating Podcast details"
        podcast.message = "Updating Podcast details"

            podcast.title = fullPodcast["title"] as? String ?? ""
            podcast.author = fullPodcast["itunes:author"] as? String
            podcast.desc = fullPodcast["description"] as? String
            podcast.copyright = fullPodcast["copyright"] as? String 
            
            podcast.language = fullPodcast["language"] as? String
            
            podcast.link = URL(string: fullPodcast["link"] as? String ?? "")
            
            if let imageURL = fullPodcast["coverImage"] as? String {
                podcast.imageURL = URL(string: imageURL)
             //   await downloadCoverArt(podcastID)
            }
            
            podcast.lastBuildDate = Date.dateFromRFC1123(
                dateString: fullPodcast["lastBuildDate"] as? String ?? ""
            )
        
        if let fundingArr = fullPodcast["funding"] as? [[String: String]] {
            podcast.funding = fundingArr.compactMap { dict in
                guard let string = dict["url"], let url = URL(string: string), let label = dict["label"] else { return nil }
                return FundingInfo(url: url, label: label)
            }
        } else if let fundingArr = fullPodcast["funding"] as? [FundingInfo] {
            podcast.funding = fundingArr
        }
       
            
            // Update episodes
            if let episodesData = fullPodcast["episodes"] as? [[String: Any]] {
                
                podcast.metaData?.message = "Updating Podcast Episodes"
                podcast.message = "Updating Podcast Episodes"

                
                var newEpisodes: [Episode] = []
               
                for episodeData in episodesData {
                    let episodeID = checkIfEpisodeExists(episodeData["guid"] as? String ?? "")
                    if let episodeID {
                      //  // print("Episode exists")
                        if let episodes = podcast.episodes, !episodes.contains(where: { $0.guid == episodeData["guid"] as? String ?? "" }) {
                            linkEpisodeToPodcast(episodeID , podcast.id)
                            modelContext.saveIfNeeded()

                        }
                        continue
                    }
                    
                    
                    if let episode = Episode(from: episodeData, podcast: podcast) {
                        newEpisodes.append(episode)
                        modelContext.saveIfNeeded()
                        
                        if silent == false{
                           // await NotificationManager().sendNotification(title: episode.podcast?.title ?? "New Episode", body: episode.title) // moved to EpisodeActor
                            await EpisodeActor(modelContainer: modelContainer).processAfterCreation(episodeID: episode.id)
                        }else{
                            episode.metaData?.isInbox = false
                            episode.metaData?.status = .archived
                            modelContext.saveIfNeeded()
                        }
                    
                    }else{
                        // print("Episode already exists")

                    }
                }
                
                
            }

        podcast.message = nil
                podcast.metaData?.lastRefresh = Date()
                podcast.metaData?.isUpdating = false
                modelContext.saveIfNeeded()
            
        return true
 }
    


    private func checkIfEpisodeExists(_ guid: String) -> UUID? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.guid == guid  }
        )
        
        let episodes = try? modelContext.fetch(descriptor)
 //       // print("checking if episode exists \(guid) - count: \(episodes?.count.description ?? "nil")")
        return episodes?.first?.id
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
            _ = try await updatePodcast(existingPodcast.persistentModelID, silent: true)
            existingPodcast.message = nil
            return existingPodcast.persistentModelID
        }
        
        // Create new podcast if it doesn't exist
        
        
        let podcast = Podcast(feed: feedURL)
        modelContext.insert(podcast)
        modelContext.saveIfNeeded()
        do {
            _ = try await updatePodcast(podcast.persistentModelID, silent: true)
            podcast.message = nil
            try await archiveEpisodes(of: podcast.persistentModelID)
            /*
             
             // The original idea was to keep the newest episode of a newly subscribed podcast in the Inbox, but i think this
            if let lastEpisode = podcast.episodes.sorted(by: { $0.publishDate ?? Date.distantPast < $1.publishDate ?? Date.distantPast }).last {
                try await unarchiveEpisode(lastEpisode.persistentModelID)
            }
             */
        } catch {
            // print("Could not update podcast: \(error)")
        }
        
        return podcast.persistentModelID
    }
    
    func archiveEpisodes(of podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        if let episodes = podcast.episodes{
            for episode in episodes {
                let episodeActor = EpisodeActor(modelContainer: modelContainer)
                await episodeActor.archiveEpisode(episodeID: episode.id)
            }
            modelContext.saveIfNeeded()
        }
    }
    
    func archiveEpisodes(episodeIDs: [UUID]) async throws {
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episodeID in episodeIDs {
            await episodeActor.archiveEpisode(episodeID: episodeID)
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

        modelContext.saveIfNeeded()
    }
    
    func deleteEpisode(_ episodeID: PersistentIdentifier) async throws {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        await EpisodeActor(modelContainer: modelContainer).deleteFile(episodeID: episode.id)
        modelContext.delete(episode)
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
                _ = try await updatePodcast(podcast.persistentModelID)
                podcast.message = nil
            } catch {
                // print("Failed to update podcast \(podcast.title): \(error)")
            }
        }
        
    }
}

