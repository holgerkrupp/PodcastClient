//
//  CarPlayHelloWorldTemplate.swift
//  CPHelloWorld
//
//  Created by Paul Wilkinson on 16/5/2023.
//

import Foundation
import CarPlay
import SwiftData

class CarPlayPlayNext {
    
    var episodes = PlaylistManager.shared.playnext.ordered.compactMap {$0.episode}
    
    let player = Player.shared
    var interfaceController: CPInterfaceController?
    var template: CPListTemplate {
        return CPListTemplate(title: "Up Next", sections: [self.section])
    }
    
    var items: [CPListItem] {
        var items: [CPListItem] = []
        for episode in episodes {
            var cover = UIImage(systemName: "globe")
            
            
            if let data = episode.cover{
                cover = ImageWithData(data).uiImage()
            }else if let data = episode.podcast?.cover{
                cover = ImageWithData(data).uiImage()
            }
            
            let newItem = CPListItem(text:episode.title, detailText: episode.podcast?.title, image: cover)
            newItem.userInfo = episode
            newItem.accessoryType = .disclosureIndicator
            newItem.isPlaying = (episode == player.currentEpisode)
            
            
            newItem.handler = {  item, completion in
                if let episode = item.userInfo as? Episode{
                    self.player.setCurrentEpisode(episode: episode, playDirectly: true)
                    
                    self.interfaceController?.pushTemplate(CarPlayNowPlaying().template, animated: true, completion: { success, error in
                        print(error)
                    })
                }
            }
            items.append(newItem)
        }
        return items
    }
    
    private var section: CPListSection {
        return CPListSection(items: items)
    }

}
