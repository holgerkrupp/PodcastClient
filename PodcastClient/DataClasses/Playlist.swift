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
    var title: String?
    
    var deleteable:Bool = true // to enable standard lists like "play next queue" or similar that can't be deleted by the user
    var hidden: Bool = false
    var items: [PlaylistEntry] = [] // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.
    
    var ordered:[PlaylistEntry]{
        items.sorted(by: {$0.order < $1.order})
    }
    
    init(){}
    
    enum Position {
        case front
        case end
    }
    
    func add(episode:Episode, to: Position = .end){
        var newPosition = 0
        switch to {
        case .front:
            newPosition = (ordered.first?.order ?? 0) - 1
        default:
            newPosition = (ordered.last?.order ?? 0) + 1
        }
        
        var newEntry = PlaylistEntry()
        newEntry.episode = episode
        newEntry.order = newPosition
        newEntry.dateAdded = Date()
        
        items.append(newEntry)
    }
}

@Model
class PlaylistEntry {
    var episode: Episode?
    var dateAdded: Date?
    var order:Int = 0
    
    init(){}
}


