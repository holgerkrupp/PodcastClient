//
//  PodcastFeed.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
@Observable
 class PodcastFeed: Hashable, @unchecked  Sendable{
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        
    }
     
     init (url: URL) {
         self.url = url
     }
    
    var title: String?
    var subtitle: String?
    var description: String?
    
    
    var url: URL?
    var existing: Bool = false
    
    var added: Bool = false
    var subscribing: Bool = false
    var status: URLstatus?
    
    var artist: String?
    var artworkURL: URL?
    var lastRelease: Date?
}

