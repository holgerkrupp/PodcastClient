//
//  podcast.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

@Model
class Podcast: Equatable, Hashable{
    var id = UUID()
    var settings:PodcastSettings?

    
    var feed: URL?
    
    var title: String = "loading"
    var subtitle: String?
    var author: String?
    var link: URL?
    var desc: String?
    var summary: String?
    var coverURL: URL?
    var cover:Data?
    
    
    
    var lastBuildDate:Date?
    var language:String?
    
    
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast) var episodes: [Episode] = []
    
    var lastHTTPcode: Int?
    
    var lastModified:Date?
    var lastRefresh:Date?
    var lastAttempt:Date?
    
    var DEBUGAttemptCount: Int = 0
    
    
    
    
    
    @Transient var isUpdating:Bool = false
 
    
    // MARK: computed properties
    
    
    func feedData() async -> Data?{
        guard let feed else {  return nil }
        
        return await feed.feedData()

    }
    

    
    func feedUpdated() async ->Bool?{
        
    

        if let lastRefresh{
            if let serverLastModified = try? await feed?.status()?.lastModified {
                print("Server: \(serverLastModified.formatted()) vs Database: \(lastRefresh.formatted())")
      
                if serverLastModified > lastRefresh{
                    print("feed is new")
                    // feed on server is new
                    return true
                }else{
                    // feed on server is old
                    print("feed is old")
                    return false
                }
            }else{
                // server is not answering with a lastmodified Date
                print("no last modified date")
                return nil
            }
        }else{
            // feed has never been fetched before, no last modified date is set.
            print("feed is very new")
            return true
        }
    }

    
    
    // MARK: init
    init(details: [String: Any]) async {


        title = details["title"] as? String ?? ""
        
        print("Podcast \(id) - \(title)")

        
        
        subtitle = details["itunes:subtitle"] as? String
        author = details["itunes:author"] as? String
        summary = details["itunes:summary"] as? String
        desc = details["description"] as? String
        
        language = details["language"] as? String
        
        lastBuildDate = Date.dateFromRFC1123(dateString: details["lastBuildDate"] as? String ?? "")
        lastRefresh = Date()
        lastModified = lastBuildDate
        
        link = URL(string: details["link"] as? String ?? "")
    
        
        
        coverURL = URL(string: (details["coverImage"] as? String) ?? (details["image"] as? [String:Any])?["url"] as? String ?? "")
        
        if let coverURL{
            cover = await coverURL.downloadData()
        }
         
        var tempE:[Episode] = []
        for episodeDetails in details["episodes"] as? [[String:Any]] ?? []{

            let episode = await Episode(details: episodeDetails, podcast: self)
                
    
            if SettingsManager.shared.defaultSettings.markAsPlayedAfterSubscribe == true{
                episode.markAsPlayed()
            }
            
            tempE.append(episode)

        

        }
        episodes = tempE
        tempE.removeAll()
        
        

        
    }
    

    
    init(){}
    
    // MARK: functions
    
    func markAllAsPlayed(){
        
        episodes.map { $0.markAsPlayed() }

    }
    
    
    func update(details: [String: Any]) async {
        
 
        let guids =
            (details["episodes"] as? [[String:Any]]).map { episodes in
                episodes.map { episode in
                     episode["guid"] as? String ??
                    (episode["enclosure"] as? [[String:Any]])?.first?["url"] as? String
                }
            }

        let diff = guids?.difference(from: episodes.map { $0.guid })
        
        print("\(diff?.count.description ?? "0") new Episodes")

        if let diff{
            let newEpisodes = (details["episodes"] as? [[String:Any]])?.filter({ episode in
                diff.contains(
                    episode["guid"] as? String ??
                    (episode["enclosure"] as? [[String:Any]])?.first?["url"] as? String
                )
            })
            dump(newEpisodes)
            
            if let newEpisodes{
                for episodeDetails in newEpisodes {
                    let container =  PersistanceManager.shared.sharedModelContainer
                    let context = modelContext ?? ModelContext(container)
                    let episode = await Episode(details: episodeDetails, podcast: self)
                    
                    context.insert(episode)
                    do{
                        try context.save()
                        episodes.append(episode)
                        //          print("Episode inserted")
                    }catch{
                        print(error)
                    }
                }
                
            }
        }

        
        
        
        
        /*
         title = details["title"] as? String ?? ""
         subtitle = details["itunes:subtitle"] as? String
         author = details["itunes:author"] as? String
         summary = details["itunes:summary"] as? String
         desc = details["description"] as? String
         
         language = details["language"] as? String
         
         lastBuildDate = Date.dateFromRFC1123(dateString: details["lastBuildDate"] as? String ?? "")
         lastModified = lastBuildDate
         
         lastRefresh = Date()
         
         link = URL(string: details["link"] as? String ?? "")
         //     coverURL = URL(string: (details["image"] as? [String:Any])?["url"] as? String ?? "")
         */
        
        
      //  print("checking \((details["episodes"] as? [[String:Any]])?.count) episodes")
        /*
        for episodeDetails in details["episodes"] as? [[String:Any]] ?? []{
            print("check: \(episodeDetails["title"] as? String ?? "")")
            
            if contains(episodeDetails: episodeDetails) == false{
                print("does not contain: \(episodeDetails["link"] as? String ?? "")")
                
                let container =  PersistanceManager.shared.sharedModelContainer
                let context = modelContext ?? ModelContext(container)
                let episode = await Episode(details: episodeDetails, podcast: self)
             
                    
                    
                context.insert(episode)
                    do{
                        try context.save()
                        episodes.append(episode)
                        print("Episode inserted")
                    }catch{
                        print(error)
                    }
                
            }else{
                print("Podcast contains \(episodeDetails["title"] ?? "")")
            }
            
        }
        */
        
        
    }
    
    func contains(episodeDetails: [String: Any]) -> Bool{
        let testURL = (episodeDetails["enclosure"] as? [[String:Any]])?.first?["url"] as? String
        
        let guid = episodeDetails["guid"] as? String ?? (episodeDetails["enclosure"] as? [[String:Any]])?.first?["url"] as? String
        
     //   print("contains: \(testURL ?? "")")
      //  let first = episodes.first(where: { $0.assetLink == URL(string: testURL ?? "de.holgerkrupp.teststring") })
        
        let first = episodes.first(where: { $0.guid == guid })

    //    print("\(first?.title ?? "-") contains \(guid ?? "")")
        
        if (first == nil){
            return false
        }else{
            return true
        }
        
        
        
    }
    
    
    func refresh() async{
        isUpdating = true
        DEBUGAttemptCount = DEBUGAttemptCount + 1
        let updated = await feedUpdated()
        lastAttempt = Date()
        
        do{
            try modelContext?.save()
        }catch{
            print(error)
        }
        
        if updated != false{ // could be true (feed file updated) or nil (no last modified day)
            
                if let data = await feedData(){
                    print("got data for \(feed?.absoluteString ?? "")")
                    
   
                    
                    let parser = XMLParser(data: data)
                    let podcastParser = PodcastParser()
                    parser.delegate = podcastParser
                    
                    if parser.parse() {
                        print("parsed for \(feed?.absoluteString ?? "")")
                        if let feedDetail =  (parser.delegate as? PodcastParser)?.podcastDictArr {
                            await update(details: feedDetail)
                            
                        }
                        
                        isUpdating = false
                    }
                    
                    
                }else{
                    print("could not load feedData")
                    isUpdating = false
                }
            
        }else{
            isUpdating = false
            print("no update in feed header - skip refresh")
        }
        
        
    }
    
    func save(){
        if let moc = self.modelContext {
            do{
                try moc.save()
            }catch{
                print(error)
            }
        }
    }
   /*
    static func ==(lhs: Podcast, rhs: Podcast) -> Bool {
        
        if lhs.id == rhs.id{
            return true
        }else if lhs.feed == rhs.feed, lhs.feed != nil{
            return true
        }else{
            return false
        }
        
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(feed)
        hasher.combine(id)
    }
    */

    
    
}



