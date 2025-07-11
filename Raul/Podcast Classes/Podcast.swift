//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

@Model
final class Podcast {
    var id = UUID()
    var title: String = "Loading..."
    var desc: String?
    var author: String?
    var feed: URL?
    var link: URL?
    
    var language: String?
    
    var copyright: String?
    @Relationship(deleteRule: .cascade) var episodes: [Episode] = []
    var lastBuildDate: Date?
    var imageURL: URL?
    @Relationship(deleteRule: .cascade) var metaData: PodcastMetaData?
    @Relationship(deleteRule: .cascade) var settings: PodcastSettings?
   
    
    // calculated properties that will be generated out of existing properties.
    
   var directoryURL: URL?  {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
    
    var coverFileLocation: URL? {
        let fileName = imageURL?.lastPathComponent ?? "cover.jpg"
        let documentsDirectoryUrl = directoryURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let baseURL = documentsDirectoryUrl else { return nil }
        
        // Create a sanitized filename
        let sanitizedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        
        let uniqueURL = baseURL.appendingPathComponent("\(sanitizedFileName)")
        
        try? FileManager.default.createDirectory(at: uniqueURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: nil)
        return uniqueURL
    }
    
    init(feed: URL) {
        self.feed = feed
        self.title = feed.absoluteString.removingPercentEncoding ?? "default"
        self.metaData = PodcastMetaData()
    }
}


@Model final class PodcastMetaData{

    var lastRefresh:Date?
    
    // these properties are supposed to be used for background refresh checks
    var feedUpdated:Bool? // has the feed been updated and should refresh?
    var feedUpdateCheckDate:Date? // when has feedUpdated been set?
    
    var isUpdating: Bool = false
    
    var isSubscribed: Bool = true
    
    @Relationship(inverse: \Podcast.metaData) var episode: Podcast?
    
    init() {
    }
}




