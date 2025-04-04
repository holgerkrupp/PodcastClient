//
//  Episode.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//
import SwiftData
import Foundation

@Model final class Episode {
    var id: UUID
    var title: String
    var guid: String?
    var publishDate: Date
    var url: URL
    @Relationship(deleteRule: .nullify) var podcast: Podcast?

    init(id: UUID , guid: String?, title: String, publishDate: Date, url: URL, podcast: Podcast) {
        self.id = id
        self.guid = guid
        self.title = title
        self.publishDate = publishDate
        self.url = url
        self.podcast = podcast
    }
}
