//
//  File.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import AVFoundation

class Player: NSObject{
    
    static let shared = Player()
    
    var avplayer = AVPlayer()
    
    var currentEpisode:Episode?{
        didSet{
            if let asset = currentEpisode?.asset?.avAsset{
                let playerItem = AVPlayerItem(asset: asset)
                avplayer.replaceCurrentItem(with: playerItem)
            }
            
        }
    }
    var activePlaylist:Playlist?
    
    
    
    private override init() {
        super.init()
    }
    
    func playPause(){
        if avplayer.currentItem?.status == .readyToPlay{
            avplayer.play()
        }
        print("playpause")
        
    }
    
    func skipback(){
        
        print("skipback")
        
    }
    
    func skipforward(){
        
        print("skipforward")
        
    }
    
}
