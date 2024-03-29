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


@Observable
class CurrentItem{
    var currentEpisode:Episode?
    var currentChapter: Chapter?
    var playPosition:Double = 0
}


@Observable class Player: NSObject{
    
    var avplayer = AVPlayer()
    private let session = AVAudioSession.sharedInstance()
    
    static let shared = Player()
    let playcenter = MPNowPlayingInfoCenter.default()
    
    
    var sleeptimer = SleepTimer()
    
    var isPlaying:Bool{
        return avplayer.isPlaying
    }
    
    var rate:Float{
        get{
            settings.playbackSpeed
        }
        set{
            avplayer.rate = newValue
            settings.playbackSpeed = newValue
        }
        
    }
    var currentPlaylist: Playlist = PlaylistManager.shared.playnext
    var settings:PodcastSettings = SettingsManager.shared.defaultSettings
    
    var playPauseButton: some View{
        if currentEpisode != nil{
            if avplayer.isPlaying == false{
                return AnyView(Image(systemName:  "play.fill").resizable().aspectRatio(1.0, contentMode: .fit))
            }else{
                return AnyView(Image(systemName:  "pause.fill").resizable().aspectRatio(1.0, contentMode: .fit))
            }
        }else{
            return AnyView(Image(systemName:  "playpause").resizable().aspectRatio(1.0, contentMode: .fit))
        }
    }
    
    
    
    
    var observer: NSKeyValueObservation?
    
    var currentItem:CurrentItem?
    
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
            
            if currentEpisode?.events?.first(where: { event in
                event.start == playPosition
            }) != nil{
                print("skip undo detected")
                currentEpisode?.events?.removeAll(where: { event in
                    event.start == playPosition
                })
                
            }else if abs(playPosition - oldValue) > 5{
                print("skip detected")
                let newSkip = Event(start: oldValue, end: playPosition, type: .skip)
                currentEpisode?.events?.append(newSkip)
                
            }else{
                // no skip detected. Let's update the maxPlayposition
                currentEpisode?.maxPlayposition = playPosition
            }
            
            currentEpisode?.playPosition = playPosition
            
        }
    }
    
    
    
    var remaining: Double?{
        if let duration = currentEpisode?.duration{ // avplayer.currentItem?.duration.seconds ??
            return duration - playPosition
        }else{
            return  nil
        }
    }
    
    var duration:Double?{
        currentEpisode?.duration
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
                    print("playerItem Duration: \(playerItem.duration)")
                    
                    if playerItem.duration.isValid{
                        //        self.currentEpisode?.setDuration(playerItem.duration)
                    }
                    
                    
                }
            })
            /*
             NotificationCenter.default
             .addObserver(self,
             selector: #selector(playerDidFinishPlaying),
             name: .AVPlayerItemDidPlayToEndTime,
             object: avplayer.currentItem
             )
             */
            
            
            
            let tolerance = CMTime(seconds: 0, preferredTimescale: 1)
            let zero = CMTime(seconds: 0, preferredTimescale: 0)
            
            avplayer.seek(to: currentEpisode?.playPosition?.CMTime ?? zero, toleranceBefore: tolerance, toleranceAfter: tolerance)
            updateCurrentChapter()
            if playDirectly == true{
                play()
            }else{
                pause()
            }
            updateMPMediaPlayer()
            initRemoteCommandCenter()
            try? session.setActive(true)
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
        pause()
        avplayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: nil) { [weak self] time in
            guard let self = self else { return }
            if avplayer.isPlaying{
                
                playPosition = avplayer.currentTime().seconds
                updateCurrentChapter()
                
                updateCurrentChapterTime()
                
                
            }
            updateMPMediaPlayer()
            if sleeptimer.activated == true, let end = sleeptimer.end, end <= Date(){
                pause()
                sleeptimer.lastFinish = Date()
                sleeptimer.activated.toggle()
            }
        }
    }
    
    private func updateCurrentChapterTime(){
        if let currentStart = currentChapter?.start{
            if let currentEnd = (nextChapter?.start ?? self.duration) {
                currentChapter?.duration = currentEnd - currentStart
                let currentChapterPlayPosition = playPosition - currentStart
                chapterProgress = currentChapterPlayPosition / (currentEnd - currentStart)
                chapterRemaining = currentEnd - playPosition
            }
        }
    }
    
    private func updateCurrentChapter(){
        let playingChapter = currentEpisode?.chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 <= self.playPosition})
        
        if currentChapter != playingChapter {
            currentChapter = playingChapter
            
            
            nextChapter = currentEpisode?.chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 > self.playPosition})
            
            
        }
        

        
        
        
        
        
        /*
         if let currentChapter{
         let index = currentEpisode?.chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).firstIndex(of: currentChapter)
         if let index, index > 0{
         if let previousIndex = currentEpisode?.chapters?.filter({ $0.shouldPlay == true  }).sorted(by: {$0.start ?? 0 < $1.start ?? 0}).index(before: index), previousIndex >= 0{
         previousChapter = currentEpisode?.chapters?.filter({ $0.shouldPlay == true  }).sorted(by: {$0.start ?? 0 < $1.start ?? 0})[previousIndex]
         }
         
         }
         
         }
         */

        
        
    }
    
    
    func playPause(){
        
        do{
            
            try session.setActive(true)
            if avplayer.isPlaying{
                pause()
                
            }else{
                
                
                play()
                
            }
        }catch{
            print(error)
        }
    }
    
    func play(){
        print("play")
        //  try? session.setActive(true)
        avplayer.play()
        avplayer.rate = settings.playbackSpeed
        sleeptimer.reactivate()
        
        
        startObservation()
    }
    
    func startObservation(){
        withObservationTracking {
            _ = currentChapter
        } onChange: {
            print("chapter changed")
            print(self.currentChapter?.title)
            self.checkChapterSkip()
            Task { self.startObservation() }
        }
    }
    
    
    func checkChapterSkip(){
        print("checkChapterSkip")
        print(currentChapter?.title)
        if nextChapter?.shouldPlay == false{
            print ("skip")
            skipToNextChapter()
        }
    }
    
    func pause(){
        print("pause")
        avplayer.pause()
    }
    
    func skipback(){
        jumpPlaypostion(by: -Double(settings.skipBack.float))
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: Double(settings.skipForward.float))
    }
    
    func undo(skip: Event){
        if let start = skip.start?.CMTime{
            jumpTo(time: start)
            currentEpisode?.events?.removeAll(where: { sk in
                sk == skip
            })
        }
    }
    
    func skipToNextChapter(){
        print("skipToNext")
        if let nextChapterStart = nextChapter?.start{
            print("nextChapterStart:\(nextChapterStart)")
            let jumpToTime = CMTimeMakeWithSeconds(nextChapterStart,preferredTimescale: 1)
            jumpTo(time: jumpToTime)
        }else{
            playerDidFinishPlaying()
            
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
        
        var mediaArtwort:MPMediaItemArtwork?
        
        
        //  print("DEBUG - \(currentEpisode?.duration?.formatted()) vs. \(avplayer.currentItem?.duration.seconds.formatted())")
        
        
        
        
        if let chapterCover = currentChapter?.imageData{
            if let image = UIImage(data: chapterCover){
                mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }else if let image = currentEpisode?.uiimage{
            mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        
        
        
        
        
        playcenter.nowPlayingInfo = [
            
            MPMediaItemPropertyArtwork: mediaArtwort ?? UIImage(named: "AppIcon") ?? UIImage(),
            MPMediaItemPropertyTitle : currentEpisode?.title ?? "",
            MPMediaItemPropertyArtist : currentEpisode?.podcast?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: currentEpisode?.duration ?? avplayer.currentItem?.duration.seconds ?? 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: avplayer.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: avplayer.rate]
    }
    
    func bookmark(){
        let bookmark = Event(start: playPosition, type: .bookmark)
        currentEpisode?.events?.append(bookmark)
    }
    
    func setLockScreenSlider(){
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = settings.enableLockscreenSlider
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
            self.jumpPlaypostion(by: -seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBack.float)]
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { event in
            self.bookmark()
            return.success
        }
        
        RCC.changePlaybackPositionCommand.isEnabled = settings.enableLockscreenSlider
        RCC.changePlaybackPositionCommand.addTarget { event in
            if self.settings.enableLockscreenSlider{
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    let time = CMTime(seconds: event.positionTime, preferredTimescale: 1000000)
                    self.jumpTo(time: time)
                    return .success
                }
            }
            return .commandFailed
        }
        
        
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
