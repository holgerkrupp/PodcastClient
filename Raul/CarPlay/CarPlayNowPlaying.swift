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
    var interfaceController: CPInterfaceController

    
    let player = Player.shared
    
    var template: CPNowPlayingTemplate = CPNowPlayingTemplate.shared
    
    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        setupTempate(interfaceController: interfaceController)
        
    }
    
    func setupTempate(interfaceController: CPInterfaceController) {
        guard let container = ModelContainerManager().container else {
            print("Warning: Could not mark Downloaded because ModelContainer is nil.")
            return
        }
        // Configure the now playing template
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = true
        
        let listButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "list.bullet") ?? UIImage()
        ) { [weak self] _ in
            let playListModelActor = PlaylistModelActor(modelContainer: container)
            
            let chapterList = CarPlayChapterMarkList(interfaceController: interfaceController).template
            
            self?.interfaceController.setRootTemplate(chapterList, animated: false, completion: nil)
        }
        
        template.updateNowPlayingButtons([listButton])
    }
    
}
