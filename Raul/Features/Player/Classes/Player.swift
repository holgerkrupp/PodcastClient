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

    private enum PlaybackPowerMode {
        case foreground
        case background

        var progressUpdateInterval: TimeInterval {
            switch self {
            case .foreground: return 1
            case .background: return 8
            }
        }

        var progressSaveInterval: TimeInterval {
            switch self {
            case .foreground: return 20
            case .background: return 45
            }
        }

        var keepsContinuousUIProgress: Bool {
            self == .foreground
        }
    }

    private struct EpisodeUnloadSnapshot {
        let episodeURL: URL
        let playPosition: Double
        let maxPlayPosition: Double
        let chapterID: UUID?
        let chapterProgress: Double?
        let playProgress: Double
        let isArchived: Bool
        let isHistory: Bool
        let isCompleted: Bool
        let savedAt: Date
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
    private var settingsChangeObserver: NSObjectProtocol?
    private var downloadCompletionObserver: NSObjectProtocol?
    private var currentPlaybackSource: PlaybackSource?
    private var currentPlaybackUsesAlternateMedia = false
    private var hasStartedRecovery = false
    private var finishingEpisodeURL: URL?
    private var isSkippingChapters = false
    private let chapterBoundaryTolerance: TimeInterval = 0.35
    private var playbackPowerMode: PlaybackPowerMode = .foreground
    private var reduceSilenceGapsEnabled = false
    private var silenceGapReductionLevel: SilenceGapReductionLevel = .low
    private var voiceEnhancementEnabled = false
    private var silenceGapReductionActive = false
    private var silenceGapReductionStartedAt: Date?
    private var pendingSilenceGapTimeSavedSeconds: TimeInterval = 0
#if !os(watchOS)
    private var currentAudioPlaybackProcessor: AudioPlaybackProcessor?
#endif

    var playbackRate: Float = 1.0 {
        didSet {
            guard playbackRate != oldValue else { return }
            accumulateSilenceGapTimeSaved(normalRate: oldValue)
            let rate = playbackRate
            Task { [weak self] in
                await self?.applyPlaybackRate(rate, persist: true)
            }
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
    var skipForwardBehavior: SkipButtonBehavior = .seconds
    var skipBackBehavior: SkipButtonBehavior = .seconds
    
    
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

    private var hasCurrentEpisodeChapters: Bool {
        currentEpisode?.preferredChapters.isEmpty == false
    }

    var remoteSkipForwardUsesChapter: Bool {
        skipForwardBehavior == .chapter && hasCurrentEpisodeChapters
    }

    var remoteSkipBackUsesChapter: Bool {
        skipBackBehavior == .chapter && hasCurrentEpisodeChapters
    }

    var canSwitchCurrentEpisodeMedia: Bool {
        currentEpisode?.hasAlternateVideo == true
    }
    
    var isCurrentEpisodeDownloaded: Bool {
        return currentEpisode?.metaData?.calculatedIsAvailableLocally ?? false
    }
    
    
    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            Task {
                await StoreSplitWorkCoordinator.shared.notePlaybackActivityChanged(
                    isPlaying: isPlaying
                )
            }
        }
    }
    var isPlayerSheetPresented: Bool = false
    
    var chapterProgress: Double?
    var currentChapter: Marker?
    var nextChapter: Marker?
    var chapters: [Marker]?
    
    var allowScrubbing:Bool?

    
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var lastArtworkIdentifier: String?

    
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

        guard StoreDevelopmentConfiguration.newStoreReadsEnabled == false else { return }
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

    private func activePlaybackPlaylistActor() -> PlaylistModelActor? {
        try? PlaylistModelActor(activePlaybackPlaylistIn: ModelContainerManager.shared.container)
    }

    private func moveEpisodeToFrontOfActivePlaybackPlaylist(_ episodeURL: URL) async {
        guard let activePlaylistActor = activePlaybackPlaylistActor() else { return }
        try? await activePlaylistActor.add(episodeURL: episodeURL, to: .front, startDownload: false)
    }
    
    func restoreLastPlayedFromPlaylist() async {
        let activePlaylistActor = activePlaybackPlaylistActor()
        let episodeURLs = (try? await activePlaylistActor?.orderedEpisodeURLs()) ?? []

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

        let interval: TimeInterval
        let repeats: Bool
        if playbackPowerMode.keepsContinuousUIProgress {
            interval = 1
            repeats = true
        } else {
            interval = max(endDate?.timeIntervalSinceNow ?? 1, 1)
            repeats = false
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] _ in
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
        settingsChangeObserver = NotificationCenter.default.addObserver(forName: .podcastSettingsDidChange, object: nil, queue: nil, using: { [weak self] notification in
            // print("received podcast settings change notification")
            Task { @MainActor in
                self?.loadPlayBackSpeed()
                self?.loadSkipDurations()
                self?.allowScrubbing = await self?.settingsActor?.getAppSliderEnable()
                await self?.loadPlaybackAudioProcessingSettings()
                if let currentItem = self?.videoPlayer.currentItem {
                    await self?.configurePlaybackAudioProcessing(for: currentItem)
                }
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
    
    private func applyPlaybackRate(_ playbackRate: Float, persist: Bool) async {
        if isPlaying{
            let effectiveRate = silenceGapReductionActive
                ? AudioSilenceGapDetector.silenceReducedRate(for: playbackRate, level: silenceGapReductionLevel)
                : playbackRate
            await engine.setRate(effectiveRate)
            if persist {
                await settingsActor?.setPlaybackSpeed(for: currentEpisode?.podcast?.feed , to: playbackRate)
            }
        }

        if currentEpisode != nil {
            updateNowPlayingInfo()
        } else {
            nowPlayingInfoActor.updateField(key: MPNowPlayingInfoPropertyPlaybackRate, value: playbackRate)
            nowPlayingInfoActor.updateField(key: MPNowPlayingInfoPropertyDefaultPlaybackRate, value: 1.0)
        }
        
        if currentEpisode != nil, currentPlaybackSource != .liveRemote {
            await playSessionTracker.handlePlaybackRateChange(
                to: playbackRate,
                at: playPosition
            )
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
            skipForwardBehavior = await settingsActor?.getSkipForwardBehavior(for: podcastFeed) ?? .seconds
            skipBackBehavior = await settingsActor?.getSkipBackBehavior(for: podcastFeed) ?? .seconds
            RemoteCommandCenter.shared.updateSkipIntervals()
        }
    }

    private func loadPlaybackAudioProcessingSettings() async {
        let podcastFeed = currentEpisode?.podcast?.feed
        reduceSilenceGapsEnabled = await settingsActor?.getReduceSilenceGapsEnabled(for: podcastFeed) ?? false
        silenceGapReductionLevel = await settingsActor?.getSilenceGapReductionLevel(for: podcastFeed) ?? .low
        voiceEnhancementEnabled = await settingsActor?.getVoiceEnhancementEnabled(for: podcastFeed) ?? false
    }

    private func accumulateSilenceGapTimeSaved(upTo date: Date = Date(), normalRate: Float? = nil) {
        guard let startedAt = silenceGapReductionStartedAt else { return }
        let elapsed = date.timeIntervalSince(startedAt)
        let baseRate = max(Double(normalRate ?? playbackRate), 0)
        let reducedRate = Double(
            AudioSilenceGapDetector.silenceReducedRate(
                for: Float(baseRate),
                level: silenceGapReductionLevel
            )
        )

        if elapsed.isFinite, elapsed > 0, baseRate > 0, reducedRate > baseRate {
            pendingSilenceGapTimeSavedSeconds += elapsed * ((reducedRate / baseRate) - 1)
        }
        silenceGapReductionStartedAt = date
    }

    private func startSilenceGapTimeSavedMeasurement() {
        guard silenceGapReductionStartedAt == nil else { return }
        silenceGapReductionStartedAt = Date()
    }

    private func stopSilenceGapTimeSavedMeasurement() {
        accumulateSilenceGapTimeSaved()
        silenceGapReductionStartedAt = nil
    }

    private func flushSilenceGapTimeSaved() async {
        if silenceGapReductionActive {
            accumulateSilenceGapTimeSaved()
        }

        let savedSeconds = pendingSilenceGapTimeSavedSeconds
        pendingSilenceGapTimeSavedSeconds = 0

        guard savedSeconds.isFinite, savedSeconds > 0 else { return }
        await playSessionTracker.recordSilenceGapTimeSaved(savedSeconds)
    }

    private func resetSilenceGapReduction(updateEngine: Bool = true) {
        guard silenceGapReductionActive else { return }
        stopSilenceGapTimeSavedMeasurement()
        silenceGapReductionActive = false
        guard updateEngine, isPlaying else { return }
        Task { [weak self] in
            guard let self else { return }
            await flushSilenceGapTimeSaved()
            await engine.setRate(playbackRate)
        }
    }

    private func setSilenceGapReductionActive(_ isActive: Bool) {
        guard reduceSilenceGapsEnabled,
              currentEpisode != nil,
              currentPlaybackSource != .liveRemote,
              currentPlaybackUsesAlternateMedia == false,
              currentPlaybackIsVideo == false else {
            resetSilenceGapReduction()
            return
        }

        guard silenceGapReductionActive != isActive else { return }
        if isActive {
            startSilenceGapTimeSavedMeasurement()
        } else {
            stopSilenceGapTimeSavedMeasurement()
        }
        silenceGapReductionActive = isActive
        guard isPlaying else { return }

        let rate = isActive
            ? AudioSilenceGapDetector.silenceReducedRate(for: playbackRate, level: silenceGapReductionLevel)
            : playbackRate

        Task { [weak self] in
            guard let self else { return }
            if isActive == false {
                await flushSilenceGapTimeSaved()
            }
            await engine.setRate(rate)
        }
    }

    private func configurePlaybackAudioProcessing(for item: AVPlayerItem) async {
        resetSilenceGapReduction(updateEngine: false)
        await flushSilenceGapTimeSaved()
#if !os(watchOS)
        currentAudioPlaybackProcessor = nil
        item.audioMix = nil

        guard currentPlaybackSource != .liveRemote,
              currentPlaybackUsesAlternateMedia == false,
              currentPlaybackIsVideo == false,
              reduceSilenceGapsEnabled || voiceEnhancementEnabled else {
            return
        }

        guard let audioTrack = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            return
        }

        let processor = AudioPlaybackProcessor(
            reduceSilenceGapsEnabled: reduceSilenceGapsEnabled,
            silenceGapReductionLevel: silenceGapReductionLevel,
            voiceEnhancementEnabled: voiceEnhancementEnabled
        ) { [weak self] isReducing in
            Task { @MainActor [weak self] in
                self?.setSilenceGapReductionActive(isReducing)
            }
        }

        guard let tap = processor.makeTap() else { return }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.audioTapProcessor = tap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        item.audioMix = audioMix
        currentAudioPlaybackProcessor = processor
#endif
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
            configureChapterBoundaryObserver()
            return
        }

        chapters = currentEpisode.preferredChapters
        configureChapterBoundaryObserver()
        RemoteCommandCenter.shared.updateSkipIntervals()
    }

    private func configureChapterBoundaryObserver() {
        let chapterStartTimes = (chapters ?? [])
            .compactMap(\.start)
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        Task { [weak self] in
            guard let self else { return }
            await self.engine.setBoundaryTimeObserver(at: chapterStartTimes) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleChapterBoundary()
                }
            }
        }
    }

    private func handleChapterBoundary() async {
        guard currentPlaybackSource != .liveRemote else { return }

        let currentTime = sanitizedPosition(await engine.currentTime())
        playPosition = chapterEvaluationPosition(for: currentTime, snappingToUpcomingBoundary: true)

        guard chapters?.isEmpty == false else { return }
        _ = updateCurrentChapter()
        updateChapterProgress()
        await skipOverChapters()
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

    private func chapterEvaluationPosition(
        for position: Double,
        snappingToUpcomingBoundary: Bool
    ) -> Double {
        guard snappingToUpcomingBoundary,
              let chapters,
              let upcomingStart = chapters
                .compactMap(\.start)
                .filter({ $0 > position && $0 - position <= chapterBoundaryTolerance })
                .min() else {
            return position
        }

        return upcomingStart
    }
    
    private func updateChapterProgress(){
        guard let currentChapter = currentChapter else { return }
        let chapterEnd = currentChapter.end ?? nextChapter?.start ?? currentEpisode?.duration ?? 1.0
        let chapterStart = currentChapter.start ?? 0
        let duration = max(chapterEnd - chapterStart, .leastNonzeroMagnitude)
        chapterProgress = (playPosition - chapterStart) / duration
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
            let didPersist = await episodeActor?.applyCachedPlaybackProgress(
                episodeURL: episodeURL,
                playPosition: sanitizedPosition(cached.playPosition),
                maxPlayPosition: sanitizedPosition(cached.maxPlayPosition),
                chapterProgresses: cached.chapterProgresses
            ) ?? false
            if didPersist {
                PlaybackProgressDefaultsStore.removeProgress(for: episodeURL)
            }
        }
    }

    func saveCurrentPlaybackState(force: Bool = false) async {
        guard let currentEpisodeURL else { return }
        guard currentPlaybackSource != .liveRemote else { return }

        cacheCurrentPlaybackState()
        let currentPlayPosition = sanitizedPosition(playPosition)
        let currentChapterProgress = chapterProgress
        let currentChapterID = currentChapter?.uuid
        let currentMaxPosition = max(
            sanitizedPosition(currentEpisode?.metaData?.maxPlayposition),
            currentPlayPosition
        )
        let chapterProgresses: [String: Double]
        if let currentChapterID, let currentChapterProgress {
            chapterProgresses = [currentChapterID.uuidString: currentChapterProgress]
        } else {
            chapterProgresses = [:]
        }

        let didPersist = await episodeActor?.applyCachedPlaybackProgress(
            episodeURL: currentEpisodeURL,
            playPosition: currentPlayPosition,
            maxPlayPosition: currentMaxPosition,
            chapterProgresses: chapterProgresses,
            lastPlayed: Date()
        ) ?? false

        if didPersist {
            PlaybackProgressDefaultsStore.removeProgress(for: currentEpisodeURL)
        }
    }

    func cachePlaybackStateForRecovery() {
        cacheCurrentPlaybackState()
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
        let item = AVPlayerItem(url: remoteURL)
        item.preferredForwardBufferDuration = 0
        return (item, .remote, false)
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

        let activePlaylistActor = activePlaybackPlaylistActor()
        let isCurrentlyQueued = (try? await activePlaylistActor?.containsEpisodeURL(episodeURL)) ?? false
        if isCurrentlyQueued == false {
            BasicLogger.shared.log("skip requeue on unload: episode no longer queued \(episodeURL.absoluteString)")
        }
        return isCurrentlyQueued
    }

    private func snapshotCurrentEpisodeForFastSwitch(episodeURL: URL) async -> EpisodeUnloadSnapshot? {
        guard currentEpisodeURL == episodeURL,
              currentPlaybackSource != .liveRemote else {
            return nil
        }

        playPosition = sanitizedPosition(await engine.currentTime())
        if currentEpisode?.chapters?.isEmpty == false {
            _ = updateCurrentChapter()
            updateChapterProgress()
        }

        let currentPlayPosition = sanitizedPosition(playPosition)
        let currentMaxPosition = max(
            sanitizedPosition(currentEpisode?.metaData?.maxPlayposition),
            currentPlayPosition
        )

        currentEpisode?.metaData?.playPosition = currentPlayPosition
        currentEpisode?.metaData?.maxPlayposition = currentMaxPosition

        PlaybackProgressDefaultsStore.update(
            episodeURL: episodeURL,
            playPosition: currentPlayPosition,
            maxPlayPosition: currentMaxPosition,
            chapterID: currentChapter?.uuid,
            chapterProgress: chapterProgress
        )

        let snapshot = EpisodeUnloadSnapshot(
            episodeURL: episodeURL,
            playPosition: currentPlayPosition,
            maxPlayPosition: currentMaxPosition,
            chapterID: currentChapter?.uuid,
            chapterProgress: chapterProgress,
            playProgress: currentEpisode?.playProgress ?? 0,
            isArchived: currentEpisode?.metaData?.isArchived == true || currentEpisode?.metaData?.status == .archived,
            isHistory: currentEpisode?.metaData?.isHistory == true || currentEpisode?.metaData?.status == .history,
            isCompleted: currentEpisode?.metaData?.completionDate != nil,
            savedAt: Date()
        )

        stopPlaybackUpdates()
        return snapshot
    }

    private func finishFastSwitchUnload(_ snapshot: EpisodeUnloadSnapshot) async {
        await episodeActor?.setLastPlayed(episodeURL: snapshot.episodeURL, to: snapshot.savedAt)
        await episodeActor?.setPlayPosition(
            episodeURL: snapshot.episodeURL,
            position: snapshot.playPosition,
            force: true
        )

        if let chapterID = snapshot.chapterID,
           let chapterProgress = snapshot.chapterProgress {
            await chapterActor?.setChapterProgress(chapterProgress, for: chapterID)
        }

        PlaybackProgressDefaultsStore.removeProgress(for: snapshot.episodeURL)

        let shouldRequeueUnfinishedEpisode: Bool
        if snapshot.isArchived {
            BasicLogger.shared.log("skip requeue on fast switch unload: archived episode \(snapshot.episodeURL.absoluteString)")
            shouldRequeueUnfinishedEpisode = false
        } else if snapshot.isHistory {
            BasicLogger.shared.log("skip requeue on fast switch unload: history episode \(snapshot.episodeURL.absoluteString)")
            shouldRequeueUnfinishedEpisode = false
        } else if snapshot.isCompleted {
            BasicLogger.shared.log("skip requeue on fast switch unload: completed episode \(snapshot.episodeURL.absoluteString)")
            shouldRequeueUnfinishedEpisode = false
        } else {
            let activePlaylistActor = activePlaybackPlaylistActor()
            shouldRequeueUnfinishedEpisode = (try? await activePlaylistActor?.containsEpisodeURL(snapshot.episodeURL)) ?? false
            if shouldRequeueUnfinishedEpisode == false {
                BasicLogger.shared.log("skip requeue on fast switch unload: episode no longer queued \(snapshot.episodeURL.absoluteString)")
            }
        }

        BasicLogger.shared.log(
            "fastSwitchUnload url=\(snapshot.episodeURL.absoluteString) playProgress=\(snapshot.playProgress)"
        )

        if snapshot.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: snapshot.episodeURL)
            await episodeActor?.moveToHistory(episodeURL: snapshot.episodeURL)
        } else if shouldRequeueUnfinishedEpisode {
            try? await activePlaybackPlaylistActor()?.add(episodeURL: snapshot.episodeURL, to: .front)
        }

        WatchSyncCoordinator.refreshSoon(force: true)
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
        configureChapterBoundaryObserver()
        currentPlaybackSource = nil
        currentPlaybackUsesAlternateMedia = false
        mediaSelection = .primary
        resetSilenceGapReduction(updateEngine: false)
        await flushSilenceGapTimeSaved()
#if !os(watchOS)
        currentAudioPlaybackProcessor = nil
#endif
        lastProgressSaveDate = .distantPast
        lastArtworkIdentifier = nil
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: nil)
        WatchSyncCoordinator.refreshSoon(force: true)

        if finishedPlayback || episode.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: episodeURL)
            await episodeActor?.moveToHistory(episodeURL: episodeURL)
        } else if shouldRequeueUnfinishedEpisode {
            try? await activePlaybackPlaylistActor()?.add(episodeURL: episodeURL, to: .front)
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
        let fastSwitchUnloadSnapshot: EpisodeUnloadSnapshot?
        if let currentEpisodeURL, currentEpisodeURL != episodeURL {
            fastSwitchUnloadSnapshot = await snapshotCurrentEpisodeForFastSwitch(episodeURL: currentEpisodeURL)
        } else {
            fastSwitchUnloadSnapshot = nil
        }

        let selectedMedia = normalizedMediaSelection(
            requestedMediaSelection ?? (previousEpisodeURL == episodeURL ? mediaSelection : .primary),
            for: episode
        )

        episode.metaData?.isInbox = false

        currentEpisode = episode
        currentEpisodeURL = episodeURL
        finishingEpisodeURL = nil
        mediaSelection = selectedMedia
        if playDirectly {
            if currentEpisode?.metaData == nil {
                let metadata = EpisodeMetaData()
                metadata.episode = currentEpisode
                currentEpisode?.metaData = metadata
            }
            currentEpisode?.metaData?.lastPlayed = Date()
            Task {
                await episodeActor?.setLastPlayed(episodeURL: episodeURL)
            }
        }
        loadSkipDurations()
        await loadPlaybackAudioProcessingSettings()
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

        if let fastSwitchUnloadSnapshot {
            Task {
                await finishFastSwitchUnload(fastSwitchUnloadSnapshot)
            }
        }

        await engine.pause()
        await configurePlaybackAudioProcessing(for: item)
        await engine.replaceCurrentItem(with: item)
        configureChapterBoundaryObserver()

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

        if targetStartTime > 0.5 {
            await jumpTo(time: targetStartTime)
        } else {
            playPosition = 0
            updateNowPlayingInfo()
            _ = updateCurrentChapter()
            updateChapterProgress()
            cacheCurrentPlaybackState()
        }
        _ = updateCurrentChapter()
        await skipOverChapters()
        setupStaticNowPlayingInfo()
        if playDirectly {
            await playPreparedEpisode()
        }

        Task {
            await moveEpisodeToFrontOfActivePlaybackPlaylist(episodeURL)
            await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: episodeURL)
            WatchSyncCoordinator.refreshSoon(force: true)
        }

        Task {
            await updateNowPlayingCover(for: episodeURL)
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

        mediaSelection = nextSelection
        currentPlaybackSource = playback.source
        currentPlaybackUsesAlternateMedia = playback.usesAlternateMedia
        await loadPlaybackAudioProcessingSettings()
        await configurePlaybackAudioProcessing(for: playback.item)
        await engine.replaceCurrentItem(with: playback.item)
        configureChapterBoundaryObserver()
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
        configureChapterBoundaryObserver()
        playPosition = 0
        lastProgressSaveDate = .distantPast

        await loadPlaybackAudioProcessingSettings()
        let item = AVPlayerItem(url: url)
        await configurePlaybackAudioProcessing(for: item)
        await engine.replaceCurrentItem(with: item)
        setupStaticNowPlayingInfo()
        await updateNowPlayingCover()
        play()
        isPlayerSheetPresented = true
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
        if observedPlayer.rate > 0 || observedPlayer.timeControlStatus == .playing {
            if isPlaying == false {
                transitionToPlaying(updateEngineRate: true, preparePlaybackSource: false)
            }
        }
    }

    func enterBackgroundPlaybackMode() {
        guard playbackPowerMode != .background else { return }
        playbackPowerMode = .background
        restartPlaybackUpdatesIfNeeded()
        restartSleepTimerIfNeeded()
        updateNowPlayingInfo()

        Task {
            await captureCurrentPlaybackStateFromEngine(force: true)
        }
    }

    func enterForegroundPlaybackMode() async {
        guard playbackPowerMode != .foreground else { return }
        playbackPowerMode = .foreground
        restartSleepTimerIfNeeded()

        guard currentEpisodeURL != nil else { return }
        playPosition = sanitizedPosition(await engine.currentTime())
        if currentEpisode?.chapters?.isEmpty == false {
            _ = updateCurrentChapter()
            updateChapterProgress()
        }
        updateNowPlayingInfo()
        restartPlaybackUpdatesIfNeeded()
    }

    private func restartPlaybackUpdatesIfNeeded() {
        guard playbackTask != nil else { return }
        startPlaybackUpdates()
    }

    private func restartSleepTimerIfNeeded() {
        guard endDate != nil else { return }
        startSleepTimer()
    }

    private func transitionToPlaying(updateEngineRate: Bool, preparePlaybackSource: Bool) {
        loadSkipDurations()
        cacheCurrentPlaybackState()
        startPlaybackUpdates()
        initRemoteCommandCenter()
        isPlaying = true
        updateNowPlayingInfo()
        WatchSyncCoordinator.refreshSoon(force: true)

        let desiredRate = playbackRate
        let desiredEngineRate = silenceGapReductionActive
            ? AudioSilenceGapDetector.silenceReducedRate(for: desiredRate, level: silenceGapReductionLevel)
            : desiredRate
        let position = playPosition
        let currentEpisodeURL = currentEpisode?.url
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        Task {
            if updateEngineRate, await engine.getRate() != desiredEngineRate {
                await engine.setRate(desiredEngineRate)
            }

            if preparePlaybackSource {
                await switchCurrentEpisodeToDownloadedCopyIfNeeded()
                await ensureDownloadForCurrentEpisodeIfNeeded()
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

    private func transitionToPaused(pauseEngine: Bool) {
        isPlaying = false
        resetSilenceGapReduction(updateEngine: false)
        stopPlaybackUpdates()
        updateNowPlayingInfo()
        Task {
            if pauseEngine {
                await engine.pause()
            }
            await captureCurrentPlaybackStateFromEngine(force: true)

            if currentEpisode != nil, currentPlaybackSource != .liveRemote {
                await flushSilenceGapTimeSaved()
                await playSessionTracker.pauseSession(at: playPosition)
            }
            WatchSyncCoordinator.refreshSoon(force: true)
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
        transitionToPlaying(updateEngineRate: true, preparePlaybackSource: true)
    }

    private func playPreparedEpisode() async {
        transitionToPlaying(updateEngineRate: false, preparePlaybackSource: true)
        await engine.setRate(playbackRate)
    }
    
    

    func pause() {
        transitionToPaused(pauseEngine: true)
    }
    
    func skipback(){
        jumpPlaypostion(by: -skipBackStep.seconds)
        
    }
    
    func skipforward(){
        jumpPlaypostion(by: skipForwardStep.seconds)
    }

    func remoteSkipBack() {
        if remoteSkipBackUsesChapter {
            Task {
                await skipToPreviousChapter()
            }
            return
        }

        jumpPlaypostion(by: -skipBackStep.seconds)
    }

    func remoteSkipForward() {
        if remoteSkipForwardUsesChapter {
            Task {
                await skipToNextChapter()
            }
            return
        }

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
        await skipOverChapters()
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
            let stream = await engine.playbackStream(interval: playbackPowerMode.progressUpdateInterval)
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .position(let time):
                    let sanitizedTime = self.sanitizedPosition(time)
                    self.playPosition = sanitizedTime
                    self.updateEpisodeProgress(to: sanitizedTime)
                case .ended:
                    let finalPosition = await engine.currentTime()
                    let itemDuration = await engine.currentItemDuration()
                    self.handlePlaybackEndedEvent(
                        source: "player_engine_stream",
                        observedPosition: finalPosition,
                        observedDuration: itemDuration,
                        trustedEndEvent: true
                    )
                }
            }
        }
    }

    private func handlePlaybackEndedEvent(
        source: String,
        observedPosition: Double? = nil,
        observedDuration: Double? = nil,
        trustedEndEvent: Bool = false
    ) {
        let episodeDuration = sanitizedPosition(currentEpisode?.duration)
        let itemDuration = sanitizedPosition(observedDuration)
        let observedPlaybackPosition = sanitizedPosition(observedPosition)
        let resolvedDuration: Double
        if itemDuration > 0 {
            resolvedDuration = itemDuration
        } else if episodeDuration > 0 {
            resolvedDuration = episodeDuration
        } else if trustedEndEvent {
            resolvedDuration = observedPlaybackPosition
        } else {
            resolvedDuration = 0
        }
        let resolvedPosition = max(
            playPosition,
            observedPlaybackPosition,
            trustedEndEvent ? resolvedDuration : 0
        )

        guard resolvedDuration > 0 else {
            BasicLogger.shared.log("Ignoring ended event from \(source): episode duration unavailable")
            return
        }

        let finishThreshold = max(resolvedDuration * progressThreshold, resolvedDuration - 2.0)
        guard trustedEndEvent || resolvedPosition >= finishThreshold else {
            BasicLogger.shared.log(
                "Ignoring premature ended event from \(source): position=\(resolvedPosition), duration=\(resolvedDuration)"
            )
            return
        }

        playPosition = resolvedPosition
        BasicLogger.shared.log("Playback finished automatically (\(source))")
        handlePlaybackFinished()
    }
    
    
    
    private var lastProgressSaveDate = Date.distantPast
    private var lastNowPlayingInfoUpdateDate = Date.distantPast
    
    private func updateEpisodeProgress(to time: Double) {
        guard isPlaying == true else { return }
        
        if let chapters, chapters.isEmpty == false {
            playPosition = chapterEvaluationPosition(for: time, snappingToUpcomingBoundary: true)
            let chapterChange = updateCurrentChapter()
            if playbackPowerMode.keepsContinuousUIProgress {
                updateChapterProgress()
            }
            if chapterChange {
                Task {
                    await skipIfNeeded(chapterChange: chapterChange)
                }
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastProgressSaveDate) >= playbackPowerMode.progressSaveInterval {
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
        guard isSkippingChapters == false else { return }
        guard let currentChapter else { return }

        guard await shouldSkip(chapter: currentChapter) else { return }

        isSkippingChapters = true
        defer { isSkippingChapters = false }

        await skipOverChaptersContinuing()
    }

    private func skipOverChaptersContinuing() async {
        guard let currentChapter else { return }

        guard await shouldSkip(chapter: currentChapter) else { return }

        if let id = currentChapter.uuid {
            let chapterActor = self.chapterActor
            Task.detached(priority: .background) {
                await chapterActor?.markChapterAsSkipped(id)
            }
        }
        let currentChapterStart = currentChapter.start ?? playPosition
        guard let nextChapter = chapters?.first(where: { ($0.start ?? 0) > currentChapterStart + .ulpOfOne })
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
        await skipOverChaptersContinuing()
    }

    private func shouldSkip(chapter: Marker) async -> Bool {
        if chapter.shouldPlay == false {
            return true
        }

        if let id = chapter.uuid,
           let persistedShouldPlay = await chapterActor?.shouldPlayChapter(id) {
            chapter.shouldPlay = persistedShouldPlay
        }

        return chapter.shouldPlay == false
    }

    func chapterPlaybackPreferenceChanged(_ chapter: Marker, shouldPlay: Bool) {
        chapter.shouldPlay = shouldPlay
        configureChapterBoundaryObserver()

        if let id = chapter.uuid {
            let chapterActor = self.chapterActor
            Task.detached(priority: .background) {
                await chapterActor?.setShouldPlay(shouldPlay, for: id)
            }
        }

        guard shouldPlay == false,
              chapter == currentChapter else {
            return
        }

        Task {
            await skipOverChapters()
        }
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
        let nextChapter = chapters?.first(where: { ($0.start ?? 0) > playPosition + 0.5 })

        if let start = nextChapter?.start{
             await jumpTo(time: start)
        }else if let end = currentChapter?.end{
            await jumpTo(time: end)
        }
    }

    func skipToPreviousChapter() async {
        let preferredChapters = chapters ?? currentEpisode?.preferredChapters ?? []
        guard preferredChapters.isEmpty == false else { return }

        guard let targetChapter = preferredChapters.last(where: { chapter in
            (chapter.start ?? 0) < playPosition - 0.5
        }) ?? preferredChapters.first else {
            return
        }

        await jumpTo(time: targetChapter.start ?? 0)
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
        guard let finishedEpisodeURL else {
            finishingEpisodeURL = nil
            return
        }
        guard finishingEpisodeURL != finishedEpisodeURL else {
            BasicLogger.shared.log("Ignoring duplicate playback finish for \(finishedEpisodeURL.absoluteString)")
            return
        }
        finishingEpisodeURL = finishedEpisodeURL
        let finalPlaybackPosition = max(playPosition, currentEpisode?.duration ?? 0.0)

        Task {
            let continuePlaying = await settingsActor?.getContiniousPlay() ?? true
            let sleepTimerContinuePlaying = !stopAfterEpisode
            let nextEpisodeURL: URL?
            if sleepTimerContinuePlaying == true && continuePlaying == true {
                if let activePlaylistActor = activePlaybackPlaylistActor() {
                    nextEpisodeURL = try? await activePlaylistActor.nextEpisodeURL(after: finishedEpisodeURL)
                } else {
                    nextEpisodeURL = nil
                }
            } else {
                nextEpisodeURL = nil
            }

            await episodeActor?.setLastPlayed(episodeURL: finishedEpisodeURL)
            await episodeActor?.setPlayPosition(
                episodeURL: finishedEpisodeURL,
                position: finalPlaybackPosition,
                force: true
            )
            PlaybackProgressDefaultsStore.removeProgress(for: finishedEpisodeURL)
            await unloadEpisode(episodeURL: finishedEpisodeURL, finishedPlayback: true)

            if let nextEpisodeURL {
                BasicLogger.shared.log("Playing next episode")
                await playEpisode(nextEpisodeURL, playDirectly: true)
            } else {
                finishingEpisodeURL = nil
            }
        }


        

    }

    private func ensureDownloadForCurrentEpisodeIfNeeded() async {
        guard playbackPowerMode == .foreground else { return }
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

        await loadPlaybackAudioProcessingSettings()
        await configurePlaybackAudioProcessing(for: replacementItem)
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
    

    
    // Always call this function to update nowPlayingInfo—when artwork, position, or rate changes.
    private func updateNowPlayingInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let episode = currentEpisode else { return }
        let effectivePlaybackRate: Float = isPlaying ? playbackRate : 0.0
        lastNowPlayingInfoUpdateDate = Date()
    
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
    
    func createBookmark() {
        Task {
            if let currentEpisodeURL {
                await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
                    .createBookmark(for: currentEpisodeURL, at: playPosition)
            }
        }
    }
    
  
    private func updateNowPlayingCover() async {
        guard let episode = currentEpisode else {
            nowPlayingInfoActor.setArtwork(nil)
            lastArtworkIdentifier = nil
            return
        }
        let coverEpisodeURL = episode.url

        let targetSize = CGSize(width: 600, height: 600)

        if let chapter = currentChapter,
           let chapterImageData = chapter.imageData,
           chapterImageData.isEmpty == false {
            let identifier = "chapter-data:\(chapter.uuid?.uuidString ?? chapter.title):\(chapterImageData.count)"
            if lastArtworkIdentifier == identifier {
                return
            }

            if let image = ImageLoaderAndCache.makeUIImage(
                from: chapterImageData,
                maxPixelSize: max(targetSize.width, targetSize.height)
            ) {
                guard currentEpisodeURL == coverEpisodeURL else { return }
                lastArtworkIdentifier = identifier
                nowPlayingInfoActor.setArtwork(image)
                return
            }
        }

        let imageURLs = [
            currentChapter?.image,
            episode.imageURL,
            episode.podcast?.imageURL
        ].compactMap { $0 }

        guard imageURLs.isEmpty == false else {
            if lastArtworkIdentifier != nil {
                nowPlayingInfoActor.setArtwork(nil)
                lastArtworkIdentifier = nil
            }
            return
        }

        for imageURL in imageURLs {
            let identifier = "url:\(imageURL.absoluteString)"
            if lastArtworkIdentifier == identifier {
                return
            }

            guard let originalImage = await ImageLoaderAndCache.loadUIImage(from: imageURL),
                  let resizedImage = Self.downscale(image: originalImage, to: targetSize) else {
                continue
            }

            guard currentEpisodeURL == coverEpisodeURL else { return }
            lastArtworkIdentifier = identifier
            nowPlayingInfoActor.setArtwork(resizedImage)
            return
        }

        guard currentEpisodeURL == coverEpisodeURL else { return }
        nowPlayingInfoActor.setArtwork(nil)
        lastArtworkIdentifier = nil
    }

    private func updateNowPlayingCover(for episodeURL: URL) async {
        guard currentEpisodeURL == episodeURL else { return }
        await updateNowPlayingCover()
        guard currentEpisodeURL == episodeURL else { return }
    }
    
    private static func downscale(image: UIImage, to size: CGSize) -> UIImage? {
#if canImport(UIKit)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
#else
        guard let source = image.cgImage,
              let context = CGContext(
                data: nil,
                width: max(Int(size.width), 1),
                height: max(Int(size.height), 1),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        guard let resized = context.makeImage() else { return nil }
        return UIImage(cgImage: resized)
#endif
    }
}
