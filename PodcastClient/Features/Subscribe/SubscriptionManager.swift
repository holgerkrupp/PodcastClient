//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData



actor SubscriptionManager:NSObject{
    
    var modelContext: ModelContext? = ModelContext(PersistanceManager.shared.sharedModelContainer)
    
    var podcasts : [Podcast] = []
    var opmlParser = OPMLParser()
   // var podcastParser = PodcastParser()
    
    static let shared = SubscriptionManager()

    

     override init() {
        super.init()
        
        
        let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
        if let fetchresult = try? modelContext?.fetch(descriptor){
            podcasts = fetchresult
        }
        

    }
    
     func fetchData() {
        
        let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
        if let fetchresult = try? modelContext?.fetch(descriptor){
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
    
    
    
    
    
    func refresh(podcast: Podcast){
        Task{
            await podcast.refresh()
        }
    }
    
    func refreshall() async{
        print("refresh all")
            fetchData()
        for podcast in podcasts.sorted(by: { lhs, rhs in
            lhs.lastAttempt ?? Date() < rhs.lastAttempt ?? Date()
        }){
                await podcast.refresh()
            }
        
    }


    
    func read(file url: URL) -> [PodcastFeed]?{
        var newPodcasts: [PodcastFeed] = []

        print("subscriptionmanager: read \(url.absoluteString)")
        guard url.startAccessingSecurityScopedResource() else { // Notice this line right here
            return nil
        }

        
        if let data = try? Data(contentsOf: url){
    
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
    

    
    func subscribe(to url: URL) async -> Bool{
        print("SM subscribe to: \(url.absoluteString)")
        if !contains(url: url){
            if let data = await url.feedData(){

                let podcastParser = PodcastParser()
                let parser = XMLParser(data: data)
                parser.shouldProcessNamespaces = true
                parser.shouldResolveExternalEntities = true
                parser.delegate = podcastParser
                if parser.parse(){
                     let feedDetail =  podcastParser.podcastDictArr
                        
                       
                        let podcast = await Podcast(details: feedDetail)
                        print("created Podcast \(podcast.title) for \(url.absoluteString)")
                        podcast.feed = url
                        if !podcasts.contains(podcast){
                            modelContext?.insert(podcast)
                         /*
                            do{
                                try modelContext?.save()
                                print("podcast inserted")
                                fetchData()
                            }catch{
                                print(error)
                            }
                        */
                          }else{
                            print("podcast \(podcast.title) alreads existing")
                            return false
                        }
                        
                        
                        return true
                    
                    
                }
            }
        }else{
            print("\(url.absoluteString) already subscribed")
            return true
        }
        
        

        return false
    }
    
    func deleteAll(){

        

                do {
                    try modelContext?.delete(model: Podcast.self)
                } catch {
                    fatalError(error.localizedDescription)
                }
                
                
                
          

        
    }
    
    func subscribe(all urls:[URL?]) async{
        
        
        for url in urls {
            if let url{
                print("start subscribe for \(url.absoluteString)")
                let _ = await subscribe(to: url)
                print("end subscribe for \(url.absoluteString)")

            }
            
        }
    }
    
    
    func subscribe(all newPodcasts:[PodcastFeed]) async{
        
     //   newPodcasts.forEach { $0.subscribing = true }
        for podcast in newPodcasts {
            
            let _ = await podcast.subscribe()
            
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
            lhs.lastAttempt ?? Date() < rhs.lastAttempt ?? Date()
        }).filter({$0.feedUpdated != true}){
            let new = await podcast.feedUpdated()
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
            lhs.lastAttempt ?? Date() < rhs.lastAttempt ?? Date()
        }).filter({$0.feedUpdated != false}){
            await podcast.refresh()
        }
    }
    

}
