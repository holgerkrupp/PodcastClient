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
        self.title = url.absoluteString
        fetchAndPopulateFeedIfNeeded()
    }
    
    private func fetchAndPopulateFeedIfNeeded() {
        print("fetchAndPopulateFeedIfNeeded \(String(describing: url))")
        
        guard let url else { return }
        // If we already have most information, skip
        let needsFetch = (title?.isEmpty ?? true) || artist == nil || description == nil || artworkURL == nil || lastRelease == nil
        guard needsFetch else { print("no fetch needed")
            return }
     
        Task {
            do {
                let parsed = try await PodcastParser.fetchAllPages(from: url)
                await MainActor.run {
                    // Assign parsed values to local state and newPodcastFeed
                    
                  
                    let newTitle = parsed["title"] as? String
                    let newDescription = parsed["description"] as? String
                    let newAuthor = (parsed["itunes:author"] as? String) ?? (parsed["author"] as? String)
                    let newArtwork = parsed["coverImage"] as? String
                    
                    
                    if let imageDict = parsed["image"] as? [String: Any],
                       let urlString = imageDict["url"] as? String,
                       let url = URL(string: urlString) {
                        artworkURL = url
                    }
                    
                    let newLastRelease = parsed["lastBuildDate"] as? String
                    self.title = newTitle ?? self.title
                    self.description = newDescription ?? self.description
                    self.artist = newAuthor ?? self.artist
                    self.artworkURL = artworkURL 
                    
                    if let lastBuildDateString = newLastRelease, let date = Date.dateFromRFC1123(dateString: lastBuildDateString) {
                        self.lastRelease = date
                    }
               
                }
            } catch {
                print(error)
            }
        }
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
