//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

@Model class Podcast {
    var id: UUID = UUID()
    var title: String?
    var url: URL?
    var podcastdescription: String?
     var imageURL: URL?
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)  var episodes: [Episode]? = []
    
    init(id: UUID, title: String? = nil, url: URL? = nil, podcastdescription: String? = nil, imageURL: URL? = nil, episodes: [Episode]? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.podcastdescription = podcastdescription
        self.imageURL = imageURL
        self.episodes = episodes
    }
}

@Model class Episode {
   var id: UUID
    var title: String
    var publishDate: Date
    var url: URL
    var podcast: Podcast?

    init(id: UUID, title: String, publishDate: Date, url: URL, podcast: Podcast? = nil) {
        self.id = id
        self.title = title
        self.publishDate = publishDate
        self.url = url
        self.podcast = podcast
    }
}
