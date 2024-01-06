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
    
    var isUpdating:Bool = false
    
    // MARK: computed properties

    var feedData:Data?{
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
    
    
    var feedUpdated:Bool?{
        get async throws{
            if let lastModified{
                if let serverLastModified = try? await feed?.status?.lastModified {
                    lastAttempt = Date()
                    if serverLastModified > lastModified{
                        // feed on server is new
                        return true
                    }else{
                        // feed on server is old
                        return false
                    }
                }else{
                    // server is not answering with a lastmodified Date
                    return nil
                }
            }else{
                // feed has never been fetched before, no last modified date is set.
                return true
            }

            
    /*
            
            if let lastModified{
                if let feed{
                    let session = URLSession.shared
                    var request = URLRequest(url: feed)
                    request.httpMethod = "HEAD"
                    if let appName = Bundle.main.applicationName{
                        request.setValue(appName, forHTTPHeaderField: "User-Agent")
                    }
                    do{
                        let (_, response) = try await session.data(for: request)
                        lastHTTPcode = (response as? HTTPURLResponse)?.statusCode

                        if let feedLastModified = Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? ""), feedLastModified > lastModified{
                            return true
                        }else{
                            return false
                        }
                    }catch{
                        print(error)
                        return nil
                    }
                }
            }else{
                return true // feed has never been fetched before therefore it's always new
            }
     return nil
*/
          
        }
    }
    

    // MARK: init
    init(details: [String: Any]) {
        
        title = details["title"] as? String ?? ""
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
           let episode = Episode(details: episodeDetails)
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
        coverURL = URL(string: (details["image"] as? [String:Any])?["url"] as? String ?? "")
        
        for episodeDetails in details["episodes"] as? [[String:Any]] ?? []{
            let episode = Episode(details: episodeDetails)
            if episodes.contains(episode){
                print("episode existing - do nothing")
            }else{
                modelContext?.insert(episode)
                episodes.append(episode)
            }
        }
        
        
    }
    
    
    
    func refresh() async{
        isUpdating = true
        
        let updated = try? await feedUpdated
                
        if updated == true{
            do{
                if let data = try await feedData{
                    
                    
                    
                    //podcast.feedData loads new data
                    
                    let parser = XMLParser(data: data)
                    let podcastParser = PodcastParser()
                    parser.delegate = podcastParser
                    
                    if parser.parse() {
                        
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
        
        
        if lhs.feed == rhs.feed, lhs.feed != nil{
            return true
        }else{
            return false
        }
        
        
        
    }
}



