//
//  File.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import AVFoundation
import SwiftUI
import Combine

@Observable class Player: NSObject{
    
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
    
    private var avplayer = AVPlayer()
    private let session = AVAudioSession.sharedInstance()
    var observer: NSKeyValueObservation?
   var currentEpisode:Episode?{
        didSet{
            if let asset = currentEpisode?.avAsset{
                let playerItem = AVPlayerItem(asset: asset)
                avplayer.replaceCurrentItem(with: playerItem)
                Task{
                    await self.currentEpisode?.updateDuration()
                }
                

                    self.observer = playerItem.observe(\.status, options:  [.new, .old], changeHandler: { (playerItem, change) in
                    if playerItem.status == .readyToPlay {
                        
                        
                        if playerItem.duration.isValid{
                            self.currentEpisode?.setDuration(playerItem.duration)
                        }
                         

                    }
                })
                let tolerance = CMTime(seconds: 5, preferredTimescale: 1)
                let zero = CMTime(seconds: 0, preferredTimescale: 0)
                avplayer.seek(to: currentEpisode?.playPosition.CMTime ?? zero, toleranceBefore: tolerance, toleranceAfter: tolerance)
                avplayer.play()

            }else{
                print("could not read current Episode")
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
    
    var playPosition: Double = 0.0{
        didSet{
            currentEpisode?.playPosition = playPosition
        }
    }
    
    var duration:Double?{
        avplayer.currentItem?.duration.seconds
    }
    var progress:Double {
        if let duration {
            return ((playPosition) / duration)
        }else{
            return 0.0
        }
    }
    
    
    

    private override init() {
        super.init()
        try? session.setCategory(.playback, mode: .spokenAudio)
        
        avplayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: nil) { [weak self] time in
            guard let self = self else { return }
            
            print("TimeObserver: \(avplayer.currentTime().seconds.description) Seconds")
            
            playPosition = avplayer.currentTime().seconds
        }
    }
    
    func playPause(){
        try? session.setActive(true)
        if avplayer.isPlaying{
            avplayer.pause()
         
        }else{
            avplayer.play()
           
        }

    }
    
    func skipback(){
        jumpPlaypostion(by: -45)
        print("skipback")
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: 45)
        print("skipforward")
        
    }
    
    private func jumpPlaypostion(by seconds:Double){
            let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
            let jumpToTime = CMTimeAdd(avplayer.currentTime(), secondsToAdd)
            avplayer.seek(to: jumpToTime)
    }
    
}

extension AVPlayer {
    var isPlaying: Bool {
        return rate != 0 && error == nil
    }
}

extension Double{
    var CMTime: CMTime{
        if self > 0 {
            return CoreMedia.CMTime(seconds: self, preferredTimescale: 1)
        }else{
            return CMTimeMake(value: 0,timescale: 1)
        }
    }
}
