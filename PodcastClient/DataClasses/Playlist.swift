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
    var items: [PlaylistEntry]? // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.
    
   @Transient var ordered:[PlaylistEntry]{
        items?.sorted(by: {$0.order < $1.order}) ?? []
    }
    
    init(){}
    
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
        let adjust = SettingsManager.shared.defaultSettings.markAsPlayedAfterSubscribe

        for item in ordered {
            let episodeSpeed = item.episode?.podcast?.settings?.playbackSpeed ?? SettingsManager.shared.defaultSettings.playbackSpeed
            let playbackspeed = adjust ? episodeSpeed : 1
            let adjustedEpisodeDuration = ((item.episode?.duration ?? 0.0) - (item.episode?.playpostion ?? 0.0) * Double(playbackspeed))
            playTime = playTime + adjustedEpisodeDuration
            playTimes.append(playTime)
        }
        return playTimes
    }
    
    func add(episode:Episode, to: Position = .end){
        var newPosition = 0
        switch to {
        case .front:
            newPosition = (ordered.first?.order ?? 0) - 1
        default:
            newPosition = (ordered.last?.order ?? 0) + 1
        }
        print("ModelContext same? \(modelContext == episode.modelContext)")
    
        if let existingItem = items?.first(where: { item in
            item.episode == episode
        }){
            existingItem.order = newPosition
        }
        else if let nE: Episode = PersistanceManager.shared.sharedContext.model(for: episode.persistentModelID) as? Episode{
            print("ModelContext same? \(modelContext == nE.modelContext)")
            let newEntry = PlaylistEntry(episode: nE, order: newPosition)
            items?.append(newEntry)

        }else{
            print("could not find Episode in Playlist ModelContext")
        }

        



    }
}

@Model
class PlaylistEntry: Equatable{

    var episode: Episode?
    var dateAdded: Date?
    var order:Int = 0
    var playlist:Playlist?
    init(episode: Episode, order: Int?){
        
        
        self.order = order ?? 0
        self.dateAdded = Date()
        self.episode = episode
    }

}


