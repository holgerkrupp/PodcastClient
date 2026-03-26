import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import BasicLogger

@Observable
@MainActor
class Player {
    
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
    
    // Added PlaySessionTrackerActor for session tracking integration
    let playSessionTracker = PlaySessionTrackerActor(modelContainer: ModelContainerManager.shared.container)

    

    
    private let nowPlayingInfoActor = NowPlayingInfoActor()
    private let engine = PlayerEngine()
    private var playbackTask: Task<Void, Never>?

    var playbackRate: Float = 1.0 {
        didSet {
            setPlayBackSpeed(to: playbackRate)
            }
    }
    ///MARK: Sleep timer
    private var timer: Timer?
    var endDate: Date? // when playback should pause
    var remainingTime: TimeInterval?
    var stopAfterEpisode: Bool = false
    
    
    
    
    var playPosition: Double = 0.0
    
    
    var currentEpisode: Episode?
    var currentEpisodeURL: URL?
    
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
    private var lastArtworkURL: URL?

    
     init()  {
      //  episodeActor = EpisodeActor(modelContainer: ModelContainerManager.shared.container)
        
      //  super.init()
        Task {
            // One-time migration from old UserDefaults storage of lastPlayedEpisodeID to playlist system
            await migrateLastPlayedFromUserDefaultsIfNeeded()
            await restoreLastPlayedFromPlaylist()
        }
        loadPlayBackSpeed()
        listenToEvent()
        Task{
            await playSessionTracker.startRecovery()
        }
        pause()
        addChangeSettingsObserver()
        Task{
            allowScrubbing = await settingsActor?.getAppSliderEnable()
        }
        
    }
    
    /// One-time migration from UserDefaults key "lastPlayedEpisodeID" to playlist system.
    /// If a last played episode ID exists in UserDefaults, fetch the episode, add it to the front of the playlist,
    /// then remove the UserDefaults entry. This prevents loss of last played info after update.
    private func migrateLastPlayedFromUserDefaultsIfNeeded() async {
        let key = "lastPlayedEpisodeID"
        if let idString = UserDefaults.standard.string(forKey: key),
           let episodeID = UUID(uuidString: idString),
           let episode = await fetchEpisode(with: episodeID),
           let episodeURL = episode.url {
            do {
                try await playlistActor?.add(episodeURL: episodeURL, to: .front)
            } catch {
                // handle error silently or log if needed
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    func restoreLastPlayedFromPlaylist() async {
        if let episodeURLs = try? await playlistActor?.orderedEpisodeURLs(),
           let firstURL = episodeURLs.first {
            await playEpisode(firstURL, playDirectly: false)
        }
    }
    
    func setSleepTimer(minutes: Int) {
        if minutes > 0 {
            endDate = Date().addingTimeInterval(Double(minutes * 60))
            startSleepTimer()
        } else {
            cancelSleepTimer()
        }
    }

    private func startSleepTimer() {
        timer?.invalidate()
        timer = nil
        updateRemainingTime()

        guard endDate != nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateRemainingTime()
            }
        }
    }

    private func updateRemainingTime() {
        if let endDate {
            let remaining = endDate.timeIntervalSinceNow
            remainingTime = remaining > 0 ? remaining : nil
            if remainingTime == nil {
                cancelSleepTimer()
                pause()
            }
        } else {
            remainingTime = nil
        }
    }

    func cancelSleepTimer() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        remainingTime = nil
        stopAfterEpisode = false
    }
    
    private  func addChangeSettingsObserver() {
        NotificationCenter.default.addObserver(forName: .podcastSettingsDidChange, object: nil, queue: nil, using: { [weak self] notification in
            // print("received podcast settings change notification")
            Task { @MainActor in
                self?.loadPlayBackSpeed()
                self?.allowScrubbing = await self?.settingsActor?.getAppSliderEnable()
                if let lockscreenEnable = await self?.settingsActor?.getLockScreenSliderEnable() {
                    RemoteCommandCenter.shared.updateLockScreenScrubbableState(lockscreenEnable)
                }
                
            }
        })
    }
    
    private func setPlayBackSpeed(to playbackRate: Float){
        if isPlaying{
            Task{
                await engine.setRate(playbackRate)
                await settingsActor?.setPlaybackSpeed(for: currentEpisode?.podcast?.feed , to: playbackRate)
                if playbackRate >= 1 {
                    isPlaying = true
                }
            }
        }

        if currentEpisode != nil {
            updateNowPlayingInfo()
        } else {
            nowPlayingInfoActor.updateField(key: MPNowPlayingInfoPropertyPlaybackRate, value: playbackRate)
            nowPlayingInfoActor.updateField(key: MPNowPlayingInfoPropertyDefaultPlaybackRate, value: 1.0)
        }
        
        Task {
            if currentEpisode != nil {
                await playSessionTracker.handlePlaybackRateChange(
                    to: playbackRate,
                    at: playPosition
                )
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
            let savedPlaybackRate = await settingsActor?.getPlaybackSpeed(for: currentEpisode?.podcast?.feed) ?? 1.0
            // print("loadPlayBackSpeed: did Change: \(playbackRate != savedPlaybackRate)")
            if savedPlaybackRate > 0, playbackRate != savedPlaybackRate {
                playbackRate = savedPlaybackRate

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
    
    func fetchEpisode(with url: URL?) async -> Episode? {
        do {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.url == url })
            return try  episodeActor?.modelContainer.mainContext.fetch(descriptor).first
        } catch {
            return nil
        }
    }

    private func resolvedChapters(for episode: Episode) -> [Marker] {
        let chapters = episode.chapters ?? []
        guard chapters.isEmpty == false else { return [] }

        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]
        let priorityByType = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) }
        )
        let categoryGroups = Dictionary(grouping: chapters) {
            $0.title + Duration.seconds($0.start ?? 0.0).formatted(.units(width: .narrow))
        }

        var resolved: [Marker] = []
        resolved.reserveCapacity(chapters.count)

        for group in categoryGroups.values {
            var bestType: MarkerType?
            var bestPriority = preferredOrder.count

            for marker in group {
                let priority = priorityByType[marker.type] ?? preferredOrder.count
                if priority < bestPriority {
                    bestPriority = priority
                    bestType = marker.type
                }
            }

            guard let bestType else { continue }
            resolved.append(contentsOf: group.filter { $0.type == bestType })
        }

        resolved.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        return resolved
    }

    private func updateChapters() {
        guard let currentEpisode else {
            chapters = []
            currentChapter = nil
            nextChapter = nil
            return
        }

        chapters = resolvedChapters(for: currentEpisode)
    }
    
    private func updateCurrentChapter() -> Bool {
        guard let chapters, chapters.isEmpty == false else {
            currentChapter = nil
            nextChapter = nil
            chapterProgress = nil
            return false
        }

        let playingChapter = chapters.last(where: { ($0.start ?? 0) <= playPosition })
        nextChapter = chapters.first(where: { ($0.start ?? 0) > playPosition })

        guard currentChapter != playingChapter else { return false }

        if let chapterProgress, let currentChapter {
            saveChapterProgress(chapter: currentChapter, progress: chapterProgress)
        }

        currentChapter = playingChapter
        if let currentChapterID = currentChapter?.uuid {
            Task {
                currentChapter?.shouldPlay = await chapterActor?.shouldPlayChapter(currentChapterID) ?? true
            }
        }
        chapterProgress = 0.0
        updateChapterProgress()
        Task {
            await updateNowPlayingCover()
        }
        return true
    }
    
    private func updateChapterProgress(){
        guard let currentChapter = currentChapter else { return }
        let chapterEnd = currentChapter.end ?? nextChapter?.start ?? currentEpisode?.duration ?? 1.0
        let chapterStart = currentChapter.start ?? 0
        let duration = max(chapterEnd - chapterStart, .leastNonzeroMagnitude)
        chapterProgress = (playPosition - chapterStart) / duration
        currentChapter.progress = chapterProgress
        if progressUpdateCounter >= progressSaveInterval {
            guard let chapterProgress  else { return }
            saveChapterProgress(chapter: currentChapter, progress: chapterProgress)
        }
    }
    
    private func saveChapterProgress(chapter: Marker, progress: Double){
        if let chapterID = chapter.uuid{

            let chapterActor = self.chapterActor
            Task.detached(priority: .background) {
                await chapterActor?.setChapterProgress(progress, for: chapterID)
            }
        }
    }

    
    private func playbackItem(for episode: Episode) -> AVPlayerItem? {
        if episode.metaData?.calculatedIsAvailableLocally == true,
           let localFile = episode.localFile,
           FileManager.default.fileExists(atPath: localFile.path) {
            return AVPlayerItem(url: localFile)
        }

        guard let remoteURL = episode.url else { return nil }
        return AVPlayerItem(url: remoteURL)
    }

    private func unloadEpisode(episodeURL: URL) async {
        let episode = (currentEpisode?.url == episodeURL) ? currentEpisode : await fetchEpisode(with: episodeURL)
        guard let episode else { return }

        stopPlaybackUpdates()
        currentEpisode = nil
        currentEpisodeURL = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        progressUpdateCounter = 0
        lastArtworkURL = nil
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: nil)

        if episode.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: episodeURL)
            await episodeActor?.archiveEpisode(episodeURL)
        } else {
            try? await playlistActor?.add(episodeURL: episodeURL, to: .front)
        }
    }
    
    
    
    func playEpisode(_ episodeURL: URL?, playDirectly: Bool = true, startingAt time: Double? = nil) async {
        guard let episodeURL,
              let episode = await fetchEpisode(with: episodeURL) else { return }

        if let currentEpisodeURL, currentEpisodeURL != episodeURL {
            await unloadEpisode(episodeURL: currentEpisodeURL)
        }

        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeURL = episodeURL
        progressUpdateCounter = 0
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)

        updateChapters()

        try? await playlistActor?.add(episodeURL: episodeURL, to: .front)
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: episodeURL)

        guard let item = playbackItem(for: episode) else { return }

        let duration = item.duration.seconds
        if duration.isNormal && currentEpisode?.duration != duration {
            currentEpisode?.duration = duration
        }

        await engine.replaceCurrentItem(with: item)

        BasicLogger.shared.log("playing episode \(episode.title) - lastPlayPosition \(String(describing: currentEpisode?.metaData?.playPosition))")
        if let time {
            BasicLogger.shared.log("Time provided when calling the playEpisode function: \(time)")
            await jumpTo(time: time)
        } else if let lastPlayPosition = currentEpisode?.metaData?.playPosition,
                  lastPlayPosition < ((currentEpisode?.duration ?? 1.0) * progressThreshold) {
            BasicLogger.shared.log("jump to last position: \(lastPlayPosition)")
            await jumpTo(time: lastPlayPosition)
        } else {
            BasicLogger.shared.log("no time - jump to beginning")
            await jumpTo(time: 0)
        }
        _ = updateCurrentChapter()
        setupStaticNowPlayingInfo()
        await updateNowPlayingCover()
        if playDirectly {
            play()
        }
    }
    
    var coverImage: some View{
        if let playing = currentEpisode{
            
             return AnyView(CoverImageView(episode: playing))
             
             
        }else{
            return AnyView(EmptyView())
        }
    }
    
    var progress: Double {
        get {
            guard let duration = currentEpisode?.duration, duration > 0 else { return 0.0 }
            return playPosition / duration
        }
        set {
            Task {
                guard let duration = currentEpisode?.duration, duration > 0 else { return }
                let seconds = newValue * duration
                let newTime = CMTime(seconds: seconds, preferredTimescale: 1)
                await jumpTo(time: newTime.seconds)
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
        Task {
            await engine.setInterruptionHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .began, .pause:
                        self.handleInterruptionBegan()
                    case .ended, .resume:
                        self.resumeAfterInterruption()
                    case .finished:
                        self.handlePlaybackFinished()
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
     //   startNowPlayingInfoUpdater()
        initRemoteCommandCenter()
        Task {
            
            await engine.setRate(playbackRate)
            isPlaying = true
            
            // New session tracking integration: start or update the play session
            if let currentEpisode = currentEpisode {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                await playSessionTracker.startOrUpdateSession(episode: currentEpisode, position: playPosition, rate: playbackRate, appVersion: appVersion)
            }
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
            
            // New session tracking integration: pause the play session
            if let currentEpisode = currentEpisode {
                await playSessionTracker.pauseSession(at: playPosition)
            }
        }
        updateLastPlayed()
       // savePlayPosition()
        stopPlaybackUpdates()
        stopNowPlayingInfoUpdater()
        updateNowPlayingInfo()
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

        await engine.seek(to: cmTime)

        playPosition = safeTime
        updateNowPlayingInfo()
        _ = updateCurrentChapter()
        updateChapterProgress()
        savePlayPosition()
    }
    
    func setRate(_ rate: Float){
        Task { await engine.setRate(rate) }
        playbackRate = rate
        updateNowPlayingInfo()
        if rate > 0 {
            startPlaybackUpdates()
        }

    }


    
    private func stopPlaybackUpdates() {
        playbackTask?.cancel()
        playbackTask = nil
    }
    
    

    private func startPlaybackUpdates() {
        stopPlaybackUpdates()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await engine.playbackStream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .position(let time):
                    self.playPosition = time
                    self.updateEpisodeProgress(to: time)
                case .ended:
                    BasicLogger.shared.log("Playback finished automatically")
                    self.handlePlaybackFinished()
                }
            }
        }
    }
    
    
    
    func updateLastPlayed()  {
        if let currentEpisodeURL {
            let episodeActor = self.episodeActor
            let currentPlayPosition = playPosition
            Task {
                await episodeActor?.setLastPlayed(episodeURL: currentEpisodeURL)
                await episodeActor?.setPlayPosition(episodeURL: currentEpisodeURL, position: currentPlayPosition)
            }
        }
    }



    private var progressUpdateCounter = 0
    private let progressSaveInterval = 40  // 0.5 seconds * 20 = 10 seconds
    
    private func updateEpisodeProgress(to time: Double) {
        guard isPlaying == true else { return }
        
        if let chapters, chapters.isEmpty == false {
            let chapterChange = updateCurrentChapter()
            updateChapterProgress()
            if chapterChange {
                Task {
                    await skipIfNeeded(chapterChange: chapterChange)
                }
            }
        }

        progressUpdateCounter += 1
        if progressUpdateCounter >= progressSaveInterval {
            if currentEpisode?.chapters?.isEmpty == false {
                updateChapters()
            }
            updateNowPlayingInfo()
            savePlayPosition()
            progressUpdateCounter = 0
        }
    }
    
    // Helper to cascade skip consecutive skipped chapters and handle last skipped chapter
    private func skipIfNeeded(chapterChange: Bool) async {
        guard chapterChange else { return }
        await skipOverChapters()
    }

    private func skipOverChapters() async {
        guard let currentChapter else { return }

        if currentChapter.shouldPlay { return }

        if let id = currentChapter.uuid {
            let chapterActor = self.chapterActor
            Task.detached(priority: .background) {
                await chapterActor?.markChapterAsSkipped(id)
            }
        }
        guard let nextChapter = chapters?.first(where: { ($0.start ?? 0) > playPosition })
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
        guard let currentEpisodeURL else { return }
        let episodeActor = self.episodeActor
        let currentPlayPosition = playPosition
        Task.detached(priority: .background) {
            await episodeActor?.setPlayPosition(episodeURL: currentEpisodeURL, position: currentPlayPosition)
        }
    }
    
    
    
    func skipTo(chapter: Marker) async{
        // print("skip to chapter \(chapter.title)")
            if let newEpisode = chapter.episode, let start = chapter.start{
                await playEpisode(newEpisode.url, playDirectly: true, startingAt: start)
            }
        
    }
    
    func skipToNextChapter() async{
        let nextChapter = chapters?.first(where: { ($0.start ?? 0) >= playPosition })

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

            Task{
                let continuePlaying = await settingsActor?.getContiniousPlay() ?? true
                let sleepTimerContinuePlaying = !stopAfterEpisode
                if sleepTimerContinuePlaying == true,
                   continuePlaying == true,
                   let nextEpisodeURL = try? await playlistActor?.nextEpisodeURL() {
                    BasicLogger.shared.log("Playing next episode")
                    await playEpisode(nextEpisodeURL, playDirectly: true)
                }else{
                    if let currentEpisodeURL {
                        await unloadEpisode(episodeURL: currentEpisodeURL)
                    }
                }
            }


        

    }
    

    
    // Always call this function to update nowPlayingInfo—when artwork or position/rate changes.
    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let episode = currentEpisode else { return }
    
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist:  episode.podcast?.title ?? episode.podcast?.author ?? episode.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
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
    
    func createBookmark() {
        Task {
            if let currentEpisodeURL {
                await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
                    .createBookmark(for: currentEpisodeURL, at: playPosition)
            }
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
            
            if lastArtworkURL == imageURL {
                return
            }
            lastArtworkURL = imageURL
            
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
