//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData
import BasicLogger


@ModelActor
actor SubscriptionManager:NSObject{
    

    var podcasts : [Podcast] = []
    var opmlParser = OPMLParser()
   // var podcastParser = PodcastParser()

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metaData = podcast.metaData {
            return metaData
        }

        let metaData = PodcastMetaData()
        modelContext.insert(metaData)
        podcast.metaData = metaData
        return metaData
    }

    private func applyFeedPreview(_ podcastFeed: PodcastFeed, to podcast: Podcast) {
        podcast.title = podcastFeed.title ?? podcast.title
        podcast.desc = podcastFeed.description ?? podcast.desc
        podcast.author = podcastFeed.artist ?? podcast.author

        if let artworkURL = podcastFeed.artworkURL {
            podcast.imageURL = artworkURL
        }
    }
    
     func fetchData() {
        
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.metaData?.isSubscribed ?? true == true },
            sortBy: [SortDescriptor(\.title)]
        )
        if let fetchresult = try? modelContext.fetch(descriptor){
            podcasts = fetchresult
        }
        
    }
    
    
    func contains(url: URL) -> Bool{
        if (podcasts.map { $0.feed }.contains(url) ? true : false){
            return true
        }else{
            return false
        }
    }
    
    func read(file url: URL) -> [PodcastFeed]?{
        var newPodcasts: [PodcastFeed] = []
        
        // print("subscriptionmanager: read \(url.absoluteString)")
        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }

        
        if let data = try? Data(contentsOf: url){
            fetchData()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = true
            parser.delegate = opmlParser
            if parser.parse(){
                
                if let feeds = (parser.delegate as? OPMLParser)?.podcastFeeds {
                    newPodcasts = feeds
                    let podcastURLs = podcasts.map { $0.feed }
                    

                    for index in newPodcasts.indices {
                        newPodcasts[index].existing = podcastURLs.contains(newPodcasts[index].url) ? true : false
                    }
                    
                }
                return newPodcasts
            }
            
            
        }else{
            // print("could not read data from OPML file")
        }
        return nil
    }
    

    enum SubscribeError: Error {
        case existing, parsing, loadfeed
        
        var localizedDescription:String{
            switch self {
            case .existing:
                "Podcast already subscribed to"
            case .parsing:
                "Could not parse feed"
            case .loadfeed:
                "Could not load feed"
            }
        }
        
        
        
    }

    
    func subscribe(all urls:[URL?], progress: SubscriptionProgressHandler? = nil) async{
        
        
        let validURLs = urls.compactMap { $0 }
        let total = max(validURLs.count, 1)

        for (index, url) in validURLs.enumerated() {
            do {
                let _ = try await PodcastModelActor(modelContainer: modelContainer).createPodcast(from: url) { update in
                    guard let progress else { return }
                    let overall = (Double(index) + update.fractionCompleted) / Double(total)
                    await progress(SubscriptionProgressUpdate(overall, update.message))
                }
            } catch {
                print(error)
            }
        }
    }

    func addToLibrary(
        _ podcastFeed: PodcastFeed,
        subscribe: Bool,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> PersistentIdentifier {
        guard let url = podcastFeed.url else {
            throw SubscribeError.loadfeed
        }

        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == url }
        )

        let podcast: Podcast
        if let existingPodcast = (try? modelContext.fetch(descriptor))?.first {
            podcast = existingPodcast
            applyFeedPreview(podcastFeed, to: existingPodcast)

            let metadata = ensureMetadata(for: existingPodcast)
            if subscribe {
                metadata.isSubscribed = true
                metadata.subscriptionDate = Date()
            }
        } else {
            let newPodcast = Podcast(from: podcastFeed)
            let metadata = newPodcast.metaData ?? PodcastMetaData()
            newPodcast.metaData = metadata
            metadata.isSubscribed = subscribe
            metadata.subscriptionDate = subscribe ? Date() : nil
            modelContext.insert(newPodcast)
            podcast = newPodcast
        }

        modelContext.saveIfNeeded()

        if let progress {
            await progress(
                SubscriptionProgressUpdate(
                    0.08,
                    subscribe ? "Preparing subscription" : "Preparing podcast"
                )
            )
        }

        if let feed = podcast.feed {
            let worker = PodcastModelActor(modelContainer: modelContainer)
            _ = try await worker.updatePodcast(feed, force: true, silent: true) { update in
                guard let progress else { return }

                let message: String
                switch update.message {
                case "Subscription complete" where subscribe == false:
                    message = "Podcast ready"
                case "Subscription failed" where subscribe == false:
                    message = "Podcast import failed"
                default:
                    message = update.message
                }

                await progress(SubscriptionProgressUpdate(update.fractionCompleted, message))
            }
        }

        if subscribe == false {
            let metadata = ensureMetadata(for: podcast)
            metadata.isSubscribed = false
            metadata.subscriptionDate = nil
            modelContext.saveIfNeeded()
        }

        return podcast.persistentModelID
    }
    
    
    

    func subscribe_old(all newPodcasts: [PodcastFeed]) async {
        let podcastSemaphore = AsyncSemaphore(value: 1)
        await withTaskGroup(of: Void.self) { group in
            for podcast in newPodcasts {
                if let url = podcast.url {
                    group.addTask {
                        await podcastSemaphore.wait()
                        do {
                            let worker = PodcastModelActor(modelContainer: self.modelContainer)
                            _ = try await worker.createPodcast(from: url)
                        } catch {
                            print(error)
                        }
                        await podcastSemaphore.signal()
                    }
                }
            }
        }
    }
    
    
    func subscribe(all newPodcasts: [PodcastFeed], progress: SubscriptionProgressHandler? = nil) async {
        
        // 1. SERIAL PHASE: Mass-insert all new podcasts quickly.
        //    Perform this on a single ModelContext serially to avoid "Database busy" errors
        //    for the crucial insertion step.
        
        var newPodcastFeeds: Set<URL> = []
        
        for podcastFeed in newPodcasts {
            guard let url = podcastFeed.url else { continue }

            
            
            
            
            // Check if podcast with this feed URL already exists (if PodcastFeed.existing is not reliable)
            let descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { $0.feed == url }
            )
            
            // This fetch/insert/save is now done serially, preventing contention.
            if let existingPodcasts = try? modelContext.fetch(descriptor),
               let existingPodcast = existingPodcasts.first, let existinURL = existingPodcast.feed {
                // Already exists, maybe update some basic properties from feedData if needed
                existingPodcast.title = podcastFeed.title ?? existingPodcast.title
                existingPodcast.metaData?.isSubscribed = true
                existingPodcast.metaData?.subscriptionDate = Date()
                // existingPodcast.message = nil
                
                newPodcastFeeds.insert(existinURL)
                
            } else {
                let podcast = Podcast(from: podcastFeed) // Use the fast, new initializer
                if let feed = podcast.feed{
                    modelContext.insert(podcast)
                    newPodcastFeeds.insert(feed)
                }
               
            }
        }
        
        dump(newPodcastFeeds)
        
        // Commit all changes from the serial inserts at once.
        // This is one large, safe save operation.
        modelContext.saveIfNeeded()
        
        do{
            let worker = PodcastModelActor(modelContainer: self.modelContainer)
            let feeds = Array(newPodcastFeeds)
            let total = max(feeds.count, 1)

            for (index, feed) in feeds.enumerated() {
                print("updating podcast: \(feed)")
                _ = try await worker.updatePodcast(feed, force: true, silent: true) { update in
                    guard let progress else { return }
                    let overall = (Double(index) + update.fractionCompleted) / Double(total)
                    await progress(SubscriptionProgressUpdate(overall, update.message))
                }
            }
            if let progress {
                await progress(SubscriptionProgressUpdate(1.0, "Subscription complete"))
            }
        }catch{
            print("could not refresh podcasts")
        }
    }
    
    func deleteAllPodcasts() async {
        let descriptor = FetchDescriptor<Podcast>()
        do {
            let all = try modelContext.fetch(descriptor)
            for podcast in all {
                modelContext.delete(podcast)
            }
            try modelContext.save()
        } catch {
            print("Failed to delete all podcasts: \(error)")
        }
        let downloadedFilesManager = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        try? downloadedFilesManager.deleteAllFiles()
    }
    
    
    //MARK: Background
    //the next functions are for background refresh activites. but could be also used in other occations
    

    
    func bgupdateFeeds() async{
        // this updates the feeds. It takes more time
        // check only those that are not marked as old during the last run
      
       //  await BasicLogger.shared.log("bgupdateFeeds")
        

            setLastRefreshDate()
            fetchData()
        //let all = podcasts.count
        var updated = 0
            for podcast in podcasts.sorted(by: { lhs, rhs in
                lhs.metaData?.feedUpdateCheckDate ?? Date() < rhs.metaData?.feedUpdateCheckDate ?? Date()
            }){
                if let feed = podcast.feed{
                    let new = try? await PodcastModelActor(modelContainer: modelContainer).updatePodcast(feed)
                    podcast.message = nil
                    if new == true { updated += 1}
                }
            }
            WatchSyncCoordinator.refreshSoon()
    }
    
    func getLastRefreshDate() -> Date? {
        let lastDate = Date.dateFromRFC1123(dateString: UserDefaults.standard.string(forKey: "LastBackgroundRefresh") ?? "")
        return lastDate
    }
    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().RFC1123String(), forKey: "LastBackgroundRefresh")
    }
    
    private func latestFetchedEpisode(for podcast: Podcast) -> Episode? {
        podcast.episodes?.max {
            ($0.publishDate ?? .distantPast) < ($1.publishDate ?? .distantPast)
        }
    }

    private func opmlAttribute(_ name: String, _ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "" }
        return " \(name)=\"\(value.xmlEscaped)\""
    }

    func generateOPML() -> String {
        fetchData()
        // print("generate OPML")
        var opmlString = """
    <?xml version="1.0" encoding="UTF-8"?>\n
    <opml version="1.1">\n
        <head>\n
            <title>Up Next Podcasts</title>\n
        </head>\n
        <body>\n
    """
        
        for podcast in podcasts {
            let latestEpisode = latestFetchedEpisode(for: podcast)
            let lastRefresh = podcast.metaData?.lastRefresh?.opmlMetadataString()
            let lastEpisodeDate = latestEpisode?.publishDate?.opmlMetadataString()
            let lastEpisodeURL = latestEpisode?.url?.absoluteString

            opmlString += """
            <outline text="\(podcast.title.xmlEscaped)" type="rss" xmlUrl="\((podcast.feed?.absoluteString ?? "").xmlEscaped)"\(opmlAttribute("upnextLastRefresh", lastRefresh))\(opmlAttribute("upnextLastEpisodeDate", lastEpisodeDate))\(opmlAttribute("upnextLastEpisodeURL", lastEpisodeURL)) />\n
        """
        }
        
        opmlString += """
        </body>\n
    </opml>\n
    """
        
        return opmlString
    }
    



}

extension String {
    var xmlEscaped: String {
        var escaped = self
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }
}
