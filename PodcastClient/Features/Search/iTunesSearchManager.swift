//
//  iTunesSearchManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.02.24.
//

import Foundation

class iTunesSearchManager {
    
    var endpointURL = "https://itunes.apple.com/search?term=$SEARCHTERM&media=podcast"
    
    func search(for term: String) async -> [ITunesFeed]?{
        if term != "" {
            
            if let requestURL = URL(string: endpointURL.replacingOccurrences(of: "$SEARCHTERM", with: term)){
                
                print(requestURL)
                
                let request = URLRequest(url: requestURL)
                let session = URLSession.shared

                do {
                    let (responseData, _) = try await session.data(for: request)
                  
                    
                    
                    guard let json = try JSONSerialization.jsonObject(with: responseData , options: []) as? [String: Any] else {
                        // appropriate error handling
                        return nil
                    }


                    var iTunesFeeds:[ITunesFeed] = []
     
                    
                    if let podcasts = json["results"] as? [[String: Any]]{
                        
                        for podcast in podcasts {
                           
                            let newFeed = ITunesFeed()
                            newFeed.artist = podcast["artistName"] as? String
                            newFeed.title = podcast["collectionName"] as? String
                            newFeed.url = URL(string: podcast["feedUrl"]  as? String ?? "")
                            newFeed.artworkURL = URL(string: podcast["artworkUrl100"] as? String ?? "")
 
                            newFeed.lastRelease = ISO8601DateFormatter().date(from: (podcast["releaseDate"] as? String ?? ""))
                            iTunesFeeds.append(newFeed)
                        }
         
                        return iTunesFeeds
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


class ITunesFeed: Decodable, Hashable{
    static func == (lhs: ITunesFeed, rhs: ITunesFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
       
    }
    
    var title: String?
    var url: URL?
    var artist: String?
    var artworkURL: URL?
    var lastRelease: Date?
    

    init(){}
}
