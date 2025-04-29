//
//  CarPlayNowPlaying.swift
//  PodcastClient
//
//  Created by Holger Krupp on 21.02.24.
//

import Foundation
import CarPlay
import SwiftData
@MainActor
class CarPlayNowPlaying {
    var interfaceController: CPInterfaceController?

    
    let player = Player.shared
    
    var template: CPNowPlayingTemplate = CPNowPlayingTemplate.shared
    
    init() {
        
        setupTempate()
    }
    
    func setupTempate(){
        
        
        
        
        let bookmarksButton = CPNowPlayingImageButton(
            image: UIImage(named: "toolbarIconBookmark")!
        ) {  _ in
            guard Player.shared.currentEpisode != nil else { return }
          //  self.player.bookmark()
        }
        
        
        let listButton = CPNowPlayingImageButton(
            image: UIImage(named: "carplay.list.bullet")!
        ) { [weak self] _ in
            let playListModelActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)
            self?.interfaceController?.setRootTemplate(CarPlayPlayNext(playlistActor: playListModelActor).template, animated: false, completion: nil)
            
        }
        
        
        template.updateNowPlayingButtons([bookmarksButton, listButton])
    }
    
}
