//
//  PodcastFeed.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import fyyd_swift

@Observable
class PodcastFeed: Hashable, @unchecked Sendable {
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    enum Source {
        case fyyd
        case iTunes
        
        var description: String {
            switch self {
            case .fyyd:
                return "fyyd"
            case .iTunes:
                return "iTunes"
            }
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        
    }
     
    init (url: URL) {
        self.url = url
    }
    
    convenience init(fyydPodcast: FyydPodcast) {
        let url = fyydPodcast.xmlURL.flatMap { URL(string: $0) }
        self.init(url: url ?? URL(string: "")!)
        self.title = fyydPodcast.title
        self.subtitle = fyydPodcast.subtitle
        self.description = fyydPodcast.description
        self.artist = fyydPodcast.author
        self.artworkURL = fyydPodcast.imgURL.flatMap { URL(string: $0) }
        // Parse lastpub to Date if possible, fallback to nil
        let dateFormatter = ISO8601DateFormatter()
        self.lastRelease = dateFormatter.date(from: fyydPodcast.lastpub)
        self.source = .fyyd
    }
    
    var title: String?
    var subtitle: String?
    var description: String?
    var source: Source?
    
    var url: URL?
    var existing: Bool = false
    
    var added: Bool = false
    var subscribing: Bool = false
    var status: URLstatus?
    
    var artist: String?
    var artworkURL: URL?
    var lastRelease: Date?
}
