//
//  File.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import AVFoundation
import SwiftUI

class Player: NSObject{
    
    static let shared = Player()
    
    var isPlaying:Bool{
        return avplayer.isPlaying
    }
    
    var playPauseButton: some View{
        if currentEpisode != nil{
            if isPlaying == false{
                return AnyView(Image(systemName:  "play.fill").resizable())
            }else{
                return AnyView(Image(systemName:  "pause.fill").resizable())
            }
        }else{
            return AnyView(Image(systemName:  "playpause").resizable())
        }
    }
    
    var avplayer = AVPlayer()
    
    var currentEpisode:Episode?{
        didSet{
            if let asset = currentEpisode?.asset?.avAsset{
                let playerItem = AVPlayerItem(asset: asset)
                avplayer.replaceCurrentItem(with: playerItem)
            }
            
        }
    }
    
    var coverImage: some View{
        if let playing = currentEpisode{
            return AnyView(playing.coverImage)
        }else{
            return AnyView(Image(systemName: "mic.fill").resizable())
        }
    }
    
    
    
    
    var activePlaylist:Playlist?
    
    
    
    private override init() {
        super.init()
    }
    
    func playPause(){
        if avplayer.currentItem?.status == .readyToPlay{
            avplayer.play()
        }else if avplayer.isPlaying{
            avplayer.pause()
        }
    }
    
    func skipback(){
        
        print("skipback")
        
    }
    
    func skipforward(){
        
        print("skipforward")
        
    }
    
}

extension AVPlayer {
    var isPlaying: Bool {
        return rate != 0 && error == nil
    }
}
