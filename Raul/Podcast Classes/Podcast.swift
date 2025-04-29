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
    @Relationship(deleteRule: .cascade) var episodes: [Episode] = []
    var lastBuildDate: Date?
    var coverImageURL: URL?
    @Relationship(deleteRule: .cascade) var metaData: PodcastMetaData?
    
    // calculated properties that will be generated out of existing properties.
    
   var directoryURL: URL?  {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
    
    init(feed: URL) {
        self.feed = feed
        self.title = feed.absoluteString
        self.metaData = PodcastMetaData()
    }
}


@Model final class PodcastMetaData{

    var lastRefresh:Date?
    
    // these properties are supposed to be used for background refresh checks
    var feedUpdated:Bool? // has the feed been updated and should refresh?
    var feedUpdateCheckDate:Date? // when has feedUpdated been set?
    
    var isSubscribed: Bool = true
    
    @Relationship(inverse: \Podcast.metaData) var episode: Podcast?
    
    init() {
    }
}


