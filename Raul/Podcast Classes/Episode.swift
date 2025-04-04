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
    var publishDate: Date
    var url: URL
    var podcast: Podcast?

    init(id: UUID, title: String, publishDate: Date, url: URL, podcast: Podcast) {
        self.id = id
        self.title = title
        self.publishDate = publishDate
        self.url = url
        self.podcast = podcast
    }
}
