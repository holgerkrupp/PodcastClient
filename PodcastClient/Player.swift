//
//  File.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import Combine

@Observable class Player: NSObject{
    
    private var avplayer = AVPlayer()
    private let session = AVAudioSession.sharedInstance()
    
    static let shared = Player()
    var isPlaying:Bool{
        return avplayer.isPlaying
    }
    
    var rate:Float{
        avplayer.rate
    }
    
    var playNextQueue: Playlist = PlaylistManager.shared.playnext
    var settings:PodcastSettings = SettingsManager.shared.defaultSettings
    
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
    
    
    
    
    var observer: NSKeyValueObservation?
    
    
    var currentEpisode:Episode?{
        didSet{
            if let asset = currentEpisode?.avAsset{
                let playerItem = AVPlayerItem(asset: asset)
                avplayer.replaceCurrentItem(with: playerItem)
                Task{
                    await self.currentEpisode?.updateDuration()
                }
                if currentEpisode?.chapters.count == 0{
                    if let content = currentEpisode?.content{
                        if let chapters = currentEpisode?.createChapters(from: content){
                            currentEpisode?.chapters = chapters
                        }
                    }
                }
                
                //    settings = currentEpisode?.podcast?.settings ?? SettingsManager.shared.defaultSettings
                
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
                initMPMediaPlayer()
                initRemoteCommandCenter()
            }else{
                print("could not read current Episode")
            }
            
        }
    }
    
    var currentChapter: Chapter?{
        
        if let chapters = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}), chapters.count > 0 {
            return chapters.last(where: {$0.start ?? 0 < self.playPosition})
        }else{
            return nil
        }
        
    }
    
    var nextChapter: Chapter?{
        if let chapters = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}), chapters.count > 0 {
            return chapters.first(where: {$0.start ?? 0 > self.playPosition})
        }else{
            return nil
        }
    }
    var previousChapter: Chapter?{
        if let chapters = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}), chapters.count > 0 {
            if let currentIndex = chapters.firstIndex(where: {$0.start ?? 0 < self.playPosition}){
                let previousIndex = chapters.index(before: currentIndex)
                print("currentIndex: \(currentIndex) PreIndex: \(previousIndex)")
                guard (previousIndex >= 0)else{return nil}
                return chapters[previousIndex]
            }else{
                return nil
            }

        }else{
            return nil
        }
    }
    
    
    var chapterRemaining: Double?
    var chapterProgress: Double?
    
    var coverImage: some View{
        if let playing = currentEpisode{
            return AnyView(playing.coverImage)
            /*
             if let chapter = currentChapter{
             
             return AnyView(chapter.coverImage)
             }else{
             return AnyView(playing.coverImage)
             }
             */
        }else{
            return AnyView(Image(systemName: "photo").resizable())
        }
    }
    
    var playPosition: Double = 0.0{
        didSet{
            currentEpisode?.playPosition = playPosition
        }
    }
    
    var remaining: Double?{
        if let duration = avplayer.currentItem?.duration{
            return duration.seconds - playPosition
        }else{
            return nil
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
            
            
            playPosition = avplayer.currentTime().seconds
            
            if let currentStart = currentChapter?.start{
                if let currentEnd = (nextChapter?.start ?? self.duration) {
                    currentChapter?.duration = currentEnd - currentStart
                    let currentChapterPlayPosition = playPosition - currentStart
                    chapterProgress = currentChapterPlayPosition / (currentEnd - currentStart)
                    chapterRemaining = currentEnd - playPosition
                }
            }
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
        jumpPlaypostion(by: -Double(settings.skipBack))
        print("skipback")
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: Double(settings.skipForward))
        print("skipforward")
        
    }
    
    func skipToNextChapter(){
        if let chapterRemaining{
            jumpPlaypostion(by: chapterRemaining)
        }
    }
    
    func skipToChapterStart(){
        if let currentStart = currentChapter?.start{
            let currentChapterPlayPosition = playPosition - currentStart
            
            print(currentChapterPlayPosition.formatted())
            if (currentChapterPlayPosition < 2.0){   // seconds margin. If you are just at the beginning of a chapter, you might want to jump to the previous instead
                if let previousStart = previousChapter?.start{
                    let previousChapterPlayPosition = playPosition - previousStart
                    print("pre \(previousChapterPlayPosition)")
                    jumpPlaypostion(by: -previousChapterPlayPosition)
                }
            }else{
                jumpPlaypostion(by: -currentChapterPlayPosition)

            }
        }
    }
    
    private func jumpPlaypostion(by seconds:Double){
            let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
            let jumpToTime = CMTimeAdd(avplayer.currentTime(), secondsToAdd)
            avplayer.seek(to: jumpToTime)
    }
    
    func initMPMediaPlayer(){
        
        let playcenter = MPNowPlayingInfoCenter.default()
  //      let mediaArtwort = MPMediaItemArtwork(image: episode.coverImage)
        playcenter.nowPlayingInfo = [
         //   MPMediaItemPropertyArtwork: mediaArtwort,
            
            MPMediaItemPropertyTitle : currentEpisode?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: currentEpisode?.duration ?? avplayer.currentItem?.duration ?? 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: avplayer.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: avplayer.rate]
    }
    
    func initRemoteCommandCenter(){
        let RCC = MPRemoteCommandCenter.shared()
        
        
        
        RCC.playCommand.isEnabled = true
        
        let playCommand = RCC.playCommand.addTarget { _ in
            
            if !self.avplayer.isPlaying {
                self.playPause()
                return .success
            }
            return .commandFailed
        }
        
        // Add handler for Pause Command
        RCC.pauseCommand.isEnabled = true
        let pauseCommand = RCC.pauseCommand.addTarget { _ in
            
            if self.avplayer.isPlaying{
                self.playPause()
                return .success
            }
            return .commandFailed
        }
        
        RCC.skipForwardCommand.isEnabled = true
        let skipForwardCommand = RCC.skipForwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpPlaypostion(by: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForward)]

        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        let skipBackwardCommand = MPRemoteCommandCenter.shared().skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpPlaypostion(by: seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBack)]

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


