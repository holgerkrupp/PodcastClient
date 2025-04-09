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
    
    var coverImage: some View{
        if let playing = currentEpisode{
            
             return AnyView(playing.coverImage)
             
             
        }else{
            return AnyView(Image(systemName: "photo").resizable())
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
    


    func playEpisode(_ episode: Episode) {
        currentEpisode = episode



        let item = AVPlayerItem(url: episode.url)
        Task {
            await engine.replaceCurrentItem(with: item)
            if let lastPlayPosition = currentEpisode?.metaData?.playPosition {
                print("last position: \(lastPlayPosition)")
                jumpTo(time: lastPlayPosition)
            }else{
                print("no last position")
            }
            await engine.play()
            isPlaying = true
        }

        startPlaybackUpdates()
    }
    
    func play(){
        Task { 
            await engine.play()
            isPlaying = true
        }
        startPlaybackUpdates()
    }
    
    

    func pause() {
        Task { 
            await engine.pause()
            isPlaying = false
        }
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

    private func stopPlaybackUpdates() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private var progressUpdateCounter = 0
    private let progressUpdateInterval = 10  // 0.5 seconds * 10 = 5 seconds
    
    private func updateEpisodeProgress(to time: Double) {
    
         guard let episode = currentEpisode else { return }
        if time > episode.metaData?.maxPlayposition ?? 0.0 {
            episode.metaData?.maxPlayposition = time
        }

        episode.metaData?.playPosition = time
        
        // Increment the progress update counter
         progressUpdateCounter += 1
         // Save every 5 seconds (10 * 0.5 seconds)
         if progressUpdateCounter >= progressUpdateInterval {
             do {
                 try episode.modelContext?.save()
                 progressUpdateCounter = 0  // Reset counter after saving
             } catch {
                 print("Failed to save context: \(error.localizedDescription)")
             }
         }
         
    }

    private func handlePlaybackFinished() {
        print("Playback finished.")
     //   currentEpisode?.finishedPlaying = true
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
