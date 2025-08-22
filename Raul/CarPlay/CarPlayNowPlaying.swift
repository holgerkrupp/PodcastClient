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
        // print("setupTempate")
 
        // Configure the now playing template
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        
        var buttons : [CPNowPlayingButton] = []
    
        if let chapters = player.currentEpisode?.chapters, chapters.isEmpty != false {
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
            
            buttons.append(contentsOf: [previousChapterButton, listButton, nextChapterButton])
        }
        
        
        
        let rateButton = CPNowPlayingPlaybackRateButton { [weak self] _ in
            guard let self = self else { return }
            self.player.switchPlayBackSpeed()
            }
        buttons.append(rateButton)
        
        let bookmarkButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "bookmark") ?? UIImage()
        ) { [weak self] _ in
            Task{
                await self?.player.createBookmark()
            }
        }
        buttons.append(bookmarkButton)

        
        template.updateNowPlayingButtons(buttons)
    }
    
}
