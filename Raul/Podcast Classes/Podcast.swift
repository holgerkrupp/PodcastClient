//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

@Model struct Podcast {
    @Attribute(.primaryKey) var id: UUID
    @Attribute(.required) var title: String
    @Attribute(.required) var url: URL
    @Attribute(.optional) var description: String?
    @Attribute(.optional) var imageURL: URL?
    @Relationship(.cascade) var episodes: [Episode]
}

@Model struct Episode {
    @Attribute(.primaryKey) var id: UUID
    @Attribute(.required) var title: String
    @Attribute(.required) var publishDate: Date
    @Attribute(.required) var url: URL
}
