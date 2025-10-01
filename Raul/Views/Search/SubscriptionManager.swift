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
    
    
    func subscribe(all newPodcasts: [PodcastFeed]) async {
        
        // 1. SERIAL PHASE: Mass-insert all new podcasts quickly.
        //    Perform this on a single ModelContext serially to avoid "Database busy" errors
        //    for the crucial insertion step.
        
        var newPodcastUUIDs: Set<UUID> = []
        
        
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
                
                
                newPodcastUUIDs.insert(existingPodcast.id)
                
            } else {
                let podcast = Podcast(from: podcastFeed) // Use the fast, new initializer
               
                modelContext.insert(podcast)
                
                
                newPodcastUUIDs.insert(podcast.id)
            }
        }
        
        dump(newPodcastUUIDs)
        
        // Commit all changes from the serial inserts at once.
        // This is one large, safe save operation.
        modelContext.saveIfNeeded()
        
        do{
            let worker = PodcastModelActor(modelContainer: self.modelContainer)
            for id in newPodcastUUIDs{
                print("updating podcast: \(id)")
                _ = try await worker.updatePodcast(id, silent: true)
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
             
                let new = try? await PodcastModelActor(modelContainer: modelContainer).updatePodcast(podcast.id)
                podcast.message = nil
                if new == true { updated += 1}
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

