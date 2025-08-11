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
        print("setupTempate")
        guard let container = ModelContainerManager().container else {
            print("Warning: Could not setupTempate because ModelContainer is nil.")
            return
        }
        // Configure the now playing template
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        
        
    
        
        let listButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "list.bullet") ?? UIImage()
        ) { [weak self] _ in
         //   let playListModelActor = PlaylistModelActor(modelContainer: container)
            
            let chapterList = CarPlayChapterMarkList(interfaceController: interfaceController).template
            
            self?.interfaceController.pushTemplate(chapterList, animated: false, completion: nil)
        }
        
        let previousChapterButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "backward.end.alt") ?? UIImage()
        ) { [weak self] _ in
            // Your logic to go to the previous chapter
            Task{
                await self?.player.skipToChapterStart()
            }
        }

        let nextChapterButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "forward.end.alt") ?? UIImage()
        ) { [weak self] _ in
            // Your logic to go to the next chapter
            Task{
                await self?.player.skipToNextChapter()
            }
        }

        
        template.updateNowPlayingButtons([previousChapterButton, listButton, nextChapterButton])
        print("updateNowPlayingButtons")
    }
    
}
