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
    var episodes: [Episode] = []
    var lastBuildDate: Date?
    var coverImageURL: URL?
    
    init(feed: URL) {
        self.feed = feed
    }
}
