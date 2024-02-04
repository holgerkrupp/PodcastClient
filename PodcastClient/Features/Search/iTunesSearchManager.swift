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
                
                var request = URLRequest(url: requestURL)
                let session = URLSession.shared

                let decoder = JSONDecoder()
                do {
                    let (responseData, _) = try await session.data(for: request)
                    dump(responseData)
                    
                    
                    guard let json = try JSONSerialization.jsonObject(with: responseData , options: []) as? [String: Any] else {
                        // appropriate error handling
                        return nil
                    }


                    
                    dump(json)
                    
                    let podcasts = try decoder.decode([String: [ITunesFeed]].self, from: responseData)
                    dump(podcasts)
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
    
    
    enum CodingKeys: CodingKey{
        case collectionName, feedUrl, artistName, artworkUrl100
    }
    
    required init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self){
            do{
                title = try container.decode(String.self, forKey: .collectionName)
                let urlString = try container.decode(String.self, forKey: .feedUrl)
                url = URL(string: urlString)
                
                artist = try container.decode(String.self, forKey: .artistName)
                //    artworkURL = try? container.decode(URL?.self, forKey: .artworkUrl100)
            }catch{
                print(error)
            }
        }
        
    }
    
    
}
