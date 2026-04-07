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
        let player = self.player
 
        // Configure the now playing template
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        
        var buttons : [CPNowPlayingButton] = []
    
        if let chapters = player.chapters, chapters.isEmpty != true {
            let listButton = CPNowPlayingImageButton(
                image: UIImage(systemName: "list.bullet") ?? UIImage()
            ) { _ in
                let chapterList = CarPlayChapterMarkList(interfaceController: interfaceController).template

                interfaceController.pushTemplate(chapterList, animated: false, completion: nil)
            }
            
            let previousChapterButton = CPNowPlayingImageButton(
                image: UIImage(systemName: "backward.end.alt") ?? UIImage()
            ) { _ in
                Task {
                    await player.skipToChapterStart()
                }
            }
            
            let nextChapterButton = CPNowPlayingImageButton(
                image: UIImage(systemName: "forward.end.alt") ?? UIImage()
            ) { _ in
                Task {
                    await player.skipToNextChapter()
                }
            }
            
            buttons.append(contentsOf: [previousChapterButton, listButton, nextChapterButton])
        }
        
        
        
        let rateButton = CPNowPlayingPlaybackRateButton { _ in
            player.switchPlayBackSpeed()
        }
        
        buttons.append(rateButton)
        
        let bookmarkButton = CPNowPlayingImageButton(
            image: UIImage(systemName: "bookmark") ?? UIImage()
        ) { _ in
            Task {
                player.createBookmark()
            }
        }
        buttons.append(bookmarkButton)

        
        template.updateNowPlayingButtons(buttons)
    }
    
}
