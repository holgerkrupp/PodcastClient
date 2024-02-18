//
//  FyydSearchManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.02.24.
//

import Foundation

class FyydSearchManager{
    
    enum Endpoints{
        case podcasts, episode
        
        var url:URL? {
            switch self {
            case .podcasts:
                return URL(string: "https://api.fyyd.de/0.2/search/podcast")
            case .episode:
                return URL(string: "https://api.fyyd.de/0.2/search/episode")


            }
        }
        
    }
    
    func search(for term: String, endpoint: Endpoints = .podcasts) async -> [FyydFeed]?{
        if term != "" {
            
            if let requestURL = endpoint.url{
                
                print(requestURL)
                
                let request = URLRequest(url: requestURL)
                let session = URLSession.shared
                
                do {
                    let (responseData, _) = try await session.data(for: request)
                    
                    
                    guard let json = try JSONSerialization.jsonObject(with: responseData , options: []) as? [String: Any] else {
                        // appropriate error handling
                        return nil
                    }
                    
                    
                    var FyydFeeds:[FyydFeed] = []
                    
                    
                    if let podcasts = json["results"] as? [[String: Any]]{
                        
                        for podcast in podcasts {
                           
                            let newFeed = FyydFeed()
                            newFeed.artist = podcast["artistName"] as? String
                            newFeed.title = podcast["collectionName"] as? String
                            newFeed.url = URL(string: podcast["feedUrl"]  as? String ?? "")
                            newFeed.coverURL = URL(string: podcast["artworkUrl100"] as? String ?? "")
                            
                            newFeed.lastRelease = ISO8601DateFormatter().date(from: (podcast["releaseDate"] as? String ?? ""))
                            FyydFeeds.append(newFeed)
                        }
                        
                        return FyydFeeds
                    }
                    
                    
                    return nil
                }catch{
                    print(error)
                    return nil
                    
                }
            }
            
        }
        return nil
    }
    
    
}



class FyydFeed: Decodable, Hashable{
    static func == (lhs: FyydFeed, rhs: FyydFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        
    }
    
    var title: String?
    var subtitle: String?
    var url: URL?
    var description: String?
    var artist: String?
    var coverURL: URL?
    var lastRelease: Date?
    
    
    init(){}
}
