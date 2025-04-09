//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData


@ModelActor
actor SubscriptionManager:NSObject{
    

    var podcasts : [Podcast] = []
    var opmlParser = OPMLParser()
   // var podcastParser = PodcastParser()
    
     func fetchData() {
        
        let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
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
        
        print("subscriptionmanager: read \(url.absoluteString)")
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
            print("could not read data from OPML file")
        }
        return nil
    }
    

    enum SubscribeError: Error {
        case existing, parsing, loadfeed
        
        var description:String{
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
                print("start subscribe for \(url.absoluteString)")
                do {
                    let _ = try await PodcastModelActor(modelContainer: modelContainer).createPodcast(from: url)
                    
                } catch {
                    let errorString = "Error: \(error)"
                    print(errorString)
                }
                
                print("end subscribe for \(url.absoluteString)")

            }
            
        }
    }
    
    
    func subscribe(all newPodcasts:[PodcastFeed]) async{
        
        
        for podcast in newPodcasts {
            if let url = podcast.url{
                do {
                    let _ = try await PodcastModelActor(modelContainer: modelContainer).createPodcast(from: url)
                    
                } catch {
                    let errorString = "Error: \(error)"
                    print(errorString)
                }

            }
            
        }
    }
    
    
    //MARK: Background
    //the next functions are for background refresh activites. but could be also used in outher occations
    
    func bgcheckIfFeedsShouldRefresh() async -> Bool{
        // this can run regularly and should be low weight
        // check only those that are not marked as updated during the last run
        print("bgcheckIfFeedsShouldRefresh")
        var shouldRefresh = false
        fetchData()
        for podcast in podcasts.sorted(by: { lhs, rhs in
            lhs.metaData?.feedUpdateCheckDate ?? Date() < rhs.metaData?.feedUpdateCheckDate ?? Date()
        }).filter({$0.metaData?.feedUpdated != true}){
            let new = await PodcastModelActor(modelContainer: modelContainer).checkIfFeedHasBeenUpdated(podcast.persistentModelID)
            if new == true{
                shouldRefresh = true
            }
        }

        return shouldRefresh
    }
    
    func bgupdateFeeds() async{
        // this updates the feeds. It takes more time
        // check only those that are not marked as old during the last run
        fetchData()
        for podcast in podcasts.sorted(by: { lhs, rhs in
            lhs.metaData?.feedUpdateCheckDate ?? Date() < rhs.metaData?.feedUpdateCheckDate ?? Date()
        }).filter({$0.metaData?.feedUpdated != false}){
            try? await PodcastModelActor(modelContainer: modelContainer).updatePodcast(podcast.persistentModelID)
        }
    }
    
    
    func generateOPML() -> String {
        fetchData()
        print("generate OPML")
        var opmlString = """
    <?xml version="1.0" encoding="UTF-8"?>\n
    <opml version="1.1">\n
        <head>\n
            <title>Raúl Podcasts</title>\n
        </head>\n
        <body>\n
    """
        
        for podcast in podcasts {
            opmlString += """
            <outline text="\(podcast.title)" type="rss" xmlUrl="\(podcast.feed?.absoluteString ?? "")" />\n
        """
        }
        
        opmlString += """
        </body>\n
    </opml>\n
    """
        
        return opmlString
    }
    



}
