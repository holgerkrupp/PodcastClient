//
//  Playlist.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

@Model
class Playlist{
    var deleteable:Bool = true // to enable standard lists like "play next queue" or similar that can't be deleted by the user
    var name: String?
    var items: [PlaylistEntry]? // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.
    
    init(){}
}

@Model
class PlaylistEntry {
    var episode: Episode?
    var dateAdded: Date?
    var order:Int?
    
    init(){}
}
