//
//  FyydSearchManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.02.24.
//

import Foundation

class FyydSearchManager{
    
    enum Endpoints{
        case podcasts, episode, hot
        
        var url:URL? {
            switch self {
            case .podcasts:
                return URL(string: "https://api.fyyd.de/0.2/search/podcast")
            case .episode:
                return URL(string: "https://api.fyyd.de/0.2/search/episode")
            case .hot:
                return URL(string: "https://api.fyyd.de/0.2/feature/podcast/hot")

            }
        }
        
    }
    
    func getLanguages() async -> [String]?{
    
        if let requestURL = URL(string: "https://api.fyyd.de/0.2/feature/podcast/hot/languages"){
            var components = URLComponents()
            components.scheme = requestURL.scheme
            components.host = requestURL.host
            components.path = requestURL.path()
    
            var request = URLRequest(url: components.url ?? requestURL)
            
            let session = URLSession.shared
            
            do {
                let (responseData, _) = try await session.data(for: request)
                
                
                guard let json = try JSONSerialization.jsonObject(with: responseData , options: []) as? [String: Any] else {
                    // appropriate error handling
                    return nil
                }
                
                
                if let lanuages = json["data"] as? [String]{
                    return lanuages
                }
            }catch{
                print(error)
                
            }
        }
        return nil
        
    }
    
    func search(for term: String, endpoint: Endpoints = .podcasts, lang: String? = nil, count: Int? = 10) async -> [PodcastFeed]?{
        if term != "" {
            
            if let requestURL = endpoint.url{
                
                
                var components = URLComponents()
                components.scheme = requestURL.scheme
                components.host = requestURL.host
                components.path = requestURL.path()
                
                    components.queryItems = [
                        URLQueryItem(name: "title", value: term)
                    ]
                
                
                if lang != nil{
                    components.queryItems?.append(
                        URLQueryItem(name: "language", value: lang)
                    )
                }
                
                if count != nil{
                    components.queryItems?.append(
                        URLQueryItem(name: "count", value: count?.formatted())
                    )
                }
                
                
                var request = URLRequest(url: components.url ?? requestURL)
                
                
                let session = URLSession.shared
                
                do {
                    let (responseData, _) = try await session.data(for: request)
                    
                    
                    guard let json = try JSONSerialization.jsonObject(with: responseData , options: []) as? [String: Any] else {
                        // appropriate error handling
                        return nil
                    }
                    
                    
                    var FyydFeeds:[PodcastFeed] = []
                    
                    
                    if let podcasts = json["data"] as? [[String: Any]]{
                        
                        for podcast in podcasts {
                           
                            let newFeed = PodcastFeed()
                            newFeed.title = podcast["title"] as? String

                            newFeed.artist = podcast["author"] as? String
                            newFeed.subtitle =  podcast["subtitle"] as? String
                            newFeed.description =  podcast["description"] as? String

                            newFeed.url = URL(string: podcast["xmlURL"]  as? String ?? "")
                            newFeed.artworkURL = URL(string: podcast["imgURL"] as? String ?? "")

                            newFeed.lastRelease = ISO8601DateFormatter().date(from: (podcast["lastpub"] as? String ?? ""))
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
