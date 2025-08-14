//
//  iTunesSearchManager.swift
//  Raul
//
//  Created by Holger Krupp on 11.08.25.
//


//
//  iTunesSearchManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.02.24.
//

import Foundation

actor ITunesSearchActor {
    
    var endpointURL = "https://itunes.apple.com/search?term=$SEARCHTERM&media=podcast"
    
    func search(for term: String) async -> [PodcastFeed]?{
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


                    var iTunesFeeds:[PodcastFeed] = []
     
                    
                    if let podcasts = json["results"] as? [[String: Any]]{
                        
                        for podcast in podcasts {
                            if  let urlString = podcast["feedUrl"] as? String, let url = URL(string: urlString){
                                let newFeed = PodcastFeed(url: url)
                                newFeed.source = .iTunes
                                newFeed.artist = podcast["artistName"] as? String
                                newFeed.title = podcast["collectionName"] as? String
                                newFeed.artworkURL = URL(string: podcast["artworkUrl100"] as? String ?? "")
                                newFeed.lastRelease = ISO8601DateFormatter().date(from: (podcast["releaseDate"] as? String ?? ""))
                                iTunesFeeds.append(newFeed)
                            }
                        }
                        print("iTunes found : \(iTunesFeeds.count)")
                        return iTunesFeeds
                    }
                    
                    print("iTunes no podcasts found")
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

