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
    
    func setupTempate() {
        guard let container = ModelContainerManager().container else {
            print("Warning: Could not mark Downloaded because ModelContainer is nil.")
            return
        }
        // Configure the now playing template
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = true
        
        let listButton = CPNowPlayingImageButton(
            image: UIImage(named: "carplay.list.bullet")!
        ) { [weak self] _ in
            let playListModelActor = PlaylistModelActor(modelContainer: container)
            self?.interfaceController?.setRootTemplate(CarPlayPlayNext(playlistActor: playListModelActor).template, animated: false, completion: nil)
        }
        
        template.updateNowPlayingButtons([listButton])
    }
    
}
