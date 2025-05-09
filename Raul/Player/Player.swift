import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import BasicLogger

@Observable
@MainActor
class Player: NSObject {
    
     let progressThreshold: Double = 0.95 // how much of an episode must be played before it is considered "played"
    
    
    static let shared = Player()
  //  private let modelContext = ModelContainerManager().container.mainContext

    private let engine = PlayerEngine()
    private var playbackTask: Task<Void, Never>?

    var playbackRate: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")

            Task { await engine.setRate(playbackRate) }
        }
    }

    var playPosition: Double = 0.0
    
    
    var currentEpisode: Episode?
    var currentEpisodeID: UUID?
    
    var podcastCover: Image?
    
    var isPlaying: Bool = false
    
    var chapterProgress: Double?
    var currentChapter: Chapter?
    var nextChapter: Chapter?
    var previousChapter: Chapter?
    var episodeActor: EpisodeActor
    var playlistActor: PlaylistModelActor
    override init()  {
        episodeActor = EpisodeActor(modelContainer: ModelContainerManager().container)
        playlistActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)
        super.init()
        loadLastPlayedEpisode()
        loadPlayBackSpeed()
        listenToEvent()
        pause()

    }
    
    private func loadLastPlayedEpisode() {
        if let episodeIDString = UserDefaults.standard.string(forKey: "lastPlayedEpisodeID"),
           let episodeUUID = UUID(uuidString: episodeIDString) {
            
            Task {  @MainActor in
                if let episode = await fetchEpisode(with: episodeUUID) {
                    print("loading last episode: \(episode.title)")
                    currentEpisode = episode
                    currentEpisodeID = episode.id
                    await playEpisode(episode.id, playDirectly: false)
                    if let cover = episode.podcast?.coverImageURL{
                        let imagedata = ImageLoaderAndCache(imageURL: cover).imageData
                        podcastCover = ImageWithData(imagedata).image
                    }
                }
            }
        }
    }
    
    private func loadPlayBackSpeed() {
        // this function should check if there is a custom playbackRate set for the podcast. If not load a standard or the last used playbackRate.
        
        let savedPlaybackRate = UserDefaults.standard.float(forKey: "playbackRate")
        if savedPlaybackRate > 0 {
            playbackRate = savedPlaybackRate
            Task {
                await engine.setRate(playbackRate)
                
                // pause()
            }
        }
        
    }
    
    func fetchEpisode(with id: UUID) async -> Episode? {
        print("fetching episode \(id)")
        do {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            return try  episodeActor.modelContainer.mainContext.fetch(descriptor).first
        } catch {
            print("Failed to fetch episode: \(error)")
            return nil
        }
    }
    
    private func updateCurrentChapter() -> Bool?{
        
        let playingChapter = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 <= self.playPosition})
        
        if currentChapter != playingChapter {
            currentChapter = playingChapter
            nextChapter = currentEpisode?.chapters.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 > self.playPosition})
            return true
        }else{
            return false
        }
        
    }
    
    private func updateChapterProgress(){
        guard let currentChapter = currentChapter else { return }
        let chapterEnd = currentChapter.end ?? nextChapter?.start ?? currentEpisode?.duration ?? 1.0
        chapterProgress = (playPosition - (currentChapter.start ?? 0)) / ((chapterEnd) - (currentChapter.start ?? 0))
        
    }
        
    private func unloadEpisode(episodeUUID: UUID) async{
        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        if episode.playProgress > progressThreshold {
            await episodeActor.markasPlayed(episodeUUID)
            
        }else{
            let playlistModelActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)
            await playlistModelActor.add(episodeID: episodeUUID, to: .front)
            print("moving episode \(episode.title) back to playlist")

        }
    }
    
    
    
    func playEpisode(_ episodeUUID: UUID, playDirectly: Bool = true) async {
        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        if let currentEpisodeID, episodeUUID != currentEpisodeID{
            print("unloading episode \(currentEpisodeID)")
            await unloadEpisode(episodeUUID: currentEpisodeID)
        }
        
        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeID = episode.id
        
        jumpTo(time: episode.metaData?.playPosition ?? 0)
        
        _ = updateCurrentChapter()
        
        let playlistModelActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)
        await playlistModelActor.remove(episodeID: episodeUUID)
        
        UserDefaults.standard.set(episode.id.uuidString, forKey: "lastPlayedEpisodeID")

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
            initRemoteCommandCenter()
            setupStaticNowPlayingInfo()
            
            if playDirectly {
                play()
                
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
    
    func listenToEvent() {
        Task{
            await engine.setInterruptionHandler { [weak self] event in
                guard let self else { return }
                switch event {
                case .began:
                    Task{
                        await self.handleInterruptionBegan()
                    }
                case .ended:
                    Task{
                        await self.resumeAfterInterruption()
                    }
                case .pause:
                    Task{
                        await self.handleInterruptionBegan()
                    }
                case .resume:
                    Task{
                        await self.resumeAfterInterruption()
                    }
                }
            }
        }
    }

    private func handleInterruptionBegan(){
        BasicLogger.shared.log("Interruption Began")
        pause()
    }
    
    private func resumeAfterInterruption(){
        BasicLogger.shared.log("Interruption Ended")
        play()
    }
    
    func play(){
        loadPlayBackSpeed()
        Task {
           
            await engine.play() // <- maybe i can remove this, i gues "setRate" already starts playing
            await engine.setRate(playbackRate)
            isPlaying = true
        }
        updateLastPlayed()
        startPlaybackUpdates()
        startNowPlayingInfoUpdater()
    }
    
    

    func pause() {
        Task { 
            await engine.pause()
            isPlaying = false
        }
        updateLastPlayed()
        stopPlaybackUpdates()
        stopNowPlayingInfoUpdater()
    }
    
    func skipback(){
        jumpPlaypostion(by: -Double(15))
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: Double(30))
    }
    
    private func jumpPlaypostion(by seconds:Double){
        let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
        
        let now = CMTimeMakeWithSeconds(playPosition,preferredTimescale: 1)
        let jumpToTime = CMTimeAdd(now, secondsToAdd).seconds
        jumpTo(time: jumpToTime)
    }

    func jumpTo(time: Double) {
        Task {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            await engine.seek(to: cmTime)
        }
        playPosition = time
        _ = updateCurrentChapter()
        updateChapterProgress()
        savePlayPosition()
    }
    
    func setRate(_ rate: Float){
        Task { await engine.setRate(rate) }
        playbackRate = rate
    }


    
    private func stopPlaybackUpdates() {
        playbackTask?.cancel()
        playbackTask = nil
    }
    
    

    private func startPlaybackUpdates() {
        Task {
            for await event in await engine.playbackStream() {
                switch event {
                case .position(let time):
                    playPosition = time
                    updateEpisodeProgress(to: time)
                    setupStaticNowPlayingInfo()
                case .ended:
                    BasicLogger.shared.log("Playback finished automatically")
                    handlePlaybackFinished()
                }
            }
            print("Loop ended") // This should run if the loop ends gracefully

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



    private var progressUpdateCounter = 0
    private let progressSaveInterval = 20  // 0.5 seconds * 20 = 10 seconds
    
    private func updateEpisodeProgress(to time: Double) {
      //  guard let episode = currentEpisode else { return }
        
        // Update UI-related properties on main thread

        let chapterChange = updateCurrentChapter()
 
        updateChapterProgress()
        
        // Skip Chapter logic
        if let currentChapter, currentChapter.shouldPlay == false && chapterChange == true {
            if let end = currentChapter.end {
                jumpTo(time: end)
                BasicLogger.shared.log("Jumped to end of chapter \(currentChapter.title)")
                Task.detached(priority: .background) {
                    let chapterActor = ChapterModelActor(modelContainer: ModelContainerManager().container)
                    await chapterActor.markChapterAsSkipped(currentChapter.id)
                }
            }
                
        }
        
        
        // Move database operations to background thread
        progressUpdateCounter += 1

        if progressUpdateCounter >= progressSaveInterval {
            savePlayPosition()
                   
            progressUpdateCounter = 0
                    
        }
    }
    
    private func savePlayPosition() {
        guard let episode = currentEpisode else { return }
        Task.detached(priority: .background) {
            await self.episodeActor.setPlayPosition(episodeID: episode.id, position: self.playPosition) // this updates the playposition in the database
             episode.modelContext?.saveIfNeeded()
        }
    }
    
    func skipTo(chapter: Chapter) async{
        
        if chapter.episode == currentEpisode{
            if let start = chapter.start{
                
                jumpTo(time: start)
            }
        }else{
            if let newEpisode = chapter.episode{
                await playEpisode(newEpisode.id, playDirectly: true)
            }
        }
    }


    private func handlePlaybackFinished() {
        print("Playback finished. - handlePlaybackFinished")
        updateLastPlayed()
        stopPlaybackUpdates()
        print("currenty PlayProgress: \(currentEpisode?.playProgress ?? 0)")
        if currentEpisode?.playProgress ?? 0 >= progressThreshold {
            Task{
                if let nextEpisodeID = await playlistActor.nextEpisode(){
                    BasicLogger.shared.log("Playing next episode")
                    await playEpisode(nextEpisodeID, playDirectly: true)
                }
            }
        }

        

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
    
    func setupStaticNowPlayingInfo()   {
        guard let episode = currentEpisode else { return }
        /*
        var mediaArtwort:MPMediaItemArtwork?
        
        
        if let chapterCover = currentChapter?.imageData{
            if let image = UIImage(data: chapterCover){
                mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
         else
        
         if let imageURL = currentEpisode?.imageURL{
             Task{
                 if let image = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                     mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                 }
             }
        }
         */
        
        
        let info: [String: Any] =  [
        //    MPMediaItemPropertyArtwork: mediaArtwort ?? UIImage(named: "AppIcon") ?? UIImage(),
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.author ?? episode.podcast?.title ?? episode.podcast?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0
        //    MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
         //   MPNowPlayingInfoPropertyPlaybackRate: playbackRate
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
