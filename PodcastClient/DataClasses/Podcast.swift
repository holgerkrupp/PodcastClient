//
//  podcast.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

@Model
class Podcast: Equatable{
    
    var guid: String?
    
    
    var feed: URL?
    
    var title: String = "..loading"
    var subtitle: String?
    var author: String?
    var link: URL?
    var desc: String?
    var summary: String?
    var coverURL: URL?
    
    
    
    var lastBuildDate:Date?
    var language:String?
    
    var settings: PodcastSettings?
    
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast) var episodes: [Episode] = []
    
    var lastHTTPcode: Int?
    
    var lastModified:Date?
    var lastRefresh:Date?
    var lastAttempt:Date?
    
    var DEBUGAttemptCount: Int = 0
    
    
    
    
    
    @Transient var isUpdating:Bool = false
    @Transient var modelContext:ModelContext?
    
    
    
    
    // MARK: computed properties
    
    @Transient var feedData:Data?{
        get async throws{
            
            
            if let feed{
                let session = URLSession.shared
                var request = URLRequest(url: feed)
                if let appName = Bundle.main.applicationName{
                    request.setValue(appName, forHTTPHeaderField: "User-Agent")
                }
                do{
                    let (data, response) = try await session.data(for: request)
                    lastHTTPcode = (response as? HTTPURLResponse)?.statusCode
                    
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
            return nil
        }
        
    }
    
    
    @Transient var feedUpdated:Bool?{
        get async throws{
            if let lastRefresh{
                if let serverLastModified = try? await feed?.status()?.lastModified {
                    print("Server: \(serverLastModified.formatted()) vs Database: \(lastRefresh.formatted())")
                    
                    lastAttempt = Date()
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
    }
    
    
    // MARK: init
    init(details: [String: Any]) {
        
        
        
        
        //update(details: details)
        guid = details["guid"] as? String ?? ""
        
        
        title = details["title"] as? String ?? ""
        
        print("Podcast \(guid) - \(title)")

        
        
        subtitle = details["itunes:subtitle"] as? String
        author = details["itunes:author"] as? String
        summary = details["itunes:summary"] as? String
        desc = details["description"] as? String
        
        language = details["language"] as? String
        
        lastBuildDate = Date.dateFromRFC1123(dateString: details["lastBuildDate"] as? String ?? "")
        lastRefresh = Date()
        lastModified = lastBuildDate
        
        link = URL(string: details["link"] as? String ?? "")
        coverURL = URL(string: (details["image"] as? [String:Any])?["url"] as? String ?? "")
        
        var tempE:[Episode] = []
        for episodeDetails in details["episodes"] as? [[String:Any]] ?? []{
            let episode = Episode(details: episodeDetails, podcast: self)
            tempE.append(episode)
        }
        episodes = tempE
        
        

        
    }
    
    init(){}
    
    // MARK: functions
    
    func markAllAsPlayed(){
        for episode in episodes {
            episode.markAsPlayed()
        }
    }
    
    
    func update(details: [String: Any]) {
        print("started update for \(details["title"] as? String ?? "")")
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
        
        
        print("checking \((details["episodes"] as? [[String:Any]])?.count) episodes")
        for episodeDetails in details["episodes"] as? [[String:Any]] ?? []{
            print("check: \(episodeDetails["title"] as? String ?? "")")
            
            if contains(episodeDetails: episodeDetails) == false{
                print("does not contain: \(episodeDetails["link"] as? String ?? "")")
                
                let schema = Schema([
                    Podcast.self,
                    Episode.self,
                    Chapter.self,
                    
                    PodcastSettings.self,
                    
                    Playlist.self,
                    PlaylistEntry.self
                    
                ])
                
                
                
                if let container = try? ModelContainer(for: schema){
                    let context = ModelContext(container)
                    let episode = Episode(details: episodeDetails, podcast: self)
                    print("created Episode \(episode.title ?? "") for \(self.title)")
                    
                    
                    context.insert(episode)
                    do{
                        try context.save()
                        episodes.append(episode)
                        print("Episode inserted")
                    }catch{
                        print(error)
                    }
                }else{
                    print("could not create ModelContainer")
                }
            }else{
                print("Episode contains \(episodeDetails["title"] ?? "")")
            }
            
        }
        
        
    }
    
    func contains(episodeDetails: [String: Any]) -> Bool{
        
        print("contains: \(episodeDetails["link"] as? String ?? "")")
        let first = episodes.first(where: { $0.link == URL(string: episodeDetails["link"] as? String ?? "de.holgerkrupp.teststring") })
        print("\(first?.title ?? "-") contains \(episodeDetails["link"] as? String ?? "") as \(first?.link?.absoluteString ?? "")")
        if (first == nil){
            return false
        }else{
            return true
        }
        
        
        
    }
    
    
    func refresh() async{
        isUpdating = true
        DEBUGAttemptCount = DEBUGAttemptCount + 1
        let updated = try? await feedUpdated
        
        if updated == true{
            do{
                if let data = try await feedData{
                    print("got data for \(feed?.absoluteString ?? "")")
                    
                    
                    //podcast.feedData loads new data
                    
                    let parser = XMLParser(data: data)
                    let podcastParser = PodcastParser()
                    parser.delegate = podcastParser
                    
                    if parser.parse() {
                        print("parsed for \(feed?.absoluteString ?? "")")
                        if let feedDetail = (parser.delegate as? PodcastParser)?.podcastDictArr {
                            update(details: feedDetail)
                            
                        }
                        
                        isUpdating = false
                    }
                    
                    
                }else{
                    print("could not load feedData")
                    isUpdating = false
                }
            }catch{
                print(error)
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
    
    static func ==(lhs: Podcast, rhs: Podcast) -> Bool {
        
        if lhs.guid == rhs.guid && lhs.guid != nil && rhs.guid != nil && lhs.guid != "" && rhs.guid != ""{
            return true
        }else if lhs.feed == rhs.feed{
            return true
        }else{
            return false
        }
        
        
        
    }
    

    
    
}



