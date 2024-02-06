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
