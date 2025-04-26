import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer

@Observable
@MainActor
class Player: NSObject {
    static let shared = Player()

    private let engine = PlayerEngine()
    private var playbackTask: Task<Void, Never>?
    var playbackRate: Float = 1.0 {
        didSet {
            Task { await engine.setRate(playbackRate) }
        }
    }

    var playPosition: Double = 0.0
    
    
    var currentEpisode: Episode?
    var currentEpisodeID: UUID?
    
    
    var isPlaying: Bool = false
    
    var chapterProgress: Double?
    var currentChapter: Chapter?
    var nextChapter: Chapter?
    var previousChapter: Chapter?
    var episodeActor: EpisodeActor
    
    override init() {
        episodeActor = EpisodeActor(modelContainer: ModelContainerManager().container)
        super.init()
        //loadEpisode()

        
        if let currentEpisode {
            playEpisode(currentEpisode, playDirectly: false)
            
        }
    }
    

    

    
    private func updateCurrentChapter(){
        
        let playingChapter = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 <= self.playPosition})
        
        if currentChapter != playingChapter {
            currentChapter = playingChapter
     
            nextChapter = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 > self.playPosition})
        }
        
    }
    
    private func updateChapterProgress(){
        guard let currentChapter = currentChapter else { return }
        let chapterEnd = currentChapter.end ?? nextChapter?.start ?? currentEpisode?.duration ?? 1.0
        chapterProgress = (playPosition - (currentChapter.start ?? 0)) / ((chapterEnd) - (currentChapter.start ?? 0))
        
    }
        
    
    func playEpisode(_ episode: Episode, playDirectly: Bool = true) {
        currentEpisode = episode
        
        Task {
            // Load the AVPlayerItem asynchronously
            let item = await Task {
                
                if episode.metaData?.calculatedIsAvailableLocally ?? false, let localFile = episode.localFile {
               
                    AVPlayerItem(url: localFile)
                }else{
                
                    AVPlayerItem(url: episode.url)
                }
                
                
            }.value
            
            
            await engine.replaceCurrentItem(with: item)
            
            if let lastPlayPosition = currentEpisode?.metaData?.playPosition {
                print("last position: \(lastPlayPosition)")
                jumpTo(time: lastPlayPosition)
            } else {
                print("no last position")
            }
            
            updateNowPlayingInfo(for: episode)
            
            if playDirectly {
                play()
                initRemoteCommandCenter()
            }
        }
    }
    
    var coverImage: some View{
        if let playing = currentEpisode{
            
             return AnyView(playing.coverImage)
             
             
        }else{
            return AnyView(EmptyView())
        }
    }
    
    var progress:Double {
        
        set{
            
            
            let seconds:Double  = newValue * (currentEpisode?.duration ?? 1.0)
            let newTime = CMTime(seconds: seconds, preferredTimescale: 1)
            jumpTo(time: newTime.seconds)
        }
        get{
            
            if let duration = currentEpisode?.duration {
                return ((playPosition) / duration)
            }else{
                return 0.0
            }
        }
        
    }
    var remaining: Double?{
        if let duration = currentEpisode?.duration{ // avplayer.currentItem?.duration.seconds ??
            return duration - playPosition
        }else{
            return  nil
        }
    }
    


 
    
    func play(){
        Task { 
            await engine.play()
            isPlaying = true
        }
        updateLastPlayed()
        startPlaybackUpdates()
    }
    
    

    func pause() {
        Task { 
            await engine.pause()
            isPlaying = false
        }
        updateLastPlayed()
        stopPlaybackUpdates()
    }

    func jumpTo(time: Double) {
        Task {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            await engine.seek(to: cmTime)
        }
        playPosition = time
    }
    
    func setRate(_ rate: Float){
        Task { await engine.setRate(rate) }
        playbackRate = rate
    }

    private func startPlaybackUpdates() {
        playbackTask?.cancel()
        playbackTask = Task {
            for await time in await engine.playbackPositionStream() {
                playPosition = time
                updateEpisodeProgress(to: time)
               
            }

            handlePlaybackFinished()
        }
    }
    func updateLastPlayed()  {
        if let currentEpisode {
            Task{
                await episodeActor.setLastPlayed(currentEpisode.id)
                await episodeActor.setPlayPosition(episodeID: currentEpisode.id, position: playPosition)
            }
        }
    }

    private func stopPlaybackUpdates() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private var progressUpdateCounter = 0
    private let progressSaveInterval = 20  // 0.5 seconds * 20 = 10 seconds
    
    private func updateEpisodeProgress(to time: Double) {
        guard let episode = currentEpisode else { return }
        
        // Update UI-related properties on main thread

        updateCurrentChapter()
        updateChapterProgress()
        
        // Move database operations to background thread
        progressUpdateCounter += 1
        if progressUpdateCounter >= progressSaveInterval {
            Task.detached(priority: .background) {
                do {
                    try episode.modelContext?.save()
                    await MainActor.run {
                        self.progressUpdateCounter = 0
                    }
                } catch {
                    print("Failed to save context: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func skipTo(chapter: Chapter){
        
        if chapter.episode == currentEpisode{
            if let start = chapter.start{
                
                jumpTo(time: start)
            }
        }else{
            if let newEpisode = chapter.episode{
                playEpisode(newEpisode, playDirectly: true)
            }
        }
    }

    private func handlePlaybackFinished() {
        print("Playback finished.")
     //   currentEpisode?.finishedPlaying = true
        updateLastPlayed()
        stopPlaybackUpdates()
/*
        currentPlaylist.items?.removeAll(where: { $0.episode == currentEpisode })

        if let next = currentPlaylist.ordered.first?.episode {
            playEpisode(next)
        }
 */
    }
    
    
    private var remoteCommandsSetup = false

    private func setupRemoteCommands() {
        guard !remoteCommandsSetup else { return }
        let RCC = MPRemoteCommandCenter.shared()

        RCC.playCommand.isEnabled = true
        RCC.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        RCC.pauseCommand.isEnabled = true
        RCC.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Add skip/back/bookmark etc...
        
        remoteCommandsSetup = true
    }
    
    func updateNowPlayingInfo(for episode: Episode)  {
        var info: [String: Any] =  [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.author ?? episode.podcast?.title ?? episode.podcast?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        
       
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
    }
    
    func initRemoteCommandCenter(){
        let RCC = MPRemoteCommandCenter.shared()
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { _ in
           // self.bookmark()
            return .success
        }
        
        RCC.playCommand.isEnabled = true
        RCC.playCommand.addTarget { _ in
            
            if !self.isPlaying {
                self.play()
                return .success
            }
            return .commandFailed
        }
        
        
        
        // Add handler for Pause Command
        RCC.pauseCommand.isEnabled = true
        RCC.pauseCommand.addTarget { _ in
            
            if self.isPlaying{
                self.pause()
                return .success
            }
            return .commandFailed
        }
        
        RCC.skipForwardCommand.isEnabled = true
        RCC.skipForwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpTo(time: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        
        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        RCC.skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpTo(time: -seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { event in
         //   self.bookmark()
            return.success
        }
        
        RCC.changePlaybackPositionCommand.isEnabled = true
        RCC.changePlaybackPositionCommand.addTarget { event in
            
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    let time = CMTime(seconds: event.positionTime, preferredTimescale: 1000000).seconds
                    self.jumpTo(time: time)
                    return .success
                }
            
            return .commandFailed
        }
        
        
    }
    
    private var nowPlayingInfoTimer: Timer?

    private func startNowPlayingInfoUpdater() {
        nowPlayingInfoTimer?.invalidate()
        nowPlayingInfoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            Task { @MainActor in
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.playPosition
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = self.playbackRate
            }
        }
    }
    
    private func stopNowPlayingInfoUpdater() {
        nowPlayingInfoTimer?.invalidate()
        nowPlayingInfoTimer = nil
    }
}
