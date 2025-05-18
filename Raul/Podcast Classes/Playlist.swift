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
    var title: String
    var id: UUID = UUID()
    var deleteable:Bool = true // to enable standard lists like "play next queue" or similar that can't be deleted by the user
    var hidden: Bool = false
    @Relationship var items: [PlaylistEntry] = [] // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.
    
    @Transient var ordered:[PlaylistEntry]{
        items.sorted(by: {$0.order < $1.order}) 
    }
    
    init(){
        self.title = "de.holgerkrupp.podbay.queue"
    }
    
    enum CodingKeys: CodingKey {
        case title, deleteable, hidden, items
    }
    enum Position:Identifiable, Codable {
        case front
        case end
        case none
        
        var id: Self { self }
        
        
    }

    func addPlayTimes() -> [Double]{
        var playTime = 0.0
        var playTimes:[Double] = []
        
        
        for item in ordered {
            let playbackspeed = 1
            let adjustedEpisodeDuration = ((item.episode?.duration ?? 0.0) - (item.episode?.metaData?.playPosition ?? 0.0) * Double(playbackspeed))
            playTime = playTime + adjustedEpisodeDuration
            playTimes.append(playTime)
        }
        return playTimes
    }
    
}

@Model
class PlaylistEntry: Equatable, Identifiable{
    var id: UUID = UUID()
    var episode: Episode?
    var dateAdded: Date?
    var order:Int = 0
    @Relationship var playlist:Playlist?
    init(episode: Episode, order: Int?){
        
        
        self.order = order ?? 0
        self.dateAdded = Date()
        self.episode = episode
    }

}
