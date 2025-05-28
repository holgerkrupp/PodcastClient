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
    static let episodeActor = EpisodeActor(modelContainer: ModelContainerManager().container)
     let chapterActor = ChapterModelActor(modelContainer: ModelContainerManager().container)

    private let engine = PlayerEngine()
    private var playbackTask: Task<Void, Never>?

    var playbackRate: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")

        //    Task { await engine.setRate(playbackRate) }
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
    var playlistActor: PlaylistModelActor
    
    var settingLockScreenScrubbing: Bool = false
    
    
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
            
            Task { 
                if let episode = await fetchEpisode(with: episodeUUID) {
                    print("loading last episode: \(episode.title)")
                    currentEpisode = episode
                    currentEpisodeID = episode.id
                    await playEpisode(episode.id, playDirectly: false)

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
            if let chapterProgress, let currentChapter  {
                saveChapterProgress(chapter: currentChapter, progress: chapterProgress)
            }
            currentChapter = playingChapter
            chapterProgress = 0.0
            updateChapterProgress()
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
        currentChapter.progress = chapterProgress
        if progressUpdateCounter >= progressSaveInterval {
            guard let chapterProgress  else { return }
            saveChapterProgress(chapter: currentChapter, progress: chapterProgress)
        }
    }
    
    private func saveChapterProgress(chapter: Chapter, progress: Double){
        let chapterID = chapter.id
        Task.detached(priority: .background) {
            await self.chapterActor.setChapterProgress(progress, for: chapterID)
        }
    }
        
    private func unloadEpisode(episodeUUID: UUID) async{
       
        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        print("unloading episode \(episode.title)")
        currentEpisode = nil
        currentEpisodeID = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        UserDefaults.standard.removeObject(forKey: "lastPlayedEpisodeUUID")
        
        
        if episode.playProgress > progressThreshold {
            print("marking episode \(episode.title) as Played")

            await episodeActor.markasPlayed(episodeUUID)
            
        }else{
            print("moving episode \(episode.title) back to playlist")

            let playlistModelActor = PlaylistModelActor(modelContainer: ModelContainerManager().container)
            await playlistModelActor.add(episodeID: episodeUUID, to: .front)

        }
    }
    
    
    
    func playEpisode(_ episodeUUID: UUID, playDirectly: Bool = true, startingAt time: Double? = nil) async {
        
        print("playing episode \(episodeUUID)")
        
        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        if let currentEpisodeID, episodeUUID != currentEpisodeID{
            print("unloading episode \(currentEpisodeID)")
            await unloadEpisode(episodeUUID: currentEpisodeID)
            await playlistActor.remove(episodeID: episodeUUID)
        }

        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeID = episode.id
        
        

        UserDefaults.standard.set(episode.id.uuidString, forKey: "lastPlayedEpisodeID")

        Task { @MainActor in
            // Load the AVPlayerItem asynchronously
            let item = await Task {
                if episode.metaData?.calculatedIsAvailableLocally ?? false, let localFile = episode.localFile {
                    AVPlayerItem(url: localFile)
                }else{
                    AVPlayerItem(url: episode.url)
                }
            }.value
           
            
            await engine.replaceCurrentItem(with: item)
 
            if let time  {
                jumpTo(time: time)
            }else if let lastPlayPosition = currentEpisode?.metaData?.playPosition {
                print("last position: \(lastPlayPosition)")
                jumpTo(time: lastPlayPosition)
            } else {
                jumpTo(time: 0)
            }
            _ = updateCurrentChapter()
            initRemoteCommandCenter()
            setupStaticNowPlayingInfo()
        await   updateNowPlayingCover()
            if playDirectly {
                play()
            }
            
        }
        
    }
    
    var coverImage: some View{
        if let playing = currentEpisode{
            
             return AnyView(EpisodeCoverView(episode: playing))
             
             
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
                print("received interruption event: \(event)")

        
                guard let self else { return }
                switch event {
                case .began:
                    Task{
                        await BasicLogger.shared.log("received interruption event: began")
                        await self.handleInterruptionBegan()
                    }
                case .ended:
                    Task{
                        await BasicLogger.shared.log("received interruption event: ended")

                        await self.resumeAfterInterruption()
                    }
                case .pause:
                    Task{
                        await BasicLogger.shared.log("received interruption event: pause")

                        await self.handleInterruptionBegan()
                    }
                case .resume:
                    Task{
                        await BasicLogger.shared.log("received interruption event: reume")

                        await self.resumeAfterInterruption()
                    }
                case .finished:
                    Task{
                        await BasicLogger.shared.log("received interruption event: finished")

                        await self.handlePlaybackFinished()
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
       
        if let episodeURL =  currentEpisode?.url{
            Task {
                await self.episodeActor.addplaybackStartTimes(episodeURL: episodeURL, date: Date())
            }
        }

    }
    
    

    func pause() {
        Task { 
            await engine.pause()
            isPlaying = false
        }
        updateLastPlayed()
        savePlayPosition()
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
             //       setupStaticNowPlayingInfo()
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
                Task.detached(priority: .background) {
                    await self.chapterActor.markChapterAsSkipped(currentChapter.id)
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
            await self.chapterActor.saveAllChanges()
          
        }

    }
    
    
    
    func skipTo(chapter: Chapter) async{
            if let newEpisode = chapter.episode, let start = chapter.start{
                await playEpisode(newEpisode.id, playDirectly: true, startingAt: start)
            }
        
    }
    
    func skipToNextChapter() async{
        if let start = nextChapter?.start{
             jumpTo(time: start)
        }
    }
    
    func skipToChapterStart() async{
        guard let currentChapter else {
            return
        }
        if let start = currentChapter.start{
             jumpTo(time: start)
        }
    }


    private func handlePlaybackFinished() {
        print("Playback finished. - handlePlaybackFinished")
       
        
        updateLastPlayed()
        stopPlaybackUpdates()
        savePlayPosition()
        print("currenty PlayProgress: \(currentEpisode?.playProgress ?? 0)")
     //   if currentEpisode?.playProgress ?? 0 >= progressThreshold {
            Task{
                if let nextEpisodeID = await playlistActor.nextEpisode(){
                    BasicLogger.shared.log("Playing next episode")
                    await playEpisode(nextEpisodeID, playDirectly: true)
                }else{
                    if let currentEpisodeID{
                        await unloadEpisode(episodeUUID: currentEpisodeID)
                    }
                    
                }
            }
     //   }

        

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
         if let chapterCover = currentChapter?.imageData{
         if let image = UIImage(data: chapterCover){
         mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
         }
         }
         else
         
         if let imageURL = currentEpisode?.coverFile{
         Task{
         if let image = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
         mediaArtwort = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
         }
         }
         
         Task {
         guard let imageURL = currentEpisode?.coverFile else { return }
         let saveLocation = currentEpisode?.coverFileLocation
         
         if let image = await ImageLoaderAndCache.loadUIImage(from: imageURL, saveTo: saveLocation) {
         await
         mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
         
         }
         }
         }
         */
        
        let info: [String: Any] =  [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.author ?? episode.podcast?.title ?? episode.podcast?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        
        
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        }
      
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
            self.jumpPlaypostion(by: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        
        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        RCC.skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.jumpPlaypostion(by: -seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { event in
         //   self.bookmark()
            return.success
        }
        
        RCC.changePlaybackPositionCommand.isEnabled = settingLockScreenScrubbing
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
    
  
    private func updateNowPlayingCover() async{
        guard let episode =  currentEpisode else {
            print("currentEpisode is nil")
            return
        }
        
        let chapterImage = currentChapter?.image
        let chapterImageData = currentChapter?.imageData
        
        
        Task.detached(priority: .userInitiated) {
            print("updating now playing cover")

            guard let imageURL = chapterImage ?? episode.imageURL ?? episode.podcast?.imageURL else {
                print("imageURL is nil")
                return }
            
            if let chapterImageData = chapterImageData, let image = UIImage(data: chapterImageData) {
                print("using chapter image data")
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 100, height: 100)) { _ in
                   image
                }
                
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                
            }else if let image =  await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                
            }else{
                print("image is nil")
                
            }
        }}
    
    
    private func stopNowPlayingInfoUpdater() {
        nowPlayingInfoTimer?.invalidate()
        nowPlayingInfoTimer = nil
    }
}
