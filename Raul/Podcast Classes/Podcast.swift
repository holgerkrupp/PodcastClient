//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

struct FundingInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    
    var url: URL
    var label: String
}

@Model
final class Podcast: Identifiable {
    var id = UUID()
    var title: String = "Loading..."
    var desc: String?
    var author: String?
    var feed: URL?
    var link: URL?
    
    var language: String?
    
    var copyright: String?
    @Relationship(deleteRule: .cascade) var episodes: [Episode]? = []
    var lastBuildDate: Date?
    var imageURL: URL?
    @Relationship(deleteRule: .cascade) var metaData: PodcastMetaData?
    @Relationship(deleteRule: .cascade) var settings: PodcastSettings?
   
    var funding: [FundingInfo] = [] // See also: Episode.funding
    
    
     var message: String?
    
    
    // calculated properties that will be generated out of existing properties.
    
   var directoryURL: URL?  {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
    

    
    init(feed: URL) {
        self.feed = feed
        self.title = feed.absoluteString.removingPercentEncoding ?? "default"
        self.metaData = PodcastMetaData()
    }
}


@Model final class PodcastMetaData{
    var id: UUID? = UUID()

    var lastRefresh:Date?
    
    // these properties are supposed to be used for background refresh checks
    var feedUpdated:Bool? // has the feed been updated and should refresh?
    var feedUpdateCheckDate:Date? // when has feedUpdated been set?
    
    @Transient var isUpdating: Bool = false
    @Transient var message: String?

    
    var isSubscribed: Bool = true
    
    @Relationship(inverse: \Podcast.metaData) var podcast: Podcast?
    init() {
    }
}

