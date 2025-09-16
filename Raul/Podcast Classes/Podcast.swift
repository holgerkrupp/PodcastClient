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

struct SocialInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    
    // Required
    var url: URL           // maps from "uri"
    var socialprotocol: String  // maps from "protocol"
    
    // Optional
    var accountId: String?
    var accountURL: URL?   // maps from "accountUrl"
    var priority: Int?

    private enum CodingKeys: String, CodingKey {
        case url = "uri"
        case socialprotocol = "protocol"
        case accountId
        case accountURL = "accountUrl"
        case priority
    }

    init(id: UUID = UUID(), url: URL, socialprotocol: String, accountId: String? = nil, accountURL: URL? = nil, priority: Int? = nil) {
        self.id = id
        self.url = url
        self.socialprotocol = socialprotocol
        self.accountId = accountId
        self.accountURL = accountURL
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required fields
        self.url = try container.decode(URL.self, forKey: .url)
        self.socialprotocol = try container.decode(String.self, forKey: .socialprotocol)
        // Optional fields
        self.accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        self.accountURL = try container.decodeIfPresent(URL.self, forKey: .accountURL)
        self.priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        // Generate a UUID if not present (not decoded from payload)
        self.id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(socialprotocol, forKey: .socialprotocol)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encodeIfPresent(accountURL, forKey: .accountURL)
        try container.encodeIfPresent(priority, forKey: .priority)
    }
}

struct PersonInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var role: String?
    var href: URL?
    var img: URL?
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
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    
    @Transient var message: String?
    
    
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

