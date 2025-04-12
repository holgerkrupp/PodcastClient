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
    private var playbackRate: Float = 1.0

    var playPosition: Double = 0.0
    var currentEpisode: Episode? 
    var isPlaying: Bool = false
    
    var chapterProgress: Double?
    var currentChapter: Chapter?
    var nextChapter: Chapter?
    var previousChapter: Chapter?
    
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
        
    func setCurrentEpisode(episode: Episode, playDirectly: Bool = false) {
        self.currentEpisode = episode
        Task{
            self.playbackRate = await engine.getRate()
        }
        
        if let lastPlayPosition = currentEpisode?.metaData?.playPosition {
            jumpTo(time: lastPlayPosition)
        }
        
        updateNowPlayingInfo(for: episode)
        
        if playDirectly {
            play()
        }
    }
    
    func playEpisode(_ episode: Episode) {
        currentEpisode = episode
        
        Task {
            // Load the AVPlayerItem asynchronously
            let item = await Task.detached {
                AVPlayerItem(url: episode.url)
            }.value
            
            await engine.replaceCurrentItem(with: item)
            
            if let lastPlayPosition = currentEpisode?.metaData?.playPosition {
                print("last position: \(lastPlayPosition)")
                await engine.seek(to: CMTime(seconds: lastPlayPosition, preferredTimescale: 600))
            } else {
                print("no last position")
            }
            
            play()
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
        currentEpisode?.metaData?.lastPlayed = Date()
        if playPosition > currentEpisode?.metaData?.maxPlayposition ?? 0.0 {
            currentEpisode?.metaData?.maxPlayposition = playPosition
        }
        currentEpisode?.metaData?.playPosition = playPosition
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
                setCurrentEpisode(episode: newEpisode, playDirectly: true)
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
        let info: [String: Any] =  [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.author ?? episode.podcast?.title ?? episode.podcast?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
/*
        if let image = episode.coverImage.asUIImage(),
           let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image } {
            info[MPMediaItemPropertyArtwork] = artwork
        }
*/
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
