//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData


@Observable
class SubscriptionManager:NSObject{
    
    static let shared = SubscriptionManager()
    var modelContext: ModelContext?

    var podcasts : [Podcast] = []
    let configuration = ModelConfiguration(isStoredInMemoryOnly: false, allowsSave: true)
    var opmlParser = OPMLParser()
    var podcastParser = PodcastParser()

    var newPodcasts: [PodcastFeed] = []
    

    private override init() {
        super.init()
        
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Chapter.self,
            
            Asset.self,
            PodcastSettings.self,
            PlayStatus.self,
            
            Playlist.self,
            PlaylistEntry.self
            
        ])
        
        
        if let container = try? ModelContainer(
            for: schema,
            configurations: configuration
        ){
            modelContext = ModelContext(container)
            fetchData()
        }
    }
    
    func refresh(podcast: Podcast){
        Task{
            await podcast.refresh()
        }
    }
    
    func refreshall() async{
            fetchData()
        for podcast in podcasts.sorted(by: { lhs, rhs in
            lhs.lastAttempt ?? Date() < rhs.lastAttempt ?? Date()
        }){
            
                await podcast.refresh()
            }
        


    }

    func fetchData() {
      
            let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
            if let fetchresult = try? modelContext?.fetch(descriptor){
                podcasts = fetchresult
            }

    }
    
    func read(file url: URL){
        
        newPodcasts.removeAll()
        
        print("subscriptionmanager: read \(url.absoluteString)")
        guard url.startAccessingSecurityScopedResource() else { // Notice this line right here
            return
        }

        
        if let data = try? Data(contentsOf: url){
            addPodcastsfrom(OPMLfile: data)
        }else{
            print("could not read data from OPML file")
        }
    }
    
    
    func addPodcastsfrom(OPMLfile data: Data){
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
            
        }
    }
    
    func subscribe(to url: URL) async -> Bool{
        if let data = await feedData(for: url){
            print("got Data for \(url.absoluteString)")

            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = true
            parser.delegate = podcastParser
            if parser.parse(){
                print("parsed for \(url.absoluteString)")

                if let feedDetail = (parser.delegate as? PodcastParser)?.podcastDictArr {
                    let podcast = Podcast(details: feedDetail)
                    print("created Podcast \(podcast.title) for \(url.absoluteString)")

                    podcast.feed = url
                    modelContext?.insert(podcast)
                    try? modelContext?.save()
                    return true
                }
                
            }
        }
        return false
    }
    
    func subscribe(all urls:[URL?]) async{
        
        
        for url in urls {
            if let url{
                print("start subscribe for \(url.absoluteString)")
                await subscribe(to: url)
                print("end subscribe for \(url.absoluteString)")

            }
            
        }
    }
    
    
    func feedData(for url: URL) async -> Data?{
      
            let session = URLSession.shared
        
            var request = URLRequest(url: url)
            if let appName = Bundle.main.applicationName{
                request.setValue(appName, forHTTPHeaderField: "User-Agent")
            }
            do{
                let (data, response) = try await session.data(for: request)
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200:
                    return data
                case .none:
                    return nil
                    
                case .some(_):
                    return nil
                    
                }
            }catch{
                print(error)
                return nil
            }
        }
        
    

    

}
