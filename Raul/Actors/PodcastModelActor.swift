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
    

    
    func safeFetchMeta(_ id: PersistentIdentifier) -> PodcastMetaData? {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    func checkIfFeedHasBeenUpdated(_ podcastUUID: UUID) async -> Bool? {
        // 1. Fetch podcast
        guard let podcast = await fetchPodcast(byID: podcastUUID) else { return nil }
        let podcastID = podcast.persistentModelID

        // Ensure metaData exists
        var metaID = podcast.metaData?.persistentModelID
        if metaID == nil {
            let meta = PodcastMetaData()
            modelContext.insert(meta)
            podcast.metaData = meta
            try? modelContext.save()
            metaID = meta.persistentModelID
        }

        // --- SAFELY snapshot lastRefresh ---
        var lastRefreshSnapshot: Date? = nil
        if let metaID,
           let freshMeta = safeFetchMeta(metaID) {
            lastRefreshSnapshot = freshMeta.lastRefresh
        }

        // Snapshot value properties (safe)
        let feedURL = podcast.feed

        // --- Async work with only value types ---
        let serverLastModified = try? await feedURL?.status()?.lastModified

        // --- Re-fetch fresh models after await ---
        guard
            let freshPodcast = modelContext.model(for: podcastID) as? Podcast,
            let metaID,
            let freshMeta = modelContext.model(for: metaID) as? PodcastMetaData
        else {
            return nil
        }

        // --- Compare & update ---
        if let serverLastModified,
           serverLastModified > (lastRefreshSnapshot ?? .distantPast) {
            
                await updateLastRefresh(for: metaID)

            /*
            
                let descriptor = FetchDescriptor<PodcastMetaData>(
                    predicate: #Predicate { $0.persistentModelID == metaID }
                )
                if let metaForUpdate = try? modelContext.fetch(descriptor).first {
                    metaForUpdate.lastRefresh = Date()
                    try? modelContext.save()
                }
            */
            
            return true
        }

        return false
    }
    
    
    func updateLastRefresh(for metadataID: PersistentIdentifier) async {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == metadataID }
        )
        var metaData = try? modelContext.fetch(descriptor).first
        metaData?.lastRefresh = Date()
        modelContext.saveIfNeeded()
    }

    func updatePodcast(_ podcastID: UUID, force: Bool? = false, silent: Bool? = false) async throws -> Bool {
        // Fetch podcast just long enough to snapshot IDs & primitives
        guard let podcast = await fetchPodcast(byID: podcastID) else { return false }
        guard let feedURL = podcast.feed else { return false }

    //    print("updating podcast: \(podcast.title ?? "unknown")")
        let podcastIDRef = podcast.persistentModelID
        var metaIDRef = podcast.metaData?.persistentModelID

        // Ensure metaData exists before any await
        if podcast.metaData == nil {
            let meta = PodcastMetaData()
            modelContext.insert(meta)
            podcast.metaData = meta
            modelContext.saveIfNeeded()
            metaIDRef = meta.persistentModelID
        }

        // Snapshot some plain values if needed
        let titleSnapshot = podcast.title

        // ⚠️ After this point: do not use `podcast` directly across awaits
        // ----------------------------------------------------------------

        // Update messages (still safe, no await yet)
        if let metaIDRef, let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData {
            freshMeta.message = "Refreshing Podcast ..."
            freshMeta.isUpdating = true
        }
        /*
        if let freshPodcast = modelContext.model(for: podcastIDRef) as? Podcast {
            freshPodcast.message = "Refreshing Podcast ..."
        }
         */
        modelContext.saveIfNeeded()

        // --- FIRST await boundary ---
        if force == false {
            guard await checkIfFeedHasBeenUpdated(podcastID) != false else {
                print("\(podcast.title ?? "unknown") not updated")

                if let metaIDRef, let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData {
                    freshMeta.isUpdating = false
                    freshMeta.message = nil
                }
                if let freshPodcast = modelContext.model(for: podcastIDRef) as? Podcast {
                    freshPodcast.message = nil
                }
                modelContext.saveIfNeeded()
                return false
            }
        }

        // --- SECOND await boundary ---
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)

        // Re-fetch podcast after await
        
        guard
              let metaIDRef,
              let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData else {
            return false
        }
         
      //  print("\(podcast.title ?? "unknown") reading feed")

        // Safe updates again
        freshMeta.message = "Reading Podcast Feed."
        podcast.message = "Reading Podcast Feed."
        modelContext.saveIfNeeded()

        // Parse XML
        let fullPodcast = try await PodcastParser.fetchAllPages(from: feedURL)

        // Re-fetch again after await
   

        // Update podcast details safely
        freshMeta.message = "Updating Podcast details"
        podcast.message = "Updating Podcast details"
        modelContext.saveIfNeeded()

        await updateDetails(podcast, fullPodcast: fullPodcast)
        
        podcast.message = nil

        // Final updates
        podcast.message = nil
        await updateLastRefresh(for: freshMeta.persistentModelID)
        freshMeta.isUpdating = false
        modelContext.saveIfNeeded()

        return true
    }
    
    func updateDetails(_ podcast: Podcast, fullPodcast: [String : Any], silent: Bool? = false) async{
        
        print("updateDetails for \(podcast.title ?? "unknown")")
        // Fetch podcast just long enough to snapshot IDs & primitives
      //  guard let podcast = await fetchPodcast(byID: podcastID) else { return nil }
        podcast.title = fullPodcast["title"] as? String ?? ""
        podcast.author = fullPodcast["itunes:author"] as? String
        podcast.desc = fullPodcast["description"] as? String
        podcast.copyright = fullPodcast["copyright"] as? String
        podcast.language = fullPodcast["language"] as? String
        podcast.link = URL(string: fullPodcast["link"] as? String ?? "")
        if let imageURL = fullPodcast["coverImage"] as? String {
            podcast.imageURL = URL(string: imageURL)
        }
        podcast.lastBuildDate = Date.dateFromRFC1123(
            dateString: fullPodcast["lastBuildDate"] as? String ?? ""
        )

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
        
        // Map podcast-level social interactions
        if let socialArr = fullPodcast["socialInteract"] as? [[String: Any]] {
            podcast.social = socialArr.compactMap { dict in
                guard
                    let proto = dict["protocol"] as? String,
                    let uriStr = dict["uri"] as? String,
                    let uri = URL(string: uriStr)
                else { return nil }
                let accountId = dict["accountId"] as? String
                let accountUrlString = dict["accountUrl"] as? String
                let accountURL = accountUrlString.flatMap(URL.init(string:))
                let priority = dict["priority"] as? Int
                return SocialInfo(url: uri, socialprotocol: proto, accountId: accountId, accountURL: accountURL, priority: priority)
            }
        } else if let socialArr = fullPodcast["socialInteract"] as? [SocialInfo] {
            podcast.social = socialArr
        }
       
        // Map podcast-level people
        if let peopleArr = fullPodcast["people"] as? [[String: Any]] {
            podcast.people = peopleArr.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let role = dict["role"] as? String
                let href = (dict["href"] as? String).flatMap(URL.init(string:))
                let img = (dict["img"] as? String).flatMap(URL.init(string:))
                return PersonInfo(name: name, role: role, href: href, img: img)
            }
        } else if let peopleArr = fullPodcast["people"] as? [PersonInfo] {
            podcast.people = peopleArr
        }
            
            // Update episodes
            if let episodesData = fullPodcast["episodes"] as? [[String: Any]] {
                
                podcast.metaData?.message = "Updating Podcast Episodes"
                podcast.message = "Updating Podcast Episodes"
                
                var newEpisodes: [Episode] = []
               
                for episodeData in episodesData {
                    
                    
                    if let episodes = podcast.episodes, !episodes.contains(where: { $0.guid == episodeData["guid"] as? String ?? "" }) {
                        
                        print("new episode: \(episodeData["title"] as? String ?? "")")
                        
                        if let episodeID = checkIfEpisodeExists(episodeData["guid"] as? String ?? "") {
                            print("already existing")
                            
                            linkEpisodeToPodcast(episodeID , podcast.id)
                            continue
                        }else if let episode = Episode(from: episodeData, podcast: podcast) {
                            print("newly created")
                            newEpisodes.append(episode)
                            modelContext.insert(episode)
                            modelContext.saveIfNeeded()
                            if silent == false{
                                print("NOT SILENT")
                                if episode.publishDate ?? Date() < episode.podcast?.metaData?.subscriptionDate ?? Date(timeIntervalSinceNow: -60*60*24*7) {
                                    
                                    print("episode is old")
                                       episode.metaData?.status = .archived
                                       episode.metaData?.isArchived = true
                                    episode.metaData?.isInbox = false
                                       
                                }else{
                                    print("episode is new")
                                    
                                    await EpisodeActor(modelContainer: modelContainer).processAfterCreation(episodeID: episode.id)
                                }
                            }else{
                                print("SILENT")

                                episode.metaData?.isInbox = false
                                episode.metaData?.status = .archived
                            }
                        
                        }
                    }
                    
                    

                }
                
                
            }


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
        
        print("createPodcast from url: \(url)")
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

        } catch {
            // print("Could not update podcast: \(error)")
        }
        modelContext.saveIfNeeded()
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

        let semaphore = AsyncSemaphore(value: 5) // 👈 max 5 at a time

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

