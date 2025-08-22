import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import BasicLogger

@Observable
@MainActor
class Player: NSObject {
    
    let progressThreshold: Double = 0.99 // how much of an episode must be played before it is considered "played"
    
    static let shared = Player()
  //  private let modelContext = ModelContainerManager.shared.container.mainContext
     let episodeActor: EpisodeActor? = {

         return EpisodeActor(modelContainer: ModelContainerManager.shared.container)
     }()
     let chapterActor: ChapterModelActor? = {

         return ChapterModelActor(modelContainer: ModelContainerManager.shared.container)
     }()
    let playlistActor: PlaylistModelActor? = {

        return try? PlaylistModelActor(modelContainer: ModelContainerManager.shared.container)
    }()
    
    let settingsActor: PodcastSettingsModelActor? = {

        return PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container)
    }()

    

    
    private let nowPlayingInfoActor = NowPlayingInfoActor()
    private let engine = PlayerEngine()
    private var playbackTask: Task<Void, Never>?

    var playbackRate: Float = 1.0 {
        didSet {
            setPlayBackSpeed(to: playbackRate)
            }
    }

    var playPosition: Double = 0.0
    
    
    var currentEpisode: Episode?
    var currentEpisodeID: UUID?
    
    
    let fileMonitor = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])

    var downloadedFiles: Set<URL> {
        fileMonitor.downloadedFiles
    }

    var isCurrentEpisodeDownloaded: Bool {
        return currentEpisode?.metaData?.calculatedIsAvailableLocally ?? false
    }
    
    
    var isPlaying: Bool = false
    
    var chapterProgress: Double?
    var currentChapter: Marker?
    var nextChapter: Marker?
    var chapters: [Marker]?
    
    var allowScrubbing:Bool?

    

    
    private var nowPlayingArtwork: MPMediaItemArtwork?

    
    override init()  {
      //  episodeActor = EpisodeActor(modelContainer: ModelContainerManager.shared.container)
        
        super.init()
        loadLastPlayedEpisode()
        loadPlayBackSpeed()
        listenToEvent()
        pause()
        addChangeSettingsObserver()
        Task{
            allowScrubbing = await settingsActor?.getAppSliderEnable()
        }
    }
    
    private  func addChangeSettingsObserver() {
        NotificationCenter.default.addObserver(forName: .podcastSettingsDidChange, object: nil, queue: nil, using: { [weak self] notification in
            // print("received podcast settings change notification")
            Task { @MainActor in
                self?.loadPlayBackSpeed()
                self?.allowScrubbing = await self?.settingsActor?.getAppSliderEnable()
                if let lockscreenEnable = await self?.settingsActor?.getAppSliderEnable() {
                    RemoteCommandCenter.shared.updateLockScreenScrubbableState(lockscreenEnable)
                }
                
            }
        })
    }
    
    private func loadLastPlayedEpisode() {
        if let episodeIDString = UserDefaults.standard.string(forKey: "lastPlayedEpisodeID"),
           let episodeUUID = UUID(uuidString: episodeIDString) {
            
            Task { 
                if let episode = await fetchEpisode(with: episodeUUID) {
                    // print("loading last episode: \(episode.title)")
                    currentEpisode = episode
                    currentEpisodeID = episode.id
                    await playEpisode(episode.id, playDirectly: false)

                }
            }
        }
    }
    
    private func setPlayBackSpeed(to playbackRate: Float){
        if isPlaying{
            Task{
                await engine.setRate(playbackRate)
                await settingsActor?.setPlaybackSpeed(for: currentEpisode?.podcast?.id , to: playbackRate)
                if playbackRate >= 1 {
                    isPlaying = true
                }
            }
        }
    }
    
    func switchPlayBackSpeed() {
        let playbackSpeeds: [Float] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
        var currentSpeedIndex: Int = 0
        if let closestIndex = playbackSpeeds.enumerated().min(by: { abs($0.element - playbackRate) < abs($1.element - playbackRate) })?.offset {
            currentSpeedIndex = closestIndex
        }
        
            currentSpeedIndex = (currentSpeedIndex + 1) % playbackSpeeds.count
            let newRate = playbackSpeeds[currentSpeedIndex]
            playbackRate = newRate
            
    }
    
    private func loadPlayBackSpeed() {
        // this function should check if there is a custom playbackRate set for the podcast. If not load a standard or the last used playbackRate.
        Task{
            let savedPlaybackRate = await settingsActor?.getPlaybackSpeed(for: currentEpisode?.podcast?.id) ?? 1.0
            // print("loadPlayBackSpeed: did Change: \(playbackRate != savedPlaybackRate)")
            if savedPlaybackRate > 0, playbackRate != savedPlaybackRate {
                playbackRate = savedPlaybackRate
                /*
                if isPlaying{
                    Task {
                        await engine.setRate(playbackRate)
                    }
                }
                */
            }
        }
    }
    
    func fetchEpisode(with id: UUID) async -> Episode? {
        do {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            return try  episodeActor?.modelContainer.mainContext.fetch(descriptor).first
        } catch {
            return nil
        }
    }
    

    
    private func fetchChapters(for episodeID: UUID)  async -> [Marker]? {
        
        guard let episode = await fetchEpisode(with: episodeID) else { return [] }
    

           
             let chapters = episode.chapters
            
        if !(chapters?.isEmpty ?? true){
            
                
                
                let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]
                
                let categoryGroups = Dictionary(grouping: chapters ?? [], by: { $0.title + (Duration.seconds($0.start ?? 0.0).formatted(.units(width: .narrow))) })
                
                return categoryGroups.values.flatMap { group in
                let highestCategory = group.max(by: { preferredOrder.firstIndex(of: $0.type) ?? 0 < preferredOrder.firstIndex(of: $1.type) ?? preferredOrder.count })?.type
                 
           
                    
                return group.filter { $0.type == highestCategory }
                }
            
            
        } else {
      
            return []
        }
    }
    
    private func updateChapters() {
        Task{
            guard let currentEpisodeID else { return }
            chapters = await fetchChapters(for: currentEpisodeID)
        }
    }
    
    private func updateCurrentChapter() -> Bool{
        if currentEpisode?.chapters != nil, currentEpisode?.chapters?.isEmpty == false {
            updateChapters()
            let playingChapter = chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 <= self.playPosition})
            if currentChapter != playingChapter {
                
                if let chapterProgress, let currentChapter  {
                    saveChapterProgress(chapter: currentChapter, progress: chapterProgress)
                }
                currentChapter = playingChapter
                if let currentChapterID = currentChapter?.id{
                    Task{
                        currentChapter?.shouldPlay = await chapterActor?.shouldPlayChapter(currentChapterID) ?? true // check that the user has not recently changed the toggle to play this chapter
                    }
                }
                chapterProgress = 0.0
                updateChapterProgress()
                nextChapter = chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 > self.playPosition})
                
                return true
            }
        }
        return false
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
    
    private func saveChapterProgress(chapter: Marker, progress: Double){
        let chapterID = chapter.id
       
            Task.detached(priority: .background) {
                await self.chapterActor?.setChapterProgress(progress, for: chapterID)
            }
       
    }
        
    private func unloadEpisode(episodeUUID: UUID) async{
        // print("unloadEpisode \(episodeUUID)")

        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        currentEpisode = nil
        currentEpisodeID = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = nil
        
        
        UserDefaults.standard.removeObject(forKey: "lastPlayedEpisodeUUID")
        
        
        if episode.playProgress >= progressThreshold {

            await episodeActor?.markasPlayed(episodeUUID)
            
        }else{

            try? await playlistActor?.add(episodeID: episodeUUID, to: .front)

        }
        
        
    }
    
    
    
    func playEpisode(_ episodeUUID: UUID, playDirectly: Bool = true, startingAt time: Double? = nil) async {
        
        // print("playEpisode \(episodeUUID)")
        guard let episode = await fetchEpisode(with: episodeUUID) else { return }
        if let currentEpisodeID, episodeUUID != currentEpisodeID{
            await unloadEpisode(episodeUUID: currentEpisodeID)
            
            try? await playlistActor?.remove(episodeID: episodeUUID)
            
        }
        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeID = episode.id
        // print("unloading finished - new episode: \(String(describing: currentEpisodeID)) - \(episode.title)")

        updateChapters()
        

        UserDefaults.standard.set(episode.id.uuidString, forKey: "lastPlayedEpisodeID")

        Task { @MainActor in
            // print("loading new AVPlayerItem - \(isCurrentEpisodeDownloaded) - \(episode.localFile?.path ?? "nil")")
            // Load the AVPlayerItem asynchronously
            let item: AVPlayerItem = {
                if isCurrentEpisodeDownloaded, let localFile = episode.localFile {
                
                    let localURL: URL
                    if localFile.isFileURL && FileManager.default.fileExists(atPath: localFile.path) {
                       
                        localURL = localFile
                        // print("file Exists - \(localURL.path)")
                    } else {
                        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                        localURL = caches.appendingPathComponent(localFile.path)
                        // print("file does not exist - \(localURL.path)")

                    }
                    guard FileManager.default.fileExists(atPath: localURL.path) else {
                        // print("Local file does not exist at \(localURL.path), falling back to remote.")
                        if let remoteURL = episode.url {
                            return AVPlayerItem(url: remoteURL)
                        } else {
                            fatalError("No valid URL for playback.")
                        }
                    }
                    return AVPlayerItem(url: localURL)
                } else if let remoteURL = episode.url {
                    // print("loading remote file from \(remoteURL.absoluteString)")
                    return AVPlayerItem(url: remoteURL)
                } else {
                    fatalError("No valid URL for playback.")
                }
            }()
           
            let duration = item.duration.seconds
            
            // print("comparing episode Duration \(currentEpisode?.duration ?? 0.0) with item duration \(duration) ")
            
            if duration.isNormal && currentEpisode?.duration != duration {
                currentEpisode?.duration = duration
            }
            
            await engine.replaceCurrentItem(with: item)
            
            BasicLogger.shared.log("playing episode \(episode.title) - lastPlayPosition \(String(describing: currentEpisode?.metaData?.playPosition))")
            if let time  {
                BasicLogger.shared.log("Time provided when calling the playEpisode function: \(time)")

                await jumpTo(time: time)
            }else if let lastPlayPosition = currentEpisode?.metaData?.playPosition, lastPlayPosition < ((currentEpisode?.duration ?? 1.0) * progressThreshold) {
             

                BasicLogger.shared.log("jump to last position: \(lastPlayPosition)")
                
                await jumpTo(time: lastPlayPosition)
            } else {
                BasicLogger.shared.log("no time - jump to beginning")

                await jumpTo(time: 0)
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
            
             return AnyView(CoverImageView(episode: playing))
             
             
        }else{
            return AnyView(EmptyView())
        }
    }
    
    var progress:Double {
        
        set{
            Task{
                let seconds:Double  = newValue * (currentEpisode?.duration ?? 1.0)
                let newTime = CMTime(seconds: seconds, preferredTimescale: 1)
                await jumpTo(time: newTime.seconds)
            }
        }
        get{
            
            if let duration = currentEpisode?.duration {
                return ((playPosition) / duration)
            }else{
                return 0.0
            }
        }
        
    }
    
    var maxPlayProgress: Double?{
        get{
           return currentEpisode?.maxPlayProgress
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
                // print("received interruption event: \(event)")

        
                guard let self else { return }
                switch event {
                case .began:
                    Task{
                       //  await BasicLogger.shared.log("received interruption event: began")
                        await self.handleInterruptionBegan()
                    }
                case .ended:
                    Task{
                       //  await BasicLogger.shared.log("received interruption event: ended")

                        await self.resumeAfterInterruption()
                    }
                case .pause:
                    Task{
                       //  await BasicLogger.shared.log("received interruption event: pause")

                        await self.handleInterruptionBegan()
                    }
                case .resume:
                    Task{
                       //  await BasicLogger.shared.log("received interruption event: reume")

                        await self.resumeAfterInterruption()
                    }
                case .finished:
                    Task{
                       //  await BasicLogger.shared.log("received interruption event: finished")

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
        updateLastPlayed()
        startPlaybackUpdates()
        startNowPlayingInfoUpdater()
        Task {
            
            await engine.setRate(playbackRate)
            isPlaying = true
        }

       
        if let episodeURL =  currentEpisode?.url{
            Task {
                await self.episodeActor?.addplaybackStartTimes(episodeURL: episodeURL, date: Date())
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
    
     func jumpPlaypostion(by seconds:Double){
         Task{
             let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
             
             let now = CMTimeMakeWithSeconds(playPosition,preferredTimescale: 1)
             let jumpToTime = CMTimeAdd(now, secondsToAdd).seconds
             await jumpTo(time: jumpToTime)
         }
    }

    func jumpTo(time: Double) async {
        let safeTime = max(0, time)
        let cmTime = CMTime(seconds: safeTime, preferredTimescale: 600)

        // Wait for seek to finish
        await engine.seek(to: cmTime)

        // Only after seek completes, update state
        playPosition = time
        _ = updateCurrentChapter()
        updateChapterProgress()
        savePlayPosition()
    }
    
    func setRate(_ rate: Float){
        Task { await engine.setRate(rate) }
        playbackRate = rate
        if rate > 0 {
            startPlaybackUpdates()
            startNowPlayingInfoUpdater()
        }

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
            // print("Loop ended") // This should run if the loop ends gracefully

        }
    }
    
    
    
    func updateLastPlayed()  {
        if let currentEpisode {
            Task{
                await episodeActor?.setLastPlayed(currentEpisode.id)
                await episodeActor?.setPlayPosition(episodeID: currentEpisode.id, position: playPosition)
            }
        }
    }



    private var progressUpdateCounter = 0
    private let progressSaveInterval = 40  // 0.5 seconds * 20 = 10 seconds
    
    private func updateEpisodeProgress(to time: Double) {
        guard isPlaying == true else { return }
        
            
        if let chapters = currentEpisode?.chapters, chapters.count > 0 {
            Task{
                let chapterChange = updateCurrentChapter()
                updateChapterProgress()
                await skipIfNeeded(chapterChange: chapterChange)
            }
        }

            updateNowPlayingInfo()
        
        
            progressUpdateCounter += 1
            if progressUpdateCounter >= progressSaveInterval {
                if let chapters = currentEpisode?.chapters, chapters.count > 0 {
                    updateChapters()
                }
              
                savePlayPosition()
                progressUpdateCounter = 0
            }
        }
    
    // Helper to cascade skip consecutive skipped chapters and handle last skipped chapter
    private func skipIfNeeded(chapterChange: Bool) async {
        guard chapterChange else { return }
        updateChapters()
        await skipOverChapters()
    }

    private func skipOverChapters() async {
        guard let currentChapter else { return }

        if currentChapter.shouldPlay { return }

        let id = currentChapter.id
        Task.detached(priority: .background) {
            await self.chapterActor?.markChapterAsSkipped(id)
        }

        guard let nextChapter = chapters?
            .sorted(by: { ($0.start ?? 0) < ($1.start ?? 0) })
            .first(where: { ($0.start ?? 0) > self.playPosition })
        else {
            handlePlaybackFinished()
            return
        }

        let start = nextChapter.start ?? 0
        guard start < (currentEpisode?.duration ?? .greatestFiniteMagnitude) else {
            handlePlaybackFinished()
            return
        }

        // Await the seek
        await jumpTo(time: start)

        // After the seek, update and re-check
        await skipOverChapters()
    }
    
    
    private func savePlayPosition() {
        guard let episode = currentEpisode else { return }
        Task.detached(priority: .background) {
            await self.episodeActor?.setPlayPosition(episodeID: episode.id, position: self.playPosition) // this updates the playposition in the database
             episode.modelContext?.saveIfNeeded()
            /*
            if episode.chapters?.isEmpty == false {
                await self.chapterActor?.saveAllChanges()
            }
          */
          
        }

    }
    
    
    
    func skipTo(chapter: Marker) async{
        // print("skip to chapter \(chapter.title)")
            if let newEpisode = chapter.episode, let start = chapter.start{
                await playEpisode(newEpisode.id, playDirectly: true, startingAt: start)
            }
        
    }
    
    func skipToNextChapter() async{
        
        
        
        let nextChapter = chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).first(where: {$0.start ?? 0 >= self.playPosition})
        
        
        
        if let start = nextChapter?.start{
             await jumpTo(time: start)
        }else if let end = currentChapter?.end{
            await jumpTo(time: end)
        }
    }
    
    func skipToChapterStart() async{
        
        let referenceTime = self.playPosition - 3 // if the chapter just started, jump to the previous chapter
   //     let lastChapter = chapters?.sorted(by: {$0.start ?? 0 < $1.start ?? 0}).last(where: {$0.start ?? 0 <= referenceTime})
        
        guard let currentChapter else {
            return
        }
        if let start = currentChapter.start{
             await jumpTo(time: start)
        }
    }


    private func handlePlaybackFinished() {
        // print("Playback finished. - handlePlaybackFinished")
       
        
        updateLastPlayed()
        stopPlaybackUpdates()
        savePlayPosition()
        // print("currenty PlayProgress: \(currentEpisode?.playProgress ?? 0)")
     //   if currentEpisode?.playProgress ?? 0 >= progressThreshold {
            Task{
                if let nextEpisodeID = try? await playlistActor?.nextEpisode(){
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
    

    
    // Always call this function to update nowPlayingInfo—when artwork or position/rate changes.
    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let episode = currentEpisode else { return }
    
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist:  episode.podcast?.title ?? episode.podcast?.author ?? episode.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        nowPlayingInfoActor.updateInfo(info)
    }
    
    func setupStaticNowPlayingInfo() {
        updateNowPlayingInfo()
    }
    
    func initRemoteCommandCenter(){
        _ = RemoteCommandCenter.shared
    }
    
    private var nowPlayingInfoTimer: Timer?

    private func startNowPlayingInfoUpdater() {
        nowPlayingInfoTimer?.invalidate()
        nowPlayingInfoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            Task { @MainActor in
                self.updateNowPlayingInfo()
            }
        }
    }
    
    func createBookmark() async{
        if  let currentEpisodeID{
            await EpisodeActor(modelContainer: ModelContainerManager.shared.container).createBookMarkfor(episodeID: currentEpisodeID, at: playPosition)
        }
    }
    
  
    private func updateNowPlayingCover() async{
        guard let episode =  currentEpisode else {
            // print("currentEpisode is nil")
            return
        }
        
        let chapterImage = currentChapter?.image
        let chapterImageData = currentChapter?.imageData
        
        
       
            // print("updating now playing cover")

            guard let imageURL = chapterImage ?? episode.imageURL ?? episode.podcast?.imageURL else {
                // print("imageURL is nil")
                return }
            
            if let chapterImageData = chapterImageData, let image = UIImage(data: chapterImageData) {
                // print("using chapter image data")

                nowPlayingInfoActor.setArtwork(image)
                
            }else if let originalImage = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                // print("using URL image Data \(imageURL.absoluteString)")
                let targetSize = CGSize(width: 600, height: 600)
                if let resizedImage = downscale(image: originalImage, to: targetSize) {
                
                    nowPlayingInfoActor.setArtwork(resizedImage)
                   
                    
                }
            }else{
                // print("image is nil")
                
            }
        }
    
    func downscale(image: UIImage, to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
    
    
    private func stopNowPlayingInfoUpdater() {
        nowPlayingInfoTimer?.invalidate()
        nowPlayingInfoTimer = nil
    }
}

