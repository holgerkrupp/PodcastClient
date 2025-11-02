//
//  SubscriptionActor.swift
//  Raul
//
//  Created by Holger Krupp on 03.10.25.
//

import Foundation
import SwiftData
import BasicLogger




@ModelActor
actor SubscriptionActor:NSObject{
    
    
    
    var podcasts : [Podcast] = []
    var opmlParser = OPMLParser()
    
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

    
    func subscribe(all urls:[URL?]) async{
        
        
        for url in urls {
            if let url{
                // print("start subscribe for \(url.absoluteString)")
                do {
                    let _ = try await PodcastModelActor(modelContainer: modelContainer).createPodcast(from: url)
                    
                } catch {
                    print(error)
                }
                
                // print("end subscribe for \(url.absoluteString)")

            }
            
        }
    }
    
    func subscribe(all newPodcasts: [PodcastFeed]) async {
        
        // 1. SERIAL PHASE: Mass-insert all new podcasts quickly.
        //    Perform this on a single ModelContext serially to avoid "Database busy" errors
        //    for the crucial insertion step.
        
        var newPodcastFeeds: Set<URL?> = []
        
        
        for podcastFeed in newPodcasts {
            guard let url = podcastFeed.url else { continue }

            
            
            // Check if podcast with this feed URL already exists (if PodcastFeed.existing is not reliable)
            let descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { $0.feed == url }
            )
            
            // This fetch/insert/save is now done serially, preventing contention.
            if let existingPodcasts = try? modelContext.fetch(descriptor),
               let existingPodcast = existingPodcasts.first {
                // Already exists, maybe update some basic properties from feedData if needed
                existingPodcast.title = podcastFeed.title ?? existingPodcast.title
                // existingPodcast.message = nil
                
                
                newPodcastFeeds.insert(existingPodcast.feed)
                
            } else {
                let podcast = Podcast(from: podcastFeed) // Use the fast, new initializer
               
                modelContext.insert(podcast)
                
                
                newPodcastFeeds.insert(podcast.feed)
            }
        }
        
        dump(newPodcastFeeds)
        
        // Commit all changes from the serial inserts at once.
        // This is one large, safe save operation.
        modelContext.saveIfNeeded()
        
        do{
            let worker = PodcastModelActor(modelContainer: self.modelContainer)
            for feed in newPodcastFeeds{
                if let feed{
                    print("updating podcast: \(feed)")
                    _ = try await worker.updatePodcast(feed, force: true, silent: true)
                }
            }
        }catch{
            print("could not refresh podcasts")
        }
    }
    
    /// Removes duplicate Podcast records that share the same feed URL, keeping the most recently refreshed one.
    /// Chooses the survivor by comparing `metaData?.lastRefresh` (nil treated as distantPast).
    /// Performs deletions and saves the context.
    func cleanupDuplicates() async {
        print("Starting duplicate cleanup...")
        do {
            // 1. Fetch all podcasts
            let allPodcasts = try modelContext.fetch(FetchDescriptor<Podcast>())

            // 2. Group podcasts by their unique feed URL
            let groupedPodcasts = Dictionary(grouping: allPodcasts) { $0.feed }

            for (_, group) in groupedPodcasts {
                // Only process groups with more than one item (duplicates)
                guard group.count > 1 else { continue }

                // 3. Sort by last refresh date so the first is the survivor (most recently refreshed)
                let sortedGroup = group.sorted {
                    ($0.metaData?.lastRefresh ?? Date.distantPast) > ($1.metaData?.lastRefresh ?? Date.distantPast)
                }

                guard let survivor = sortedGroup.first else { continue }
                let duplicates = sortedGroup.dropFirst()

                // 4. Delete the duplicates
                for duplicate in duplicates {
                    let title = duplicate.title
                    let feedString = duplicate.feed?.absoluteString ?? "N/A"
                    print("Deleting duplicate podcast: \(title.xmlEscaped) with feed: \(feedString)")
                    modelContext.delete(duplicate)
                }

                // Optionally, you could merge any additional data from duplicates into survivor here.
                _ = survivor // silence unused warning if not used further
            }

            // 5. Save context
            if let saveIfNeeded = (modelContext as AnyObject).perform?(Selector(("saveIfNeeded"))) {
                // If extension exists, call regular save() to avoid fragile selector usage
                try modelContext.save()
            } else {
                try modelContext.save()
            }
            print("Duplicate cleanup complete. Deletions saved.")
        } catch {
            print("Error during duplicate cleanup: \(error)")
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
        
        await cleanupDuplicates() 
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
            
    }
    
    func getLastRefreshDate() -> Date? {
        let lastDate = Date.dateFromRFC1123(dateString: UserDefaults.standard.string(forKey: "LastBackgroundRefresh") ?? "")
        return lastDate
    }
    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().RFC1123String(), forKey: "LastBackgroundRefresh")
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
            opmlString += """
            <outline text="\(podcast.title.xmlEscaped)" type="rss" xmlUrl="\(podcast.feed?.absoluteString ?? "")" />\n
        """
        }
        
        opmlString += """
        </body>\n
    </opml>\n
    """
        
        return opmlString
    }
    



}
/*
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

*/

