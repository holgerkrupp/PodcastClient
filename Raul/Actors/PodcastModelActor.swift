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
    func fetchPodcast(byID podcastID: UUID) async -> Podcast? {
        let predicate = #Predicate<Podcast> { podcast in
            podcast.id == podcastID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Podcast>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for podcast ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    func setFeedUpdated(_ metaDataID: PersistentIdentifier, to updated: Bool? = nil) async {
        guard let metaData = modelContext.model(for: metaDataID) as? PodcastMetaData else { return }
        metaData.feedUpdateCheckDate = Date()
        metaData.feedUpdated = updated
        modelContext.saveIfNeeded()
    }
    
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
    
    func checkIfFeedHasBeenUpdated(_ podcastUUID: UUID) async -> Bool? {
        // 1) Fetch the podcast
        guard let podcast = await fetchPodcast(byID: podcastUUID) else { return nil }

        // Ensure metaData exists
        if podcast.metaData == nil {
            let metaData = PodcastMetaData()
            modelContext.insert(metaData)
            podcast.metaData = metaData
            modelContext.saveIfNeeded()
        }

        guard let meta = podcast.metaData else { return nil }

        // 2) Snapshot only plain values / IDs
        let podcastIDRef = podcast.persistentModelID
        let metaIDRef = meta.persistentModelID
        let lastRefreshSnapshot = meta.lastRefresh
        let feedRef = podcast.feed   // must be a value type / URL / service object, not a model

        // 3) Async work using snapshots
        let serverLastModified = try? await feedRef?.status()?.lastModified

        // 4) Re-fetch fresh instances
        guard
            let freshPodcast = modelContext.model(for: podcastIDRef) as? Podcast,
            let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData
        else {
            return nil // deleted while we awaited
        }

        // 5) Safe updates
        if let server = serverLastModified {
            if let last = lastRefreshSnapshot {
                if server > last {
                    freshPodcast.message = nil
                    await setFeedUpdated(metaIDRef, to: true)
                    freshMeta.lastRefresh = server
                    freshMeta.feedUpdateCheckDate = Date()
                    modelContext.saveIfNeeded()
                    return true
                } else {
                    freshPodcast.message = nil
                    await setFeedUpdated(metaIDRef, to: false)
                    freshMeta.feedUpdateCheckDate = Date()
                    modelContext.saveIfNeeded()
                    return false
                }
            } else {
                // never refreshed before
                freshPodcast.message = nil
                await setFeedUpdated(metaIDRef, to: true)
                freshMeta.lastRefresh = server
                freshMeta.feedUpdateCheckDate = Date()
                modelContext.saveIfNeeded()
                return true
            }
        } else {
            // server gave no Last-Modified
            freshPodcast.message = nil
            await setFeedUpdated(metaIDRef, to: nil)
            freshMeta.feedUpdateCheckDate = Date()
            modelContext.saveIfNeeded()
            return nil
        }
    }

    func updatePodcast(_ podcastID: UUID, force: Bool? = false, silent: Bool? = false) async throws -> Bool{
        guard let podcast = await fetchPodcast(byID: podcastID) else { return false}
        guard let feedURL = podcast.feed else { return false }
 

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

        
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData  // Always fetch from server

        let (data, response) = try await URLSession.shared.data(for: request)
       
        
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
                    print("Episode \(episodeData["title"] ?? "unknown") found")
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
                            await EpisodeActor(modelContainer: modelContainer).processAfterCreation(episodeID: episode.id)
                        }else{
                            episode.metaData?.isInbox = false
                            episode.metaData?.status = .archived
                            modelContext.saveIfNeeded()
                        }
                    
                    }else{
                        print("Episode \(episodeData["title"] ?? "unknown") already exists")

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
            _ = try await updatePodcast(existingPodcast.id, silent: true)
            existingPodcast.message = nil
            return existingPodcast.persistentModelID
        }
        
        // Create new podcast if it doesn't exist
        
        
        let podcast = Podcast(feed: feedURL)
        modelContext.insert(podcast)
        modelContext.saveIfNeeded()
        do {
            _ = try await updatePodcast(podcast.id, silent: true)
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
        let ids = podcasts.map(\.id)

        let semaphore = AsyncSemaphore(value: 10) // 👈 max 5 at a time

        await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await semaphore.wait()
                    do {
                        let worker = PodcastModelActor(modelContainer: self.modelContainer)
                        _ = try await worker.updatePodcast(id)
                    } catch {
                        throw error
                    }
                    await semaphore.signal()
                }
            }
        }
    }
    
    /*
    func refreshAllPodcasts() async throws {
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try modelContext.fetch(descriptor)
        let ids = podcasts.map(\.persistentModelID)
        // Now leave actor isolation and kick off parallel updates:
         await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    // Create a new instance of the actor
                    let actor = PodcastModelActor(modelContainer: self.modelContainer)
                    _ = try await actor.updatePodcast(id)
                }
            }
        //    await group.waitForAll()
        }
    }
    */
}

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
