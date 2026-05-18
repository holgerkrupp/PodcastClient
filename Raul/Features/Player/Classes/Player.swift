import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import BasicLogger

enum PlaybackMediaSelection: String, Sendable {
    case primary
    case alternateVideo
}

private struct CachedPlaybackProgress: Codable {
    var playPosition: Double
    var maxPlayPosition: Double
    var chapterProgresses: [String: Double]
    var updatedAt: Date
}

@MainActor
private enum PlaybackProgressDefaultsStore {
    private static let defaultsKey = "Player.cachedPlaybackProgress.v1"
    private static let defaults = UserDefaults.standard

    static func cachedProgress(for episodeURL: URL) -> CachedPlaybackProgress? {
        allCachedProgress()[episodeURL.absoluteString]
    }

    static func allCachedProgress() -> [String: CachedPlaybackProgress] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedPlaybackProgress].self, from: data)) ?? [:]
    }

    static func update(
        episodeURL: URL,
        playPosition: Double,
        maxPlayPosition: Double,
        chapterID: UUID?,
        chapterProgress: Double?
    ) {
        var allProgress = allCachedProgress()
        let key = episodeURL.absoluteString
        var cached = allProgress[key] ?? CachedPlaybackProgress(
            playPosition: 0,
            maxPlayPosition: 0,
            chapterProgresses: [:],
            updatedAt: Date()
        )

        cached.playPosition = playPosition
        cached.maxPlayPosition = max(cached.maxPlayPosition, maxPlayPosition, playPosition)
        if let chapterID, let chapterProgress {
            cached.chapterProgresses[chapterID.uuidString] = chapterProgress
        }
        cached.updatedAt = Date()
        allProgress[key] = cached
        save(allProgress)
    }

    static func removeProgress(for episodeURL: URL) {
        var allProgress = allCachedProgress()
        allProgress.removeValue(forKey: episodeURL.absoluteString)
        save(allProgress)
    }

    private static func save(_ allProgress: [String: CachedPlaybackProgress]) {
        guard allProgress.isEmpty == false else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(allProgress) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

@Observable
@MainActor
class Player {
    private enum PlaybackSource {
        case local
        case remote
        case liveRemote
    }
    private static let playSessionRecoveryLastRunKey = "PlaySessionRecoveryLastRun"
    private static let playSessionRecoveryMinimumInterval: TimeInterval = 60 * 60 * 12
    private static let playSessionRecoveryStartupDelayNanoseconds: UInt64 = 15_000_000_000
    
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
    private var playbackStatusObservation: NSKeyValueObservation?
    private var playbackRateObservation: NSKeyValueObservation?
    private var downloadCompletionObserver: NSObjectProtocol?
    private var currentPlaybackSource: PlaybackSource?
    private var currentPlaybackUsesAlternateMedia = false
    private var hasStartedRecovery = false

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
    var skipForwardStep: SkipSteps = .thirty
    var skipBackStep: SkipSteps = .fifteen
    
    
    var currentEpisode: Episode?
    var currentEpisodeURL: URL?
    var mediaSelection: PlaybackMediaSelection = .primary

    var videoPlayer: AVPlayer {
        engine.avPlayer
    }

    var currentPlaybackIsVideo: Bool {
        guard let currentEpisode else { return false }
        if mediaSelection == .alternateVideo, currentEpisode.alternateVideo != nil {
            return true
        }
        return currentEpisode.isVideo
    }

    var currentPlaybackURL: URL? {
        guard let currentEpisode else { return nil }
        if mediaSelection == .alternateVideo, let alternateVideo = currentEpisode.alternateVideo {
            return alternateVideo.url
        }
        return currentEpisode.localFile ?? currentEpisode.url
    }

    var canSwitchCurrentEpisodeMedia: Bool {
        currentEpisode?.hasAlternateVideo == true
    }
    
    var isCurrentEpisodeDownloaded: Bool {
        return currentEpisode?.metaData?.calculatedIsAvailableLocally ?? false
    }
    
    
    var isPlaying: Bool = false
    var isPlayerSheetPresented: Bool = false
    
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
            // Remove legacy UUID-based last-played storage from older builds.
            await migrateLastPlayedFromUserDefaultsIfNeeded()
            await reconcileCachedPlaybackProgress()
            await restoreLastPlayedFromPlaylist()
        }
        loadPlayBackSpeed()
        listenToEvent()
        observeEnginePlaybackState()
        pause()
        addChangeSettingsObserver()
        addDownloadObserver()
        Task{
            allowScrubbing = await settingsActor?.getAppSliderEnable()
        }
        
    }

    func startRecoveryIfNeeded() {
        guard !hasStartedRecovery else { return }
        hasStartedRecovery = true

        guard shouldRunPlaySessionRecoveryNow() else { return }

        Task.detached(priority: .background) { [playSessionTracker] in
            try? await Task.sleep(nanoseconds: Self.playSessionRecoveryStartupDelayNanoseconds)
            await playSessionTracker.startRecovery()
            await MainActor.run {
                UserDefaults.standard.setValue(Date().timeIntervalSince1970, forKey: Self.playSessionRecoveryLastRunKey)
            }
        }
    }

    private func shouldRunPlaySessionRecoveryNow() -> Bool {
        let lastRunTimestamp = UserDefaults.standard.double(forKey: Self.playSessionRecoveryLastRunKey)
        guard lastRunTimestamp > 0 else { return true }
        let elapsed = Date().timeIntervalSince(Date(timeIntervalSince1970: lastRunTimestamp))
        return elapsed >= Self.playSessionRecoveryMinimumInterval
    }
    
    /// Clears the legacy UUID-based last-played key from older builds.
    private func migrateLastPlayedFromUserDefaultsIfNeeded() async {
        let key = "lastPlayedEpisodeID"
        if UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    func restoreLastPlayedFromPlaylist() async {
        let episodeURLs = (try? await playlistActor?.orderedEpisodeURLs()) ?? []

        if let lastPlayedURL = await episodeActor?.getLastPlayedEpisodeURL(),
           episodeURLs.contains(lastPlayedURL) {
            await playEpisode(lastPlayedURL, playDirectly: false)
            return
        }

        if let firstURL = episodeURLs.first {
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
                self?.loadSkipDurations()
                self?.allowScrubbing = await self?.settingsActor?.getAppSliderEnable()
                if let lockscreenEnable = await self?.settingsActor?.getLockScreenSliderEnable() {
                    RemoteCommandCenter.shared.updateLockScreenScrubbableState(lockscreenEnable)
                }
                RemoteCommandCenter.shared.updateSkipIntervals()
                
            }
        })
    }

    private func addDownloadObserver() {
        downloadCompletionObserver = NotificationCenter.default.addObserver(
            forName: .episodeDownloadFinished,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let episodeURL = notification.userInfo?[EpisodeDownloadNotificationKey.episodeURL] as? URL
            Task { @MainActor [weak self] in
                guard let self,
                      let episodeURL else {
                    return
                }
                await self.handleDownloadFinished(for: episodeURL)
            }
        }
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

    func loadSkipDurations() {
        Task {
            let podcastFeed = currentEpisode?.podcast?.feed
            skipForwardStep = await settingsActor?.getSkipForwardStep(for: podcastFeed) ?? .thirty
            skipBackStep = await settingsActor?.getSkipBackStep(for: podcastFeed) ?? .fifteen
            RemoteCommandCenter.shared.updateSkipIntervals()
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

    private func updateChapters() {
        guard let currentEpisode else {
            chapters = []
            currentChapter = nil
            nextChapter = nil
            return
        }

        chapters = currentEpisode.preferredChapters
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
    }
    
    private func saveChapterProgress(chapter: Marker, progress: Double){
        cacheCurrentPlaybackState(chapterID: chapter.uuid, chapterProgress: progress)
    }

    private func sanitizedPosition(_ value: Double?) -> Double {
        guard let value,
              value.isFinite else {
            return 0
        }

        return max(0, value)
    }

    private func resolvedResumePosition(
        explicitTime: Double?,
        episodeDuration: Double?,
        persistedPosition: Double?,
        persistedMaxPosition: Double?,
        metadataPosition: Double?,
        metadataMaxPosition: Double?,
        inMemoryPosition: Double?
    ) -> Double {
        if let explicitTime {
            BasicLogger.shared.log("Time provided when calling the playEpisode function: \(explicitTime)")
            return sanitizedPosition(explicitTime)
        }

        let persistedCandidate = sanitizedPosition(persistedPosition)
        let metadataCandidate = sanitizedPosition(metadataPosition)
        let inMemoryCandidate = sanitizedPosition(inMemoryPosition)
        var candidate = max(persistedCandidate, metadataCandidate, inMemoryCandidate)

        if candidate <= 0 {
            let maxFallback = max(
                sanitizedPosition(persistedMaxPosition),
                sanitizedPosition(metadataMaxPosition)
            )

            if maxFallback > 0 {
                BasicLogger.shared.log("using max position as resume fallback: \(maxFallback)")
                candidate = maxFallback
            }
        }

        let duration = sanitizedPosition(episodeDuration)
        if duration > 0,
           candidate >= (duration * progressThreshold) {
            BasicLogger.shared.log("episode considered finished - jump to beginning")
            return 0
        }

        if candidate > 0 {
            BasicLogger.shared.log("jump to last position: \(candidate)")
        } else {
            BasicLogger.shared.log("no persisted position - jump to beginning")
        }
        return candidate
    }

    private func cachedPlaybackProgress(for episodeURL: URL) -> CachedPlaybackProgress? {
        PlaybackProgressDefaultsStore.cachedProgress(for: episodeURL)
    }

    private func cacheCurrentPlaybackState(
        chapterID: UUID? = nil,
        chapterProgress explicitChapterProgress: Double? = nil
    ) {
        guard let currentEpisodeURL else { return }
        guard currentPlaybackSource != .liveRemote else { return }

        let currentPlayPosition = sanitizedPosition(playPosition)
        let currentMaxPosition = max(
            sanitizedPosition(currentEpisode?.metaData?.maxPlayposition),
            currentPlayPosition
        )
        let resolvedChapterID = chapterID ?? currentChapter?.uuid
        let resolvedChapterProgress = explicitChapterProgress ?? chapterProgress

        currentEpisode?.metaData?.playPosition = currentPlayPosition
        currentEpisode?.metaData?.maxPlayposition = currentMaxPosition

        PlaybackProgressDefaultsStore.update(
            episodeURL: currentEpisodeURL,
            playPosition: currentPlayPosition,
            maxPlayPosition: currentMaxPosition,
            chapterID: resolvedChapterID,
            chapterProgress: resolvedChapterProgress
        )
    }

    private func reconcileCachedPlaybackProgress() async {
        let cachedProgress = PlaybackProgressDefaultsStore.allCachedProgress()
        guard cachedProgress.isEmpty == false else { return }

        for (episodeURLString, cached) in cachedProgress {
            guard let episodeURL = URL(string: episodeURLString) else { continue }
            await episodeActor?.applyCachedPlaybackProgress(
                episodeURL: episodeURL,
                playPosition: sanitizedPosition(cached.playPosition),
                maxPlayPosition: sanitizedPosition(cached.maxPlayPosition),
                chapterProgresses: cached.chapterProgresses
            )
            PlaybackProgressDefaultsStore.removeProgress(for: episodeURL)
        }
    }

    func saveCurrentPlaybackState(force: Bool = false) async {
        guard let currentEpisodeURL else { return }
        guard currentPlaybackSource != .liveRemote else { return }

        let currentPlayPosition = sanitizedPosition(playPosition)
        let currentChapterProgress = chapterProgress
        let currentChapterID = currentChapter?.uuid
        let episodeActor = self.episodeActor
        let chapterActor = self.chapterActor

        await episodeActor?.setLastPlayed(episodeURL: currentEpisodeURL)
        await episodeActor?.setPlayPosition(
            episodeURL: currentEpisodeURL,
            position: currentPlayPosition,
            force: force
        )

        currentEpisode?.metaData?.playPosition = currentPlayPosition
        if currentPlayPosition > (currentEpisode?.metaData?.maxPlayposition ?? 0.0) {
            currentEpisode?.metaData?.maxPlayposition = currentPlayPosition
        }

        if let currentChapterID, let currentChapterProgress {
            await chapterActor?.setChapterProgress(currentChapterProgress, for: currentChapterID)
        }

        PlaybackProgressDefaultsStore.removeProgress(for: currentEpisodeURL)
    }

    func captureCurrentPlaybackStateFromEngine(force: Bool = true) async {
        guard currentEpisodeURL != nil else { return }
        guard currentPlaybackSource != .liveRemote else { return }

        playPosition = sanitizedPosition(await engine.currentTime())
        if currentEpisode?.chapters?.isEmpty == false {
            _ = updateCurrentChapter()
            updateChapterProgress()
        }
        updateNowPlayingInfo()
        await saveCurrentPlaybackState(force: force)
    }

    func reloadPlaybackStateFromPersistenceIfNeeded() async {
        guard !isPlaying,
              let currentEpisodeURL,
              currentEpisode != nil,
              let snapshot = await episodeActor?.playbackStateSnapshot(for: currentEpisodeURL) else {
            return
        }

        let persistedMaxPlayPosition = sanitizedPosition(snapshot.maxPlayPosition)
        if persistedMaxPlayPosition > (currentEpisode?.metaData?.maxPlayposition ?? 0) {
            currentEpisode?.metaData?.maxPlayposition = persistedMaxPlayPosition
        }

        let restoredPosition = resolvedResumePosition(
            explicitTime: nil,
            episodeDuration: currentEpisode?.duration,
            persistedPosition: snapshot.playPosition,
            persistedMaxPosition: snapshot.maxPlayPosition,
            metadataPosition: currentEpisode?.metaData?.playPosition,
            metadataMaxPosition: currentEpisode?.metaData?.maxPlayposition,
            inMemoryPosition: self.playPosition
        )
        if restoredPosition > 0 || self.playPosition <= 0 {
            self.playPosition = restoredPosition
            currentEpisode?.metaData?.playPosition = restoredPosition
        }

        if currentEpisode?.chapters?.isEmpty == false {
            updateChapters()
            _ = updateCurrentChapter()
            updateChapterProgress()
        }

        updateNowPlayingInfo()
    }

    private func normalizedMediaSelection(_ selection: PlaybackMediaSelection, for episode: Episode) -> PlaybackMediaSelection {
        if selection == .alternateVideo, episode.alternateVideo != nil {
            return .alternateVideo
        }
        return .primary
    }

    private func playbackItem(
        for episode: Episode,
        mediaSelection selection: PlaybackMediaSelection
    ) -> (item: AVPlayerItem, source: PlaybackSource, usesAlternateMedia: Bool)? {
        if selection == .alternateVideo, let alternateVideo = episode.alternateVideo {
            return (AVPlayerItem(url: alternateVideo.url), .remote, true)
        }

        if episode.source == .sideLoaded {
            guard let localFile = episode.localFile,
                  FileManager.default.fileExists(atPath: localFile.path) else {
                return nil
            }
            return (AVPlayerItem(url: localFile), .local, false)
        }

        if episode.metaData?.calculatedIsAvailableLocally == true,
           let localFile = episode.localFile,
           FileManager.default.fileExists(atPath: localFile.path) {
            return (AVPlayerItem(url: localFile), .local, false)
        }

        guard let remoteURL = episode.url else { return nil }
        return (AVPlayerItem(url: remoteURL), .remote, false)
    }

    private func shouldRequeueEpisodeOnUnload(_ episode: Episode, episodeURL: URL) async -> Bool {
        if episode.metaData?.isArchived == true || episode.metaData?.status == .archived {
            BasicLogger.shared.log("skip requeue on unload: archived episode \(episodeURL.absoluteString)")
            return false
        }

        if episode.metaData?.isHistory == true || episode.metaData?.status == .history {
            BasicLogger.shared.log("skip requeue on unload: history episode \(episodeURL.absoluteString)")
            return false
        }

        if episode.metaData?.completionDate != nil {
            BasicLogger.shared.log("skip requeue on unload: completed episode \(episodeURL.absoluteString)")
            return false
        }

        let isCurrentlyQueued = (try? await playlistActor?.containsEpisodeURL(episodeURL)) ?? false
        if isCurrentlyQueued == false {
            BasicLogger.shared.log("skip requeue on unload: episode no longer queued \(episodeURL.absoluteString)")
        }
        return isCurrentlyQueued
    }

    private func unloadEpisode(episodeURL: URL, finishedPlayback: Bool = false) async {
        if currentEpisodeURL == episodeURL, finishedPlayback == false {
            await captureCurrentPlaybackStateFromEngine(force: true)
        } else if finishedPlayback {
            PlaybackProgressDefaultsStore.removeProgress(for: episodeURL)
        }

        let episode = (currentEpisode?.url == episodeURL) ? currentEpisode : await fetchEpisode(with: episodeURL)
        guard let episode else { return }
        let shouldRequeueUnfinishedEpisode = await shouldRequeueEpisodeOnUnload(episode, episodeURL: episodeURL)
        BasicLogger.shared.log(
            "unloadEpisode url=\(episodeURL.absoluteString) finishedPlayback=\(finishedPlayback) playProgress=\(episode.playProgress)"
        )

        stopPlaybackUpdates()
        currentEpisode = nil
        currentEpisodeURL = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        currentPlaybackSource = nil
        currentPlaybackUsesAlternateMedia = false
        mediaSelection = .primary
        lastProgressSaveDate = .distantPast
        lastArtworkURL = nil
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: nil)

        if finishedPlayback || episode.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: episodeURL)
            await episodeActor?.moveToHistory(episodeURL: episodeURL)
        } else if shouldRequeueUnfinishedEpisode {
            try? await playlistActor?.add(episodeURL: episodeURL, to: .front)
        }
    }
    
    
    
    func playEpisode(
        _ episodeURL: URL?,
        playDirectly: Bool = true,
        startingAt time: Double? = nil,
        mediaSelection requestedMediaSelection: PlaybackMediaSelection? = nil
    ) async {
        guard let episodeURL,
              let episode = await fetchEpisode(with: episodeURL) else { return }

        let previousEpisodeURL = currentEpisodeURL
        if let currentEpisodeURL, currentEpisodeURL != episodeURL {
            await unloadEpisode(episodeURL: currentEpisodeURL)
        }

        let selectedMedia = normalizedMediaSelection(
            requestedMediaSelection ?? (previousEpisodeURL == episodeURL ? mediaSelection : .primary),
            for: episode
        )

        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeURL = episodeURL
        mediaSelection = selectedMedia
        if playDirectly {
            if currentEpisode?.metaData == nil {
                let metadata = EpisodeMetaData()
                metadata.episode = currentEpisode
                currentEpisode?.metaData = metadata
            }
            currentEpisode?.metaData?.lastPlayed = Date()
            await episodeActor?.setLastPlayed(episodeURL: episodeURL)
        }
        loadSkipDurations()
        lastProgressSaveDate = Date()
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)

        updateChapters()

        guard let playback = playbackItem(for: episode, mediaSelection: selectedMedia) else { return }
        currentPlaybackSource = playback.source
        currentPlaybackUsesAlternateMedia = playback.usesAlternateMedia
        let item = playback.item

        let duration = item.duration.seconds
        if duration.isNormal && currentEpisode?.duration != duration {
            currentEpisode?.duration = duration
        }

        let snapshot = await episodeActor?.playbackStateSnapshot(for: episodeURL)
        let cachedProgress = cachedPlaybackProgress(for: episodeURL)
        if currentEpisode?.metaData == nil {
            let metadata = EpisodeMetaData()
            metadata.episode = currentEpisode
            currentEpisode?.metaData = metadata
        }
        if let cachedProgress {
            let cachedPosition = sanitizedPosition(cachedProgress.playPosition)
            currentEpisode?.metaData?.playPosition = cachedPosition
            currentEpisode?.metaData?.maxPlayposition = max(
                sanitizedPosition(currentEpisode?.metaData?.maxPlayposition),
                sanitizedPosition(snapshot?.maxPlayPosition),
                sanitizedPosition(cachedProgress.maxPlayPosition),
                cachedPosition
            )
        } else if let persistedPosition = snapshot?.playPosition {
            let sanitizedPersistedPosition = sanitizedPosition(persistedPosition)
            if sanitizedPersistedPosition > 0 || sanitizedPosition(currentEpisode?.metaData?.playPosition) <= 0 {
                currentEpisode?.metaData?.playPosition = sanitizedPersistedPosition
            }
        }
        if let persistedMaxPosition = snapshot?.maxPlayPosition {
            let sanitizedPersistedMaxPosition = sanitizedPosition(persistedMaxPosition)
            if sanitizedPersistedMaxPosition > (currentEpisode?.metaData?.maxPlayposition ?? 0) {
                currentEpisode?.metaData?.maxPlayposition = sanitizedPersistedMaxPosition
            }
        }

        await engine.replaceCurrentItem(with: item)
        try? await playlistActor?.add(episodeURL: episodeURL, to: .front)
        
        
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: episodeURL)

        BasicLogger.shared.log(
            "playing episode \(episode.title) - playPosition \(String(describing: currentEpisode?.metaData?.playPosition)) maxPosition \(String(describing: currentEpisode?.metaData?.maxPlayposition)) snapshotPosition \(String(describing: snapshot?.playPosition))"
        )
        let inMemoryResumePosition = (previousEpisodeURL == episodeURL) ? playPosition : nil
        let targetStartTime = resolvedResumePosition(
            explicitTime: time,
            episodeDuration: currentEpisode?.duration,
            persistedPosition: cachedProgress?.playPosition ?? snapshot?.playPosition,
            persistedMaxPosition: max(
                sanitizedPosition(cachedProgress?.maxPlayPosition),
                sanitizedPosition(snapshot?.maxPlayPosition)
            ),
            metadataPosition: currentEpisode?.metaData?.playPosition,
            metadataMaxPosition: currentEpisode?.metaData?.maxPlayposition,
            inMemoryPosition: inMemoryResumePosition
        )

        await jumpTo(time: targetStartTime)
        _ = updateCurrentChapter()
        setupStaticNowPlayingInfo()
        await updateNowPlayingCover()
        if playDirectly {
            play()
        }
    }

    func switchCurrentEpisodeMedia(to requestedSelection: PlaybackMediaSelection? = nil) async {
        guard let episode = currentEpisode,
              episode.hasAlternateVideo else { return }

        let nextSelection = normalizedMediaSelection(
            requestedSelection ?? (mediaSelection == .alternateVideo ? .primary : .alternateVideo),
            for: episode
        )
        guard nextSelection != mediaSelection else { return }

        await captureCurrentPlaybackStateFromEngine(force: true)
        guard let playback = playbackItem(for: episode, mediaSelection: nextSelection) else { return }

        let preservedPosition = max(0, playPosition)
        let wasPlaying = isPlaying
        let preservedRate = playbackRate
        let hadPlaybackUpdates = playbackTask != nil

        await engine.replaceCurrentItem(with: playback.item)
        mediaSelection = nextSelection
        currentPlaybackSource = playback.source
        currentPlaybackUsesAlternateMedia = playback.usesAlternateMedia
        await engine.seek(to: CMTime(seconds: preservedPosition, preferredTimescale: 600))

        playPosition = preservedPosition
        updateNowPlayingInfo()
        _ = updateCurrentChapter()
        updateChapterProgress()

        if hadPlaybackUpdates {
            startPlaybackUpdates()
        }

        if wasPlaying {
            await engine.setRate(preservedRate)
        }
    }

    func playLiveStream(
        url: URL,
        title: String,
        podcastTitle: String,
        artworkURL: URL?,
        link: URL?
    ) async {
        if let currentEpisodeURL, currentPlaybackSource != .liveRemote {
            await unloadEpisode(episodeURL: currentEpisodeURL)
        } else {
            stopPlaybackUpdates()
        }

        let liveEpisode = Episode(
            guid: url.absoluteString,
            title: title,
            publishDate: nil,
            url: url,
            podcast: nil,
            duration: nil,
            author: podcastTitle
        )
        liveEpisode.imageURL = artworkURL
        liveEpisode.link = link

        currentEpisode = liveEpisode
        currentEpisodeURL = url
        currentPlaybackSource = .liveRemote
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        playPosition = 0
        lastProgressSaveDate = .distantPast

        await engine.replaceCurrentItem(with: AVPlayerItem(url: url))
        setupStaticNowPlayingInfo()
        await updateNowPlayingCover()
        play()
        isPlayerSheetPresented = true
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

    private func observeEnginePlaybackState() {
        playbackStatusObservation = videoPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.syncPlaybackStateFromObservedPlayer(player)
            }
        }

        playbackRateObservation = videoPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.syncPlaybackStateFromObservedPlayer(player)
            }
        }
    }

    private func syncPlaybackStateFromObservedPlayer(_ observedPlayer: AVPlayer) {
        if (observedPlayer.rate > 0 || observedPlayer.timeControlStatus == .playing), isPlaying == false {
            handleExternalPlaybackStarted()
        } else if observedPlayer.timeControlStatus == .paused, observedPlayer.rate == 0, isPlaying == true {
            handleExternalPlaybackPaused()
        }
    }

    private func handleExternalPlaybackStarted() {
        loadSkipDurations()
        cacheCurrentPlaybackState()
        startPlaybackUpdates()
        initRemoteCommandCenter()
        isPlaying = true
        updateNowPlayingInfo()

        let desiredRate = playbackRate
        let position = playPosition
        let currentEpisodeURL = currentEpisode?.url
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        Task {
            if await engine.getRate() != desiredRate {
                await engine.setRate(desiredRate)
            }

            if let currentEpisodeURL, currentPlaybackSource != .liveRemote {
                await playSessionTracker.startOrUpdateSession(
                    episodeURL: currentEpisodeURL,
                    position: position,
                    rate: desiredRate,
                    appVersion: appVersion
                )
                await episodeActor?.addplaybackStartTimes(episodeURL: currentEpisodeURL, date: Date())
            }
        }
    }

    private func handleExternalPlaybackPaused() {
        isPlaying = false
        stopPlaybackUpdates()
        stopNowPlayingInfoUpdater()
        Task {
            await captureCurrentPlaybackStateFromEngine(force: true)

            if currentEpisode != nil, currentPlaybackSource != .liveRemote {
                await playSessionTracker.pauseSession(at: playPosition)
            }
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
                        self.handlePlaybackEndedEvent(source: "interruption_finished_event")
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
        loadSkipDurations()
        cacheCurrentPlaybackState()
        startPlaybackUpdates()
     //   startNowPlayingInfoUpdater()
        initRemoteCommandCenter()
        isPlaying = true
        updateNowPlayingInfo()

        let rate = playbackRate
        let position = playPosition
        let currentEpisodeURL = currentEpisode?.url
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        Task {
            await switchCurrentEpisodeToDownloadedCopyIfNeeded()
            await ensureDownloadForCurrentEpisodeIfNeeded()
            await engine.setRate(rate)
            
            // New session tracking integration: start or update the play session
            if let currentEpisodeURL, currentPlaybackSource != .liveRemote {
                await playSessionTracker.startOrUpdateSession(episodeURL: currentEpisodeURL, position: position, rate: rate, appVersion: appVersion)
            }
        }

       
        if let episodeURL =  currentEpisode?.url, currentPlaybackSource != .liveRemote {
            Task {
                await self.episodeActor?.addplaybackStartTimes(episodeURL: episodeURL, date: Date())
            }
        }

    }
    
    

    func pause() {
        isPlaying = false
        stopPlaybackUpdates()
        stopNowPlayingInfoUpdater()
        Task {
            await engine.pause()
            await captureCurrentPlaybackStateFromEngine(force: true)

            // New session tracking integration: pause the play session
            if currentEpisode != nil, currentPlaybackSource != .liveRemote {
                await playSessionTracker.pauseSession(at: playPosition)
            }
        }
    }
    
    func skipback(){
        jumpPlaypostion(by: -skipBackStep.seconds)
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: skipForwardStep.seconds)
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
        cacheCurrentPlaybackState()
    }
    
    func setRate(_ rate: Float){
        Task { await engine.setRate(rate) }
        isPlaying = rate > 0
        playbackRate = rate
        updateNowPlayingInfo()
        if isPlaying {
            startPlaybackUpdates()
        } else {
            stopPlaybackUpdates()
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
                    let sanitizedTime = self.sanitizedPosition(time)
                    self.playPosition = sanitizedTime
                    self.updateEpisodeProgress(to: sanitizedTime)
                case .ended:
                    self.handlePlaybackEndedEvent(source: "player_engine_stream")
                }
            }
        }
    }

    private func handlePlaybackEndedEvent(source: String) {
        let resolvedDuration = sanitizedPosition(currentEpisode?.duration)
        guard resolvedDuration > 0 else {
            BasicLogger.shared.log("Ignoring ended event from \(source): episode duration unavailable")
            return
        }

        let finishThreshold = max(resolvedDuration * progressThreshold, resolvedDuration - 2.0)
        guard playPosition >= finishThreshold else {
            BasicLogger.shared.log(
                "Ignoring premature ended event from \(source): position=\(playPosition), duration=\(resolvedDuration)"
            )
            return
        }

        BasicLogger.shared.log("Playback finished automatically (\(source))")
        handlePlaybackFinished()
    }
    
    
    
    private var lastProgressSaveDate = Date.distantPast
    private var nowPlayingUpdateCounter = 0
    private let progressSaveInterval: TimeInterval = 10
    private let nowPlayingUpdateInterval = 1 // 1 second * 1 = 1 second
    
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

        nowPlayingUpdateCounter += 1
        if nowPlayingUpdateCounter >= nowPlayingUpdateInterval {
            updateNowPlayingInfo()
            nowPlayingUpdateCounter = 0
        }

        let now = Date()
        if now.timeIntervalSince(lastProgressSaveDate) >= progressSaveInterval {
            if currentEpisode?.chapters?.isEmpty == false {
                updateChapters()
            }
            cacheCurrentPlaybackState()
            lastProgressSaveDate = now
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
    
    
    func skipTo(chapter: Marker) async{
        guard let start = chapter.start else { return }

        if chapter.episode?.url == currentEpisodeURL {
            await jumpTo(time: start)
            return
        }

        if let newEpisode = chapter.episode {
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
        guard let currentChapter else {
            return
        }
        if let start = currentChapter.start{
             await jumpTo(time: start)
        }
    }


    private func handlePlaybackFinished() {
        // print("Playback finished. - handlePlaybackFinished")
        stopPlaybackUpdates()
        let finishedEpisodeURL = currentEpisodeURL
        let finalPlaybackPosition = max(playPosition, currentEpisode?.duration ?? 0.0)

        Task {
            let continuePlaying = await settingsActor?.getContiniousPlay() ?? true
            let sleepTimerContinuePlaying = !stopAfterEpisode
            let nextEpisodeURL: URL?
            if sleepTimerContinuePlaying == true && continuePlaying == true {
                nextEpisodeURL = try? await playlistActor?.nextEpisodeURL()
            } else {
                nextEpisodeURL = nil
            }

            if let finishedEpisodeURL {
                await episodeActor?.setLastPlayed(episodeURL: finishedEpisodeURL)
                await episodeActor?.setPlayPosition(
                    episodeURL: finishedEpisodeURL,
                    position: finalPlaybackPosition,
                    force: true
                )
                PlaybackProgressDefaultsStore.removeProgress(for: finishedEpisodeURL)
                await unloadEpisode(episodeURL: finishedEpisodeURL, finishedPlayback: true)
            }

            if let nextEpisodeURL {
                BasicLogger.shared.log("Playing next episode")
                await playEpisode(nextEpisodeURL, playDirectly: true)
            }
        }


        

    }

    private func ensureDownloadForCurrentEpisodeIfNeeded() async {
        guard currentPlaybackSource == .remote,
              currentPlaybackUsesAlternateMedia == false,
              let episode = currentEpisode,
              episode.metaData?.calculatedIsAvailableLocally != true,
              let remoteURL = episode.url else {
            return
        }

        _ = await DownloadManager.shared.download(from: remoteURL, saveTo: episode.localFile)
    }

    private func handleDownloadFinished(for episodeURL: URL) async {
        guard currentEpisodeURL == episodeURL else { return }
        await switchCurrentEpisodeToDownloadedCopyIfNeeded()
    }

    private func switchCurrentEpisodeToDownloadedCopyIfNeeded() async {
        guard currentPlaybackSource == .remote,
              currentPlaybackUsesAlternateMedia == false,
              let episode = currentEpisode,
              let localFile = episode.localFile,
              FileManager.default.fileExists(atPath: localFile.path) else {
            return
        }

        let replacementItem = AVPlayerItem(url: localFile)
        let replacementDuration = replacementItem.duration.seconds
        if replacementDuration.isNormal && currentEpisode?.duration != replacementDuration {
            currentEpisode?.duration = replacementDuration
        }

        let preservedPosition = max(0, playPosition)
        let wasPlaying = isPlaying
        let preservedRate = playbackRate
        let hadPlaybackUpdates = playbackTask != nil

        await engine.replaceCurrentItem(with: replacementItem)
        currentPlaybackSource = .local
        await engine.seek(to: CMTime(seconds: preservedPosition, preferredTimescale: 600))

        playPosition = preservedPosition
        updateNowPlayingInfo()
        _ = updateCurrentChapter()
        updateChapterProgress()

        if hadPlaybackUpdates {
            startPlaybackUpdates()
        }

        if wasPlaying {
            await engine.setRate(preservedRate)
        }
    }
    

    
    // Always call this function to update nowPlayingInfo—when artwork or position/rate changes.
    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let episode = currentEpisode else { return }
        let effectivePlaybackRate: Float = isPlaying ? playbackRate : 0.0
    
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist:  episode.displayPodcastTitle ?? episode.podcast?.author ?? episode.author ?? "",
            MPMediaItemPropertyPlaybackDuration: episode.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: effectivePlaybackRate,
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
            let targetSize = CGSize(width: 600, height: 600)
            
            if let chapterImageData = chapterImageData,
               let image = ImageLoaderAndCache.makeUIImage(from: chapterImageData, maxPixelSize: max(targetSize.width, targetSize.height)) {
                // print("using chapter image data")

                nowPlayingInfoActor.setArtwork(image)
                
            }else if let originalImage = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                // print("using URL image Data \(imageURL.absoluteString)")
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
