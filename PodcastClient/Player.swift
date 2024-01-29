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
import SwiftData

@Observable class Player: NSObject{
    
    
    struct Sleeptimer{
        enum SleeptimerType{
            case time, episode
        }
        var activated:Bool = false{
            didSet{
                if activated == true{
                    start = Date()
                }else{
                    start = nil
                }
            }
        }
        var minutes:Double = 5
        var secondsLeft:Double?{
            end?.timeIntervalSince(Date())
        }
        var type:SleeptimerType = .time
        var start: Date? = nil
        var end:Date? {
            start?.addingTimeInterval(60*minutes)
        }
        var lastFinish:Date?
        
 
    }
    
    var avplayer = AVPlayer()
    private let session = AVAudioSession.sharedInstance()
//    private let defaults = UserDefaults.standard
    
    static let shared = Player()
    let playcenter = MPNowPlayingInfoCenter.default()

    
    var sleeptimer = Sleeptimer()

    var isPlaying:Bool{
        return avplayer.isPlaying
    }
    
    var rate:Float{
        avplayer.rate
    }
    var currentPlaylist: Playlist = PlaylistManager.shared.playnext
    var settings:PodcastSettings = SettingsManager.shared.defaultSettings
    
    var playPauseButton: some View{
        if currentEpisode != nil{
            if avplayer.isPlaying == false{
                return AnyView(Image(systemName:  "play.fill").resizable())
            }else{
                return AnyView(Image(systemName:  "pause.fill").resizable())
            }
        }else{
            return AnyView(Image(systemName:  "playpause").resizable())
        }
    }
    
    
    
    
    var observer: NSKeyValueObservation?
    
    
    var currentEpisode:Episode?
    
    var currentChapter: Chapter?{
        didSet{
            if currentChapter?.shouldPlay == false, currentChapter?.didSkip == false{
                currentChapter?.didSkip = true
                skipToNextChapter()
            }
        }
    }
    var nextChapter: Chapter?
    var previousChapter: Chapter?
    
    
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
        
            if abs(playPosition - oldValue) > 5{
                print("skip detected")
                let newSkip = Skip(start: oldValue, end: playPosition)
                currentEpisode?.skips?.append(newSkip)
            }
            
            
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

        set{
           

            let seconds:Double  = newValue * (duration ?? 1.0)
            let newTime = CMTime(seconds: seconds, preferredTimescale: 1)
            jumpTo(time: newTime)
        }
        get{
            if let duration {
                return ((playPosition) / duration)
            }else{
                return 0.0
            }
        }

    }
    @objc
    func playerDidFinishPlaying(){
        currentEpisode?.finishedPlaying = true
        currentPlaylist.items?.removeAll(where: { item in
            item.episode == currentEpisode
        })
        if let nextEpisode = currentPlaylist.ordered.first?.episode{
            setCurrentEpisode(episode: nextEpisode, playDirectly: true)
           // currentEpisode = nextItem.episode
        }
        
    }
    
    
    
    func setCurrentEpisode(episode: Episode, playDirectly: Bool = true){
        currentEpisode = episode
        currentPlaylist.add(episode: episode, to: .front)
        if let asset = currentEpisode?.avAsset{
            let playerItem = AVPlayerItem(asset: asset)
            avplayer.replaceCurrentItem(with: playerItem)
            
            
            settings = currentEpisode?.podcast?.settings ?? SettingsManager.shared.defaultSettings
            self.observer = playerItem.observe(\.status, options:  [.new, .old], changeHandler: { (playerItem, change) in
                if playerItem.status == .readyToPlay {
                    if playerItem.duration.isValid{
                        self.currentEpisode?.setDuration(playerItem.duration)
                    }
                    
                    
                }
            })
            
            
            NotificationCenter.default
                .addObserver(self,
                             selector: #selector(playerDidFinishPlaying),
                             name: .AVPlayerItemDidPlayToEndTime,
                             object: avplayer.currentItem
                )
            
            
            
            
            let tolerance = CMTime(seconds: 0, preferredTimescale: 1)
            let zero = CMTime(seconds: 0, preferredTimescale: 0)
            
            avplayer.seek(to: currentEpisode?.playPosition.CMTime ?? zero, toleranceBefore: tolerance, toleranceAfter: tolerance)
            updateCurrentChapter()
            if playDirectly == true{
                play()
            }else{
                pause()
            }
            updateMPMediaPlayer()
            initRemoteCommandCenter()
        }else{
            print("could not read current Episode")
        }
    }
    
    private override init() {
        super.init()
        
        
        if let oldEpisode = currentPlaylist.ordered.first?.episode{
            setCurrentEpisode(episode: oldEpisode, playDirectly: false)

        }

        do{
            try session.setCategory(.playback, mode: .spokenAudio)
        }catch{
            print(error)
        }
        avplayer.rate = settings.playbackSpeed
        avplayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: nil) { [weak self] time in
            guard let self = self else { return }
            if avplayer.isPlaying{
               
                playPosition = avplayer.currentTime().seconds
                updateCurrentChapter()
                updateMPMediaPlayer()
                
            }
            if sleeptimer.activated == true, let end = sleeptimer.end, end <= Date(){
                pause()
                sleeptimer.lastFinish = Date()
                sleeptimer.activated.toggle()
            }
        }
    }
    
    private func updateCurrentChapter(){
        currentChapter = currentEpisode?.chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 < self.playPosition})
        nextChapter = currentEpisode?.chapters?.filter({ $0.shouldPlay == true  }).sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 > self.playPosition})
        if let currentChapter{
            let index = currentEpisode?.chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).firstIndex(of: currentChapter)
            if let index, index > 0{
                if let previousIndex = currentEpisode?.chapters?.filter({ $0.shouldPlay == true  }).sorted(by: {$0.start ?? 0 < $1.start ?? 0}).index(before: index), previousIndex >= 0{
                    previousChapter = currentEpisode?.chapters?.filter({ $0.shouldPlay == true  }).sorted(by: {$0.start ?? 0 < $1.start ?? 0})[previousIndex]
                }
                
            }

        }
        
        if let currentStart = currentChapter?.start{
            if let currentEnd = (nextChapter?.start ?? self.duration) {
                currentChapter?.duration = currentEnd - currentStart
                let currentChapterPlayPosition = playPosition - currentStart
                chapterProgress = currentChapterPlayPosition / (currentEnd - currentStart)
                chapterRemaining = currentEnd - playPosition
            }
        }
        
        updateImage()
    }
    
    private func updateImage(){
        /*
        if let playing = currentEpisode{
           // return AnyView(playing.coverImage)
            
             if let chapter = currentChapter{
             
                 coverImage =  AnyView(chapter.coverImage)
             }else{
                 coverImage = AnyView(playing.coverImage)
             }
             
        }else{
            coverImage = AnyView(Image(systemName: "photo").resizable())
        }
         */
    }
    
    func playPause(){
        try? session.setActive(true)
        if avplayer.isPlaying{
            pause()
            print(isPlaying)
            
        }else{
          
            avplayer.rate = settings.playbackSpeed
            play()
            print(isPlaying)

        }
        
    }
    
    func play(){
        
        if let sleetTimerJustFinished = sleeptimer.lastFinish?.addingTimeInterval(settings.sleepTimerDurationToReactivate * 60), sleetTimerJustFinished >= Date(){
            // Sleeptime just finished, but if the user presses play again, we reactivate the sleeptimer and add some more time
            print("reactivate SleepTimer")
            sleeptimer.minutes = settings.sleepTimerAddMinutes
            sleeptimer.activated.toggle()
            
            
        }
        
        avplayer.play()
    }
    
    func pause(){
        avplayer.pause()
    }
    
    func skipback(){
        jumpPlaypostion(by: -Double(settings.skipBack.float))
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: Double(settings.skipForward.float))
    }
    
    func undo(skip: Skip){
        if let start = skip.start?.CMTime{
            jumpTo(time: start)
            currentEpisode?.skips?.removeAll(where: { sk in
                sk == skip
            })
        }
    }
    
    func skipToNextChapter(){
        if let nextChapterStart = nextChapter?.start{
            let jumpToTime = CMTimeMakeWithSeconds(nextChapterStart,preferredTimescale: 1)
            jumpTo(time: jumpToTime)
        }
    }
    
    
    func skipTo(chapter: Chapter){
        
        if chapter.episode == currentEpisode{
            if let start = chapter.start{
                let jumpToTime = CMTimeMakeWithSeconds(start,preferredTimescale: 1)
                jumpTo(time: jumpToTime)
            }
        }else{
            if let newEpisode = chapter.episode{
                setCurrentEpisode(episode: newEpisode, playDirectly: true)
            }
           

        }
        


    }
    
    func skipToChapterStart(){
        if let currentStart = currentChapter?.start{
            let currentChapterPlayPosition = playPosition - currentStart
            
            print(currentChapterPlayPosition.formatted())
            if (currentChapterPlayPosition < 2.0){   // seconds margin. If you are just at the beginning of a chapter, you might want to jump to the previous instead
                if let previousStart = previousChapter?.start{
                    let previousChapterPlayPosition = playPosition - previousStart
                    jumpPlaypostion(by: -previousChapterPlayPosition)
                }else{
                    // if the first chapter is not starting at 00:00:00 let's start to the beginning instead
                    jumpPlaypostion(by: -playPosition)
                }
            }else{
                jumpPlaypostion(by: -currentChapterPlayPosition)

            }
        }else{
            // if the first chapter is not starting at 00:00:00 let's start to the beginning instead
            jumpPlaypostion(by: -playPosition)
        }
    }
    
    private func jumpPlaypostion(by seconds:Double){
            let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
            let jumpToTime = CMTimeAdd(avplayer.currentTime(), secondsToAdd)
            jumpTo(time: jumpToTime)

            
    }
    
    private func jumpTo(time: CMTime){
        let tolerance = CMTime(seconds: 0, preferredTimescale: 1)
        avplayer.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        playPosition = time.seconds
        updateCurrentChapter()
        if !isPlaying{
            play()
        }
    }
    
    func updateMPMediaPlayer(){
        
     //   let image =  ?? ImageWithData(currentEpisode?.podcast?.cover ?? ImageWithURL(currentEpisode?.image) ?? UIImage())
        let mediaArtwort = MPMediaItemArtwork(image: currentEpisode?.uiimage ?? UIImage())
        playcenter.nowPlayingInfo = [
            
            MPMediaItemPropertyArtwork: mediaArtwort,
            
            MPMediaItemPropertyTitle : currentEpisode?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: currentEpisode?.duration ?? avplayer.currentItem?.duration ?? 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: avplayer.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: avplayer.rate]
    }
    
    func bookmark(){
        print("bookmark")
    }
    
    
    
    func initRemoteCommandCenter(){
        let RCC = MPRemoteCommandCenter.shared()
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { _ in
            self.bookmark()
            return .success
        }
        
        RCC.playCommand.isEnabled = true
        RCC.playCommand.addTarget { _ in
            
            if !self.avplayer.isPlaying {
                self.playPause()
                return .success
            }
            return .commandFailed
        }
        
        // Add handler for Pause Command
        RCC.pauseCommand.isEnabled = true
        RCC.pauseCommand.addTarget { _ in
            
            if self.avplayer.isPlaying{
                self.playPause()
                return .success
            }
            return .commandFailed
        }
        
        RCC.skipForwardCommand.isEnabled = true
        RCC.skipForwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpPlaypostion(by: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForward.float)]

        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        RCC.skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpPlaypostion(by: seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBack.float)]

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
