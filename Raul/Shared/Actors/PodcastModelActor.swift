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
    private let maximumTrustedHeaderSkipInterval: TimeInterval = 60 * 60 * 6

    private func reportProgress(
        _ update: SubscriptionProgressUpdate,
        using progressHandler: SubscriptionProgressHandler?
    ) async {
        guard let progressHandler else { return }
        await progressHandler(update)
    }

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metaData = podcast.metaData {
            return metaData
        }

        let metaData = PodcastMetaData()
        modelContext.insert(metaData)
        podcast.metaData = metaData
        modelContext.saveIfNeeded()
        return metaData
    }

    func setSubscriptionStatus(_ podcastID: PersistentIdentifier, isSubscribed: Bool) async {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        let metaData = ensureMetadata(for: podcast)

        metaData.isSubscribed = isSubscribed
        if isSubscribed {
            metaData.subscriptionDate = Date()
        }

        modelContext.saveIfNeeded()
    }

    
    func fetchPodcast(byFeed podcastFeed: URL) async -> Podcast? {
        let predicate = #Predicate<Podcast> { podcast in
            podcast.feed == podcastFeed
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Podcast>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for podcast Feed: \(podcastFeed), Error: \(error)")
            return nil
        }
    }
    
    func setFeedUpdated(_ metaDataID: PersistentIdentifier, to updated: Bool? = nil) async {
        guard let metaData = modelContext.model(for: metaDataID) as? PodcastMetaData else { return }
        metaData.feedUpdateCheckDate = Date()
        metaData.feedUpdated = updated
        modelContext.saveIfNeeded()
    }
    
    func linkEpisodeToPodcast(_ episodeURL: URL, _ podcastFeed: URL) async {
   
        guard let podcast = await fetchPodcast(byFeed: podcastFeed) else { return }
        let episodedescriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.url == episodeURL })

        guard let episode = try? modelContext.fetch(episodedescriptor).first else { return }
        if let episodes = podcast.episodes, !episodes.contains(where: { $0.url == episodeURL }) {
            episode.podcast = podcast
        }
      
        modelContext.saveIfNeeded()
    }

    private func episodeIdentifier(from episodeData: [String: Any]) -> String? {
        if let guid = episodeData["guid"] as? String, guid.isEmpty == false {
            return guid
        }

        if let podcastGUID = episodeData["podcast:guid"] as? String, podcastGUID.isEmpty == false {
            return podcastGUID
        }

        if let enclosure = (episodeData["enclosure"] as? [[String: Any]])?.first?["url"] as? String,
           enclosure.isEmpty == false {
            return enclosure
        }

        return nil
    }

    private func episodeURL(from episodeData: [String: Any]) -> URL? {
        guard let enclosure = (episodeData["enclosure"] as? [[String: Any]])?.first?["url"] as? String,
              enclosure.isEmpty == false else {
            return nil
        }

        return URL(string: enclosure)
    }

    private func existingEpisodeURL(identifier: String?, episodeURL: URL?) -> URL? {
        if let identifier {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.guid == identifier }
            )

            if let existingURL = (try? modelContext.fetch(descriptor))?.first?.url {
                return existingURL
            }
        }

        guard let episodeURL else { return nil }
        return fetchEpisode(byURL: episodeURL)?.url
    }

    private func fetchEpisode(byURL episodeURL: URL) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )

        return try? modelContext.fetch(descriptor).first
    }

    private func refreshFeedExternalFiles(
        for episodeURL: URL,
        from episodeData: [String: Any]
    ) {
        guard let episode = fetchEpisode(byURL: episodeURL) else { return }
        episode.refreshFeedExternalFiles(from: episodeData)
        modelContext.saveIfNeeded()
    }
    

    
    func safeFetchMeta(_ id: PersistentIdentifier) -> PodcastMetaData? {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    func checkIfFeedHasBeenUpdated(_ podcastFeed: URL) async -> Bool? {
        // 1. Fetch podcast
        guard let podcast = await fetchPodcast(byFeed: podcastFeed)  else { return nil }
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
        let status = try? await feedURL?.status()
        let serverLastModified = status?.lastModified
        let now = Date()
        



        // --- Re-fetch fresh models after await ---
        guard
            let freshPodcast = modelContext.model(for: podcastID) as? Podcast,
            let metaID,
            let freshMeta = modelContext.model(for: metaID) as? PodcastMetaData
        else {
            return nil
        }

       
        if let newURL = status?.newURL, newURL != feedURL, status?.statusCode == 301 {
            freshPodcast.feed = newURL
            modelContext.saveIfNeeded()
        }
        
        await setFeedUpdated(freshMeta.persistentModelID, to: nil)

        // Treat the preflight request as advisory only. Some feeds either reject HEAD
        // requests or return stale/missing Last-Modified values.
        guard let statusCode = status?.statusCode else {
            return nil
        }

        guard (200...299).contains(statusCode) || (300...399).contains(statusCode) else {
            return nil
        }

        guard let serverLastModified else {
            return nil
        }

        if serverLastModified > (lastRefreshSnapshot ?? .distantPast) {
            await setFeedUpdated(freshMeta.persistentModelID, to: true)
            return true
        }

        if let lastRefreshSnapshot,
           now.timeIntervalSince(lastRefreshSnapshot) > maximumTrustedHeaderSkipInterval {
            return nil
        }

        await setFeedUpdated(freshMeta.persistentModelID, to: false)
        return false
    }
    
    
    func updateLastRefresh(for metadataID: PersistentIdentifier) async {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == metadataID }
        )
        let metaData = try? modelContext.fetch(descriptor).first
        metaData?.lastRefresh = Date()
        metaData?.feedUpdateCheckDate = Date()
        modelContext.saveIfNeeded()
    }
    
    func updateFeedURL(_ podcastFeed: URL) async{
        guard let podcast = await fetchPodcast(byFeed: podcastFeed)  else { return  }
        guard let feedURL = podcast.feed else { return  }

        let reachable = await feedURL.absoluteString.reachabilityStatus()
        if let newURL = reachable?.finalURL, newURL != feedURL{
            podcast.feed = newURL
        }
    }

    func updatePodcast(
        _ podcastFeed: URL,
        force: Bool? = false,
        silent: Bool? = false,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        // Fetch podcast just long enough to snapshot IDs & primitives
        guard let podcast = await fetchPodcast(byFeed: podcastFeed) else { return false }
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
        await reportProgress(SubscriptionProgressUpdate(0.12, "Checking feed status"), using: progress)
        try Task.checkCancellation()

        // --- FIRST await boundary ---
        if force == false {
            guard await checkIfFeedHasBeenUpdated(podcastFeed) != false else {
                print("\(titleSnapshot) not updated")

                if let metaIDRef, let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData {
                    freshMeta.isUpdating = false
                    freshMeta.message = nil
                }
                if let freshPodcast = modelContext.model(for: podcastIDRef) as? Podcast {
                    freshPodcast.message = nil
                }
                modelContext.saveIfNeeded()
                await reportProgress(SubscriptionProgressUpdate(1.0, "Feed already up to date"), using: progress)
                return false
            }
        }
        try Task.checkCancellation()

        // --- SECOND await boundary ---
        guard
              let metaIDRef,
              let freshMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData,
              let freshPodcast = modelContext.model(for: podcastIDRef) as? Podcast else {
            return false
        }
         
        // Safe updates again
        freshMeta.message = "Reading Podcast Feed."
        freshPodcast.message = "Reading Podcast Feed."
        modelContext.saveIfNeeded()
        await reportProgress(SubscriptionProgressUpdate(0.32, "Downloading and parsing feed"), using: progress)
        try Task.checkCancellation()

        do {
            // Parse XML
            let fullPodcast = try await PodcastParser.fetchAllPages(from: feedURL)
            try Task.checkCancellation()

            guard
                let finalMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData,
                let finalPodcast = modelContext.model(for: podcastIDRef) as? Podcast
            else {
                return false
            }

            // Update podcast details safely
            finalMeta.message = "Updating Podcast details"
            finalPodcast.message = "Updating Podcast details"
            modelContext.saveIfNeeded()
            await reportProgress(SubscriptionProgressUpdate(0.56, "Updating podcast details"), using: progress)

            try await updateDetails(
                finalPodcast,
                fullPodcast: fullPodcast,
                silent: silent,
                progress: progress
            )

            finalPodcast.message = nil
            finalMeta.message = nil
            finalMeta.isUpdating = false
            finalMeta.feedUpdated = true
            await updateLastRefresh(for: finalMeta.persistentModelID)
            modelContext.saveIfNeeded()
            await reportProgress(SubscriptionProgressUpdate(1.0, "Subscription complete"), using: progress)

            return true
        } catch is CancellationError {
            if let cancelledMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData {
                cancelledMeta.isUpdating = false
                cancelledMeta.message = nil
            }
            if let cancelledPodcast = modelContext.model(for: podcastIDRef) as? Podcast {
                cancelledPodcast.message = nil
            }
            modelContext.saveIfNeeded()
            await reportProgress(SubscriptionProgressUpdate(1.0, "Refresh paused"), using: progress)
            return false
        } catch {
            if let failedMeta = modelContext.model(for: metaIDRef) as? PodcastMetaData {
                failedMeta.isUpdating = false
                failedMeta.message = nil
                failedMeta.feedUpdateCheckDate = Date()
                failedMeta.feedUpdated = nil
            }
            if let failedPodcast = modelContext.model(for: podcastIDRef) as? Podcast {
                failedPodcast.message = nil
            }
            modelContext.saveIfNeeded()
            await reportProgress(SubscriptionProgressUpdate(1.0, "Subscription failed"), using: progress)
            throw error
        }
    }
    
    func updateDetails(
        _ podcast: Podcast,
        fullPodcast: [String : Any],
        silent: Bool? = false,
        progress: SubscriptionProgressHandler? = nil
    ) async throws {
        print("updateDetails for \(podcast.title)")

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

        if let fundingArr = fullPodcast["funding"] as? [[String: String]] {
            podcast.funding = fundingArr.compactMap { dict in
                guard let string = dict["url"], let url = URL(string: string), let label = dict["label"] else { return nil }
                return FundingInfo(url: url, label: label)
            }
        } else if let fundingArr = fullPodcast["funding"] as? [FundingInfo] {
            podcast.funding = fundingArr
        }

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

        if let optionalTags = fullPodcast["optionalTags"] as? PodcastNamespaceOptionalTags,
           optionalTags.isEmpty == false {
            podcast.optionalTags = optionalTags
        } else {
            podcast.optionalTags = nil
        }

        if let episodesData = fullPodcast["episodes"] as? [[String: Any]] {
            podcast.metaData?.message = "Updating Podcast Episodes"
            podcast.message = "Updating Podcast Episodes"
            await reportProgress(SubscriptionProgressUpdate(0.7, "Creating database entries"), using: progress)

            let totalEpisodes = max(episodesData.count, 1)

            for (index, episodeData) in episodesData.enumerated() {
                try Task.checkCancellation()
                let episodeProgress = 0.7 + (Double(index) / Double(totalEpisodes)) * 0.25
                await reportProgress(
                    SubscriptionProgressUpdate(
                        episodeProgress,
                        "Importing episodes \(index + 1)/\(episodesData.count)"
                    ),
                    using: progress
                )

                let episodeIdentifier = episodeIdentifier(from: episodeData)
                let candidateEpisodeURL = episodeURL(from: episodeData)

                if let existingEpisode = podcast.episodes?.first(where: {
                    ($0.guid != nil && $0.guid == episodeIdentifier) || ($0.url != nil && $0.url == candidateEpisodeURL)
                }) {
                    existingEpisode.refreshFeedExternalFiles(from: episodeData)
                    existingEpisode.refreshOptionalTags(from: episodeData)
                    modelContext.saveIfNeeded()
                    continue
                }

                print("new episode: \(episodeData["title"] as? String ?? "")")

                if let episodeURL = existingEpisodeURL(identifier: episodeIdentifier, episodeURL: candidateEpisodeURL),
                   let feed = podcast.feed {
                    print("already existing")
                    await linkEpisodeToPodcast(episodeURL, feed)
                    refreshFeedExternalFiles(for: episodeURL, from: episodeData)
                    continue
                }

                guard let episode = Episode(from: episodeData, podcast: podcast) else { continue }

                print("newly created")
                modelContext.insert(episode)
                modelContext.saveIfNeeded()

                let episodeActor = EpisodeActor(modelContainer: modelContainer)
                if silent == false {
                    print("NOT SILENT")
                    if episode.publishDate ?? Date() < episode.podcast?.metaData?.subscriptionDate ?? Date(timeIntervalSinceNow: -60 * 60 * 24 * 7) {
                        print("episode is old")
                        await episodeActor.suppressEpisodeFromInbox(
                            episode.url,
                            reason: .backCatalogImport
                        )
                    } else {
                        print("episode is new")
                        if let episodeURL = episode.url {
                            await episodeActor.processAfterCreation(episodeURL: episodeURL)
                        }
                    }
                } else {
                    print("SILENT")
                    await episodeActor.suppressEpisodeFromInbox(
                        episode.url,
                        reason: .backCatalogImport
                    )
                }
            }

            await reportProgress(SubscriptionProgressUpdate(0.96, "Finalizing library updates"), using: progress)

            if let podcastFeed = podcast.feed {
                await EpisodeActor(modelContainer: modelContainer).applyAutomaticDownloadPolicy(for: podcastFeed)
            }
        }
    }
    
    func createPodcast(
        from url: URL,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> PersistentIdentifier {
        
        print("createPodcast from url: \(url)")
        await reportProgress(SubscriptionProgressUpdate(0.02, "Resolving podcast feed"), using: progress)
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
           let existingPodcast = existingPodcasts.first, let feed = existingPodcast.feed {
            // If podcast exists, update it and return its ID
            let metaData = ensureMetadata(for: existingPodcast)
            metaData.isSubscribed = true
            metaData.subscriptionDate = Date()
            modelContext.saveIfNeeded()

            await reportProgress(SubscriptionProgressUpdate(0.18, "Refreshing existing podcast"), using: progress)
            _ = try await updatePodcast(feed, force: true, silent: true, progress: progress)
            existingPodcast.message = nil
            return existingPodcast.persistentModelID
        }
        
        // Create new podcast if it doesn't exist
        
        
        let podcast = Podcast(feed: feedURL)
        modelContext.insert(podcast)
        modelContext.saveIfNeeded()
        await reportProgress(SubscriptionProgressUpdate(0.16, "Creating podcast record"), using: progress)
        if let feed = podcast.feed {
        do {
            
                _ = try await updatePodcast(feed, force: true, silent: true, progress: progress)
                podcast.message = nil
                await reportProgress(SubscriptionProgressUpdate(0.98, "Finalizing subscription"), using: progress)
            
        } catch {
            // print("Could not update podcast: \(error)")
        }
        modelContext.saveIfNeeded()
       
        }
        return podcast.persistentModelID
    }
    
    func archiveEpisodes(of podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        if let episodes = podcast.episodes{
            for episode in episodes {
                let episodeActor = EpisodeActor(modelContainer: modelContainer)
                await episodeActor.archiveEpisode(episode.url)
            }
            modelContext.saveIfNeeded()
        }
    }
    
    func archiveEpisodes(episodeURLs: [URL?]) async throws {
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episodeURL in episodeURLs {
            await episodeActor.archiveEpisode(episodeURL)
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
            await episodeActor.archiveEpisode(episode.url)

        }
        modelContext.saveIfNeeded()
    }
    
    func unarchiveEpisode(_ episodeID: PersistentIdentifier) async throws {
        
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        episode.metaData?.isArchived = false
        episode.metaData?.isInbox = true
        episode.metaData?.status = .inbox
        episode.metaData?.archivedAt = nil
        episode.metaData?.systemSuppressionReason = nil

        modelContext.saveIfNeeded()
    }
    
    func deleteEpisode(_ episodeID: PersistentIdentifier) async throws {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        if episode.source != .sideLoaded {
            await EpisodeActor(modelContainer: modelContainer).deleteFile(episodeURL: episode.url)
        }
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
      //  let descriptor = FetchDescriptor<Podcast>()
        
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { podcast in
                podcast.metaData != nil && podcast.metaData!.isSubscribed != false
            }
        )
        
        
        
        let podcasts = try modelContext.fetch(descriptor)
        let feeds = podcasts.map(\.feed)

        let semaphore = AsyncSemaphore(value: 5) // 👈 max 5 at a time

        await withThrowingTaskGroup(of: Void.self) { group in
            for feed in feeds {
                if let feed{
                    group.addTask {
                        await semaphore.wait()
                        do {
                            let worker = PodcastModelActor(modelContainer: self.modelContainer)
                            _ = try await worker.updatePodcast(feed)
                        } catch {
                            throw error
                        }
                        await semaphore.signal()
                    }
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
