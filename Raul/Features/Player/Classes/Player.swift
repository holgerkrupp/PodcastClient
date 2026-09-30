import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import mp3ChapterReader
#if canImport(UIKit)
import UIKit
#endif

enum PlaybackMediaSelection: String, Codable, Sendable {
    case primary
    case alternateVideo
}

enum SkipProtectionBehavior: Sendable {
    case protect
    case ignore
}

struct SkipProtectionPolicy {
    static let significantSeekThreshold: TimeInterval = 90
    static let undoLifetime: TimeInterval = 60

    static func shouldOfferUndo(
        from originEpisodeURL: URL,
        position originPosition: TimeInterval,
        to destinationEpisodeURL: URL,
        position destinationPosition: TimeInterval
    ) -> Bool {
        if originEpisodeURL != destinationEpisodeURL {
            return true
        }

        return abs(destinationPosition - originPosition) >= significantSeekThreshold
    }
}

enum RemoteMP3PlaybackDurationReader {
    static func duration(fromID3 tags: [String: Any]) -> TimeInterval? {
        guard let milliseconds = tags["TLEN"] as? String,
              let value = Double(milliseconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else {
            return nil
        }
        return value / 1_000
    }

    static func duration(from url: URL) async -> TimeInterval? {
        if let reader = await mp3ChapterReader.fromRemoteURL(url),
           let duration = duration(fromID3: reader.getID3Dict()) {
            return duration
        }

        // Some MP3s omit TLEN. The package can estimate their length from
        // the remote file size and first audio frame without downloading it.
        return try? await RemoteMP3DurationReader.duration(from: url)
    }
}

struct SkipProtectionUndo: Identifiable, Codable, Sendable {
    let id: UUID
    let episodeURL: URL
    let episodeTitle: String
    let position: TimeInterval
    let mediaSelection: PlaybackMediaSelection
    let wasPlaying: Bool
    let createdAt: Date
    let expiresAt: Date
}

private struct SkipProtectionOrigin {
    let episodeURL: URL
    let episodeTitle: String
    let position: TimeInterval
    let mediaSelection: PlaybackMediaSelection
    let wasPlaying: Bool
}

private struct CachedPlaybackProgress: Codable {
    var playPosition: Double
    var maxPlayPosition: Double
    var chapterProgresses: [String: Double]
    var updatedAt: Date
}

@MainActor
private enum PlaybackProgressDefaultsStore {
    private static let legacyDefaultsKey = "Player.cachedPlaybackProgress.v1"
    private static let indexKey = "Player.cachedPlaybackProgress.index.v2"
    private static let entryKeyPrefix = "Player.cachedPlaybackProgress.entry.v2."
    private static let pendingCompletionKey = "Player.pendingFinishedEpisode.v1"
    private static let defaults = UserDefaults.standard

    struct PendingCompletion: Codable {
        let episodeURL: URL
        let playlistID: UUID?
        let finalPlaybackPosition: Double
    }

    static func cachedProgress(for episodeURL: URL) -> CachedPlaybackProgress? {
        migrateLegacyIfNeeded()
        guard let data = defaults.data(forKey: entryKey(for: episodeURL)) else { return nil }
        return try? JSONDecoder().decode(CachedPlaybackProgress.self, from: data)
    }

    static func allCachedProgress() -> [String: CachedPlaybackProgress] {
        migrateLegacyIfNeeded()
        let keys = defaults.stringArray(forKey: indexKey) ?? []
        return keys.reduce(into: [:]) { result, episodeURLString in
            guard let url = URL(string: episodeURLString),
                  let cached = cachedProgress(for: url) else { return }
            result[episodeURLString] = cached
        }
    }

    /// Most recently updated cached entry, if any.
    ///
    /// An entry only survives here when its write to the store did not land, so
    /// after a crash this is the episode that was actually playing even though
    /// nothing in the store records it yet.
    static func newestCachedProgress() -> (episodeURL: URL, updatedAt: Date)? {
        allCachedProgress()
            .lazy
            .compactMap { key, cached -> (episodeURL: URL, updatedAt: Date)? in
                guard let url = URL(string: key) else { return nil }
                return (url, cached.updatedAt)
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func update(
        episodeURL: URL,
        playPosition: Double,
        maxPlayPosition: Double,
        chapterID: UUID?,
        chapterProgress: Double?
    ) {
        let key = episodeURL.absoluteString
        var cached = cachedProgress(for: episodeURL) ?? CachedPlaybackProgress(
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
        guard let data = try? JSONEncoder().encode(cached) else { return }
        defaults.set(data, forKey: entryKey(for: episodeURL))
        var index = defaults.stringArray(forKey: indexKey) ?? []
        if index.contains(key) == false { index.append(key) }
        defaults.set(index, forKey: indexKey)
    }

    static func removeProgress(for episodeURL: URL) {
        migrateLegacyIfNeeded()
        defaults.removeObject(forKey: entryKey(for: episodeURL))
        var index = defaults.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == episodeURL.absoluteString }
        if index.isEmpty {
            defaults.removeObject(forKey: indexKey)
        } else {
            defaults.set(index, forKey: indexKey)
        }
    }

    static func savePendingCompletion(
        episodeURL: URL,
        playlistID: UUID?,
        finalPlaybackPosition: Double
    ) {
        let pending = PendingCompletion(
            episodeURL: episodeURL,
            playlistID: playlistID,
            finalPlaybackPosition: finalPlaybackPosition
        )
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: pendingCompletionKey)
    }

    static func pendingCompletion() -> PendingCompletion? {
        guard let data = defaults.data(forKey: pendingCompletionKey) else { return nil }
        return try? JSONDecoder().decode(PendingCompletion.self, from: data)
    }

    static func removePendingCompletion() {
        defaults.removeObject(forKey: pendingCompletionKey)
    }

    private static func entryKey(for episodeURL: URL) -> String {
        entryKeyPrefix + episodeURL.absoluteString
    }

    private static func migrateLegacyIfNeeded() {
        guard let data = defaults.data(forKey: legacyDefaultsKey),
              let legacy = try? JSONDecoder().decode(
                  [String: CachedPlaybackProgress].self,
                  from: data
              ) else { return }

        var index = defaults.stringArray(forKey: indexKey) ?? []
        for (episodeURLString, cached) in legacy {
            guard let url = URL(string: episodeURLString),
                  let encoded = try? JSONEncoder().encode(cached) else { continue }
            defaults.set(encoded, forKey: entryKey(for: url))
            if index.contains(episodeURLString) == false {
                index.append(episodeURLString)
            }
        }
        defaults.set(index, forKey: indexKey)
        defaults.removeObject(forKey: legacyDefaultsKey)
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

    private struct PlaybackAudioProcessingSettings {
        let reduceSilenceGapsEnabled: Bool
        let silenceGapReductionLevel: SilenceGapReductionLevel
        let voiceEnhancementEnabled: Bool
    }

    enum LivePlaybackState: Equatable, Sendable {
        case connecting
        case live
        case buffering
        case paused
        case ended
        case failed(String)
        case unsupported

        var label: String {
            switch self {
            case .connecting: "Connecting"
            case .live: "Live"
            case .buffering: "Buffering"
            case .paused: "Paused"
            case .ended: "Ended"
            case .failed: "Playback failed"
            case .unsupported: "Unsupported stream"
            }
        }
    }

    private struct SuspendedPlaybackContext {
        let episodeURL: URL
        let wasPlaying: Bool
        let position: Double
        let mediaSelection: PlaybackMediaSelection
    }

    private static let playSessionRecoveryLastRunKey = "PlaySessionRecoveryLastRun"
    private static let playSessionRecoveryMinimumInterval: TimeInterval = 60 * 60 * 12
    private static let playSessionRecoveryStartupDelayNanoseconds: UInt64 = 15_000_000_000
    private static let skipProtectionUndoDefaultsKey = "Player.skipProtectionUndo.v1"
    
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
    private var liveStreamStatusObservation: NSKeyValueObservation?
    private var liveStreamSources: [PodcastLiveItem.StreamSource] = []
    private var liveStreamSourceIndex = 0
    private var suspendedPlaybackContext: SuspendedPlaybackContext?
    private var currentPlaybackUsesAlternateMedia = false
    private var playbackLoadGeneration: UInt64 = 0
    private var hasStartedRecovery = false
    private var wasPlayingBeforeInterruption = false
    private var finishingEpisodeURL: URL?
    /// The manual playlist that supplied the current episode. This is captured
    /// when the episode is loaded so a later playlist selection change cannot
    /// redirect successor/dequeue logic at completion time.
    private var currentPlaybackPlaylistID: UUID?
    private var isSkippingChapters = false
    private var chapterSkipPlan = ChapterSkipPlan(entries: [])
    private let chapterBoundaryTolerance: TimeInterval = 0.35
    private var playbackPowerMode: PlaybackPowerMode = .foreground
#if canImport(UIKit)
    // When an AVPlayer item ends, the audio background assertion can disappear
    // before the async queue lookup and replacement item have started. Keep a
    // very short execution lease over that handoff; the new item takes over as
    // soon as AVPlayer reports that it is playing.
    private var episodeTransitionBackgroundTaskID = UIBackgroundTaskIdentifier.invalid
    private var episodeTransitionBackgroundTaskTimeout: Task<Void, Never>?
#endif
    private var reduceSilenceGapsEnabled = false
    private var silenceGapReductionLevel: SilenceGapReductionLevel = .low
    private var voiceEnhancementEnabled = false
    private var introSkipSeconds: TimeInterval = 0
    private var outroSkipSeconds: TimeInterval = 0
    private var silenceGapReductionActive = false
    private var silenceGapReductionStartedAt: Date?
    private var pendingSilenceGapTimeSavedSeconds: TimeInterval = 0
    private var pendingSkipProtectionOrigin: SkipProtectionOrigin?
    private var skipProtectionExpirationTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkLoadGeneration: UInt64 = 0
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

    /// While listening together over SharePlay, features that seek, change
    /// the rate or switch episodes on their own are off: the playback
    /// coordinator would apply them to everyone in the session.
    var isInSharedListeningSession = false {
        didSet {
            guard isInSharedListeningSession, oldValue == false else { return }
            setSilenceGapReductionActive(false)
        }
    }
    
    
    
    
    var playPosition: Double = 0.0
    var skipForwardStep: SkipSteps = .thirty
    var skipBackStep: SkipSteps = .fifteen
    var skipForwardBehavior: SkipButtonBehavior = .seconds
    var skipBackBehavior: SkipButtonBehavior = .seconds
    
    
    var currentEpisode: Episode? {
        didSet {
            scheduleCurrentArtworkUpdate()
        }
    }
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
    private(set) var livePlaybackState: LivePlaybackState = .ended
    private(set) var currentLiveItem: PodcastLiveItem?

    var isLivePlayback: Bool {
        currentPlaybackSource == .liveRemote
    }
    
    var chapterProgress: Double?
    var currentChapter: Marker? {
        didSet {
            scheduleCurrentArtworkUpdate()
        }
    }
    var nextChapter: Marker?
    var chapters: [Marker]?
    private(set) var currentArtworkImage: UIImage?
    
    var allowScrubbing:Bool?
    private(set) var skipProtectionEnabled = false
    private(set) var skipProtectionNotificationsEnabled = false
    private(set) var skipProtectionUndo: SkipProtectionUndo?

    
     init()  {
      //  episodeActor = EpisodeActor(modelContainer: ModelContainerManager.shared.container)
        
      //  super.init()
        restorePersistedSkipProtectionUndo()
        Task {
            await retryPendingFinishedEpisode()

            // Restoring the episode is what makes the player usable, so nothing
            // else may sit in front of it. The cache reconciliation below used
            // to run first and walked every leftover entry with a store write
            // each; `restoreLastPlayedFromPlaylist` reads the same cache
            // directly, so it no longer needs that pass to have finished.
            await restoreLastPlayedFromPlaylist()

            // Remove legacy UUID-based last-played storage from older builds.
            await migrateLastPlayedFromUserDefaultsIfNeeded()
            await reconcileCachedPlaybackProgress()
        }
        loadPlayBackSpeed()
        listenToEvent()
        observeEnginePlaybackState()
        pause()
        addChangeSettingsObserver()
        addDownloadObserver()
        Task{
            allowScrubbing = await settingsActor?.getAppSliderEnable()
            await loadSkipProtectionSettings()
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

    private func loadSkipProtectionSettings() async {
        let isEnabled = await settingsActor?.getSkipProtectionEnabled() ?? false
        let notificationsEnabled = await settingsActor?.getSkipProtectionNotificationsEnabled() ?? false
        skipProtectionEnabled = isEnabled
        skipProtectionNotificationsEnabled = isEnabled && notificationsEnabled

        if isEnabled == false {
            clearSkipProtectionUndo()
        } else if notificationsEnabled == false {
            Task {
                await NotificationManager.shared.removeSkipProtectionUndoNotification()
            }
        }
    }

    private func restorePersistedSkipProtectionUndo() {
        guard let data = UserDefaults.standard.data(forKey: Self.skipProtectionUndoDefaultsKey),
              let undo = try? JSONDecoder().decode(SkipProtectionUndo.self, from: data),
              undo.expiresAt > Date() else {
            UserDefaults.standard.removeObject(forKey: Self.skipProtectionUndoDefaultsKey)
            return
        }

        skipProtectionUndo = undo
        scheduleSkipProtectionExpiration(for: undo)
    }

    private func persistSkipProtectionUndo(_ undo: SkipProtectionUndo?) {
        guard let undo,
              let data = try? JSONEncoder().encode(undo) else {
            UserDefaults.standard.removeObject(forKey: Self.skipProtectionUndoDefaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.skipProtectionUndoDefaultsKey)
    }

    private func scheduleSkipProtectionExpiration(for undo: SkipProtectionUndo) {
        skipProtectionExpirationTask?.cancel()
        let delay = max(0, undo.expiresAt.timeIntervalSinceNow)
        skipProtectionExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard Task.isCancelled == false,
                  self?.skipProtectionUndo?.id == undo.id else {
                return
            }
            self?.clearSkipProtectionUndo()
        }
    }

    private func currentSkipProtectionOrigin(position: TimeInterval? = nil) -> SkipProtectionOrigin? {
        guard currentPlaybackSource != .liveRemote,
              let episodeURL = currentEpisodeURL else {
            return nil
        }

        return SkipProtectionOrigin(
            episodeURL: episodeURL,
            episodeTitle: currentEpisode?.title ?? String(localized: "Previous episode"),
            position: sanitizedPosition(position ?? playPosition),
            mediaSelection: mediaSelection,
            wasPlaying: isPlaying
        )
    }

    private func offerSkipProtectionUndo(from origin: SkipProtectionOrigin) {
        guard skipProtectionEnabled else { return }

        if let existingUndo = skipProtectionUndo {
            if existingUndo.expiresAt > Date() {
                pendingSkipProtectionOrigin = nil
                return
            }
            clearSkipProtectionUndo()
        }

        let createdAt = Date()
        let undo = SkipProtectionUndo(
            id: UUID(),
            episodeURL: origin.episodeURL,
            episodeTitle: origin.episodeTitle,
            position: origin.position,
            mediaSelection: origin.mediaSelection,
            wasPlaying: origin.wasPlaying,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(SkipProtectionPolicy.undoLifetime)
        )
        skipProtectionUndo = undo
        pendingSkipProtectionOrigin = nil
        persistSkipProtectionUndo(undo)
        scheduleSkipProtectionExpiration(for: undo)

        guard skipProtectionNotificationsEnabled else { return }
        Task { [weak self] in
            guard self?.skipProtectionUndo?.id == undo.id,
                  self?.skipProtectionNotificationsEnabled == true else {
                return
            }
            await NotificationManager.shared.sendSkipProtectionUndoNotification(
                undoID: undo.id,
                episodeTitle: undo.episodeTitle,
                positionDescription: Self.positionDescription(undo.position),
                expiresAt: undo.expiresAt
            )
        }
    }

    func beginSkipProtectionSeek() {
        guard skipProtectionEnabled,
              skipProtectionUndo == nil,
              pendingSkipProtectionOrigin == nil else {
            return
        }
        pendingSkipProtectionOrigin = currentSkipProtectionOrigin()
    }

    func endSkipProtectionSeek(at progress: Double) {
        guard let origin = pendingSkipProtectionOrigin else { return }
        pendingSkipProtectionOrigin = nil
        guard let duration = currentEpisode?.duration,
              duration.isFinite,
              duration > 0 else {
            return
        }

        let destinationPosition = min(max(progress, 0), 1) * duration
        guard let destinationURL = currentEpisodeURL,
              SkipProtectionPolicy.shouldOfferUndo(
                from: origin.episodeURL,
                position: origin.position,
                to: destinationURL,
                position: destinationPosition
              ) else {
            return
        }
        offerSkipProtectionUndo(from: origin)
    }

    func dismissSkipProtectionUndo() {
        clearSkipProtectionUndo()
    }

    func undoSkipProtection(undoID: UUID? = nil) async {
        guard let undo = skipProtectionUndo,
              undoID == nil || undo.id == undoID,
              undo.expiresAt > Date() else {
            clearSkipProtectionUndo()
            return
        }

        if currentEpisodeURL == undo.episodeURL,
           mediaSelection == undo.mediaSelection {
            await jumpTo(time: undo.position, protectLargeSeek: false)
            if undo.wasPlaying {
                play()
            } else {
                pause()
            }
        } else {
            await playEpisode(
                undo.episodeURL,
                playDirectly: undo.wasPlaying,
                startingAt: undo.position,
                mediaSelection: undo.mediaSelection,
                skipProtectionBehavior: .ignore
            )
        }

        clearSkipProtectionUndo()
    }

    private func clearSkipProtectionUndo() {
        skipProtectionExpirationTask?.cancel()
        skipProtectionExpirationTask = nil
        pendingSkipProtectionOrigin = nil
        skipProtectionUndo = nil
        persistSkipProtectionUndo(nil)
        Task {
            await NotificationManager.shared.removeSkipProtectionUndoNotification()
        }
    }

    private static func positionDescription(_ position: TimeInterval) -> String {
        Duration.seconds(max(0, position)).formatted(
            .time(pattern: .minuteSecond(padMinuteToLength: 1))
        )
    }

    private func activePlaybackPlaylistActor() -> PlaylistModelActor? {
        try? PlaylistModelActor(activePlaybackPlaylistIn: ModelContainerManager.shared.container)
    }

    /// Captures the selected playlist only when it actually supplied the
    /// episode. A nil result explicitly represents playback started outside a
    /// playlist; it is not permission to re-resolve the selection at finish.
    private func capturePlaybackPlaylistID(for episodeURL: URL) async -> UUID? {
        do {
            let actor = try PlaylistModelActor(
                activePlaybackPlaylistIn: ModelContainerManager.shared.container
            )
            guard try await actor.containsEpisodeURL(episodeURL) else {
                AppDiagnostics.log(
                    "Playback episode is outside the selected playlist: \(episodeURL.redactedPodcastURLString)"
                )
                return nil
            }
            return actor.playlistID
        } catch {
            AppDiagnostics.log(
                "Could not capture playback playlist for \(episodeURL.redactedPodcastURLString): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func moveEpisodeToFrontOfActivePlaybackPlaylist(_ episodeURL: URL) async {
        // `playEpisode` defers this to a background task, so playback may already
        // have moved on — or finished, and dequeued this episode — by the time it
        // runs. Re-adding then would put a played episode back at the top of the
        // queue, which is exactly the state the finish handler just cleared.
        guard currentEpisodeURL == episodeURL else { return }
        guard let activePlaylistActor = activePlaybackPlaylistActor() else { return }
        try? await activePlaylistActor.add(
            episodeURL: episodeURL,
            to: .front,
            startDownload: false,
            origin: .automatic
        )
    }
    
    func restoreLastPlayedFromPlaylist() async {
        guard let activePlaylistActor = activePlaybackPlaylistActor() else { return }
        let candidateURL = await launchResumeCandidateURL()
        guard let resumeURL = try? await activePlaylistActor.launchEpisodeURL(
            preferring: candidateURL
        ) else { return }

        await playEpisode(
            resumeURL,
            playDirectly: false,
            skipProtectionBehavior: .ignore
        )
    }

    /// The episode this device was last playing, according to whichever record
    /// is newer: the persisted `lastPlayed` stamp or an unreconciled progress
    /// entry left in the defaults cache by a session that ended before its
    /// write landed.
    private func launchResumeCandidateURL() async -> URL? {
        let persisted = await episodeActor?.lastPlayedEpisodeReference()
        guard let newestCached = PlaybackProgressDefaultsStore.newestCachedProgress() else {
            return persisted?.url
        }
        guard let persisted else { return newestCached.episodeURL }
        return newestCached.updatedAt > persisted.lastPlayed
            ? newestCached.episodeURL
            : persisted.url
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
                await self?.loadSkipProtectionSettings()
                await self?.loadPlaybackAudioProcessingSettings()
                await self?.loadPlaybackTrimSettings(applyToCurrentPlayback: true)
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
        let settings = await playbackAudioProcessingSettings(for: currentEpisode?.podcast?.feed)
        applyPlaybackAudioProcessingSettings(settings)
    }

    private func playbackAudioProcessingSettings(for podcastFeed: URL?) async -> PlaybackAudioProcessingSettings {
        PlaybackAudioProcessingSettings(
            reduceSilenceGapsEnabled: await settingsActor?.getReduceSilenceGapsEnabled(for: podcastFeed) ?? false,
            silenceGapReductionLevel: await settingsActor?.getSilenceGapReductionLevel(for: podcastFeed) ?? .low,
            voiceEnhancementEnabled: await settingsActor?.getVoiceEnhancementEnabled(for: podcastFeed) ?? false
        )
    }

    private func applyPlaybackAudioProcessingSettings(_ settings: PlaybackAudioProcessingSettings) {
        reduceSilenceGapsEnabled = settings.reduceSilenceGapsEnabled
        silenceGapReductionLevel = settings.silenceGapReductionLevel
        voiceEnhancementEnabled = settings.voiceEnhancementEnabled
    }

    @discardableResult
    private func loadPlaybackTrimSettings(
        for podcastFeed: URL? = nil,
        applyToCurrentPlayback: Bool
    ) async -> PodcastPlaybackTrim {
        let resolvedFeed = podcastFeed ?? currentEpisode?.podcast?.feed
        let trim = await settingsActor?.getPlaybackTrim(for: resolvedFeed) ?? PodcastPlaybackTrim()
        introSkipSeconds = trim.introSkipSeconds
        outroSkipSeconds = trim.outroSkipSeconds
        configureOutroBoundaryObserver()

        guard applyToCurrentPlayback,
              isInSharedListeningSession == false,
              currentPlaybackSource != .liveRemote,
              currentEpisode != nil else {
            return trim
        }

        if playPosition < trim.introSkipSeconds {
            await jumpTo(time: trim.introSkipSeconds, protectLargeSeek: false)
        }
        _ = finishAtOutroIfNeeded(position: playPosition, source: "settings_change")
        return trim
    }

    private func currentPlaybackDuration() -> TimeInterval? {
        let itemDuration = engine.currentItemDuration()
        if let itemDuration, itemDuration > 0 {
            return itemDuration
        }
        guard let episodeDuration = currentEpisode?.duration,
              episodeDuration.isFinite,
              episodeDuration > 0 else {
            return nil
        }
        return episodeDuration
    }

    private func configureOutroBoundaryObserver() {
        let boundary = PlaybackTrimPolicy.outroBoundary(
            duration: currentPlaybackDuration(),
            outroSkipSeconds: outroSkipSeconds
        )
        let boundaryTime = boundary.map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }

        engine.setOutroBoundaryTimeObserver(at: boundaryTime) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let position = self.sanitizedPosition(self.engine.currentTime())
                _ = self.finishAtOutroIfNeeded(position: position, source: "outro_boundary")
            }
        }
    }

    @discardableResult
    private func finishAtOutroIfNeeded(position: TimeInterval, source: String) -> Bool {
        guard isInSharedListeningSession == false,
              currentPlaybackSource != .liveRemote,
              isPlaying,
              let duration = currentPlaybackDuration(),
              PlaybackTrimPolicy.hasReachedOutro(
                position: position,
                duration: duration,
                outroSkipSeconds: outroSkipSeconds
              ) else {
            return false
        }

        engine.pause()
        playPosition = duration
        updateEpisodeProgress(to: duration)
        updateNowPlayingInfo()
        AppDiagnostics.log("Skipping podcast outro (\(source)): \(outroSkipSeconds) seconds")
        handlePlaybackFinished()
        return true
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

    @discardableResult
    private func advancePlaybackLoadGeneration() -> UInt64 {
        playbackLoadGeneration &+= 1
        return playbackLoadGeneration
    }

    private func isCurrentPlaybackLoad(
        _ generation: UInt64,
        episodeURL: URL,
        item: AVPlayerItem
    ) -> Bool {
        playbackLoadGeneration == generation &&
        currentEpisodeURL == episodeURL &&
        videoPlayer.currentItem === item
    }

    private func resetPlaybackAudioProcessing(for item: AVPlayerItem? = nil) async {
        resetSilenceGapReduction(updateEngine: false)
        await flushSilenceGapTimeSaved()
#if !os(watchOS)
        currentAudioPlaybackProcessor = nil
        item?.audioMix = nil
#endif
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
              isInSharedListeningSession == false,
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

    private func configurePlaybackAudioProcessing(
        for item: AVPlayerItem,
        shouldApply: () -> Bool = { true }
    ) async {
        guard shouldApply() else { return }
        await resetPlaybackAudioProcessing(for: item)
        guard shouldApply() else { return }
#if !os(watchOS)
        guard currentPlaybackSource != .liveRemote,
              currentPlaybackUsesAlternateMedia == false,
              currentPlaybackIsVideo == false,
              reduceSilenceGapsEnabled || voiceEnhancementEnabled else {
            return
        }

        guard let audioTrack = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            return
        }
        guard shouldApply() else { return }

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

    private func schedulePlaybackAudioProcessing(
        for item: AVPlayerItem,
        episodeURL: URL,
        generation: UInt64
    ) {
        let podcastFeed = currentEpisode?.podcast?.feed
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard isCurrentPlaybackLoad(generation, episodeURL: episodeURL, item: item) else {
                return
            }
            let settings = await playbackAudioProcessingSettings(for: podcastFeed)
            guard isCurrentPlaybackLoad(generation, episodeURL: episodeURL, item: item) else {
                return
            }
            applyPlaybackAudioProcessingSettings(settings)
            await configurePlaybackAudioProcessing(for: item) { [weak self] in
                guard let self else { return false }
                return isCurrentPlaybackLoad(generation, episodeURL: episodeURL, item: item)
            }
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
            chapterSkipPlan = ChapterSkipPlan(entries: [])
            currentChapter = nil
            nextChapter = nil
            configureChapterBoundaryObserver()
            return
        }

        chapters = currentEpisode.preferredChapters
        rebuildChapterSkipPlan()
        configureChapterBoundaryObserver()
        RemoteCommandCenter.shared.updateSkipIntervals()
    }

    private func configureChapterBoundaryObserver() {
        let chapterStartTimes = chapterSkipPlan.boundaryTimes
            .filter { $0 > 0 }
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        Task { [weak self] in
            guard let self else { return }
            self.engine.setBoundaryTimeObserver(at: chapterStartTimes) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleChapterBoundary()
                }
            }
        }
    }

    private func rebuildChapterSkipPlan() {
        chapterSkipPlan = ChapterSkipPlan(entries: (chapters ?? []).compactMap { chapter in
            guard let start = chapter.start else { return nil }
            return ChapterSkipPlan.Entry(
                id: chapter.uuid,
                start: start,
                shouldPlay: chapter.shouldPlay
            )
        })
    }

    private func handleChapterBoundary() async {
        guard currentPlaybackSource != .liveRemote else { return }

        let currentTime = sanitizedPosition(engine.currentTime())
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

        if let currentChapter {
            let progressAtBoundary = chapterProgress(for: currentChapter, at: playPosition)
            let progressToSave = max(chapterProgress ?? 0.0, progressAtBoundary)
            saveChapterProgress(chapter: currentChapter, progress: progressToSave)
        }

        currentChapter = playingChapter
        chapterProgress = 0.0
        updateChapterProgress()
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
        chapterProgress = chapterProgress(for: currentChapter, at: playPosition)
    }
    
    private func saveChapterProgress(chapter: Marker, progress: Double){
        let clampedProgress = clampedProgress(progress)
        chapter.progress = clampedProgress
        cacheCurrentPlaybackState(chapterID: chapter.uuid, chapterProgress: clampedProgress)

        guard let chapterID = chapter.uuid else { return }
        Task {
            await chapterActor?.setChapterProgress(clampedProgress, for: chapterID)
        }
    }

    private func sanitizedPosition(_ value: Double?) -> Double {
        guard let value,
              value.isFinite else {
            return 0
        }

        return max(0, value)
    }

    private func clampedProgress(_ value: Double?) -> Double {
        guard let value,
              value.isFinite else {
            return 0
        }

        return min(max(value, 0), 1)
    }

    private func chapterProgress(for chapter: Marker, at position: Double) -> Double {
        guard let chapterStart = chapter.start else { return 0 }

        let chapterEnd = chapter.end
            ?? chapters?
                .compactMap(\.start)
                .filter { $0 > chapterStart }
                .min()
            ?? currentEpisode?.duration
            ?? chapterStart
        guard chapterEnd > chapterStart else { return 0 }

        let clampedPosition = min(max(position, chapterStart), chapterEnd)
        return clampedProgress((clampedPosition - chapterStart) / (chapterEnd - chapterStart))
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
            AppDiagnostics.log("Time provided when calling the playEpisode function: \(explicitTime)")
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
                AppDiagnostics.log("using max position as resume fallback: \(maxFallback)")
                candidate = maxFallback
            }
        }

        let duration = sanitizedPosition(episodeDuration)
        if duration > 0,
           candidate >= (duration * progressThreshold) {
            AppDiagnostics.log("episode considered finished - jump to beginning")
            return 0
        }

        if candidate > 0 {
            AppDiagnostics.log("jump to last position: \(candidate)")
        } else {
            AppDiagnostics.log("no persisted position - jump to beginning")
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
        let resolvedChapterProgress = (explicitChapterProgress ?? chapterProgress).map(clampedProgress)

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
            // The loaded episode's state belongs to the live player now; its
            // entry is persisted and cleared by the normal save path instead.
            guard episodeURL != currentEpisodeURL else { continue }
            let didPersist = await episodeActor?.applyCachedPlaybackProgress(
                episodeURL: episodeURL,
                playPosition: sanitizedPosition(cached.playPosition),
                maxPlayPosition: sanitizedPosition(cached.maxPlayPosition),
                chapterProgresses: cached.chapterProgresses.mapValues(clampedProgress)
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
        var chapterProgresses = cachedPlaybackProgress(for: currentEpisodeURL)?.chapterProgresses ?? [:]
        if let currentChapterID, let currentChapterProgress {
            chapterProgresses[currentChapterID.uuidString] = clampedProgress(currentChapterProgress)
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

        playPosition = sanitizedPosition(engine.currentTime())
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

    private func accessProfile(for episode: Episode) -> PodcastAccessProfile? {
        guard let metadata = episode.podcast?.metaData,
              let id = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feedURL = episode.podcast?.feed else {
            return nil
        }
        return PodcastAccessProfile(id: id, kind: kind, resourceURL: feedURL)
    }

    private func authorizedPlayerItem(for url: URL, profile: PodcastAccessProfile?) -> AVPlayerItem {
        guard let profile,
              let request = try? PodcastAccessResolver().request(for: url, profile: profile),
              let requestURL = request.url else {
            return AVPlayerItem(url: url)
        }

        var options: [String: Any] = [:]
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authorization]
        }
        let asset = AVURLAsset(url: requestURL, options: options)
        return AVPlayerItem(asset: asset)
    }

    private func playbackItem(
        for episode: Episode,
        mediaSelection selection: PlaybackMediaSelection
    ) -> (item: AVPlayerItem, source: PlaybackSource, usesAlternateMedia: Bool)? {
        if selection == .alternateVideo, let alternateVideo = episode.alternateVideo {
            return (authorizedPlayerItem(for: alternateVideo.url, profile: accessProfile(for: episode)), .remote, true)
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
        let item = authorizedPlayerItem(for: remoteURL, profile: accessProfile(for: episode))
        item.preferredForwardBufferDuration = 0
        return (item, .remote, false)
    }

    private func shouldRequeueEpisodeOnUnload(_ episode: Episode, episodeURL: URL) async -> Bool {
        if episode.metaData?.isArchived == true || episode.metaData?.status == .archived {
            AppDiagnostics.log("skip requeue on unload: archived episode \(episodeURL.redactedPodcastURLString)")
            return false
        }

        if episode.metaData?.isHistory == true || episode.metaData?.status == .history {
            AppDiagnostics.log("skip requeue on unload: history episode \(episodeURL.redactedPodcastURLString)")
            return false
        }

        if episode.metaData?.completionDate != nil {
            AppDiagnostics.log("skip requeue on unload: completed episode \(episodeURL.redactedPodcastURLString)")
            return false
        }

        let activePlaylistActor = activePlaybackPlaylistActor()
        let isCurrentlyQueued = (try? await activePlaylistActor?.containsEpisodeURL(episodeURL)) ?? false
        if isCurrentlyQueued == false {
            AppDiagnostics.log("skip requeue on unload: episode no longer queued \(episodeURL.redactedPodcastURLString)")
        }
        return isCurrentlyQueued
    }

    private func snapshotCurrentEpisodeForFastSwitch(episodeURL: URL) async -> EpisodeUnloadSnapshot? {
        guard currentEpisodeURL == episodeURL,
              currentPlaybackSource != .liveRemote else {
            return nil
        }

        playPosition = sanitizedPosition(engine.currentTime())
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

        var chapterProgresses = PlaybackProgressDefaultsStore
            .cachedProgress(for: snapshot.episodeURL)?
            .chapterProgresses ?? [:]
        if let chapterID = snapshot.chapterID,
           let chapterProgress = snapshot.chapterProgress {
            chapterProgresses[chapterID.uuidString] = clampedProgress(chapterProgress)
        }
        for (chapterIDString, chapterProgress) in chapterProgresses {
            guard let chapterID = UUID(uuidString: chapterIDString) else { continue }
            await chapterActor?.setChapterProgress(clampedProgress(chapterProgress), for: chapterID)
        }

        PlaybackProgressDefaultsStore.removeProgress(for: snapshot.episodeURL)

        let shouldRequeueUnfinishedEpisode: Bool
        if snapshot.isArchived {
            AppDiagnostics.log("skip requeue on fast switch unload: archived episode \(snapshot.episodeURL.redactedPodcastURLString)")
            shouldRequeueUnfinishedEpisode = false
        } else if snapshot.isHistory {
            AppDiagnostics.log("skip requeue on fast switch unload: history episode \(snapshot.episodeURL.redactedPodcastURLString)")
            shouldRequeueUnfinishedEpisode = false
        } else if snapshot.isCompleted {
            AppDiagnostics.log("skip requeue on fast switch unload: completed episode \(snapshot.episodeURL.redactedPodcastURLString)")
            shouldRequeueUnfinishedEpisode = false
        } else {
            let activePlaylistActor = activePlaybackPlaylistActor()
            shouldRequeueUnfinishedEpisode = (try? await activePlaylistActor?.containsEpisodeURL(snapshot.episodeURL)) ?? false
            if shouldRequeueUnfinishedEpisode == false {
            AppDiagnostics.log("skip requeue on fast switch unload: episode no longer queued \(snapshot.episodeURL.redactedPodcastURLString)")
            }
        }

        AppDiagnostics.log(
            "fastSwitchUnload url=\(snapshot.episodeURL.absoluteString) playProgress=\(snapshot.playProgress)"
        )

        if snapshot.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: snapshot.episodeURL)
            await episodeActor?.moveToHistory(episodeURL: snapshot.episodeURL)
        } else if shouldRequeueUnfinishedEpisode {
            try? await activePlaybackPlaylistActor()?.add(
                episodeURL: snapshot.episodeURL,
                to: .front,
                origin: .automatic
            )
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
        AppDiagnostics.log(
            "unloadEpisode url=\(episodeURL.absoluteString) finishedPlayback=\(finishedPlayback) playProgress=\(episode.playProgress)"
        )

        stopPlaybackUpdates()
        currentEpisode = nil
        currentEpisodeURL = nil
        currentPlaybackPlaylistID = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        advancePlaybackLoadGeneration()
        configureChapterBoundaryObserver()
        engine.removeOutroBoundaryTimeObserver()
        currentPlaybackSource = nil
        currentPlaybackUsesAlternateMedia = false
        mediaSelection = .primary
        introSkipSeconds = 0
        outroSkipSeconds = 0
        resetSilenceGapReduction(updateEngine: false)
        await flushSilenceGapTimeSaved()
#if !os(watchOS)
        currentAudioPlaybackProcessor = nil
#endif
        lastProgressSaveDate = .distantPast
        await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: nil)
        WatchSyncCoordinator.refreshSoon(force: true)

        if finishedPlayback || episode.playProgress >= progressThreshold {
            await episodeActor?.setCompletionDate(episodeURL: episodeURL)
            await episodeActor?.moveToHistory(episodeURL: episodeURL)
        } else if shouldRequeueUnfinishedEpisode {
            try? await activePlaybackPlaylistActor()?.add(
                episodeURL: episodeURL,
                to: .front,
                origin: .automatic
            )
        }
    }
    
    
    
    func playEpisode(
        _ episodeURL: URL?,
        playDirectly: Bool = true,
        startingAt time: Double? = nil,
        mediaSelection requestedMediaSelection: PlaybackMediaSelection? = nil,
        skipProtectionBehavior: SkipProtectionBehavior = .protect
    ) async {
        guard let episodeURL,
              let episode = await fetchEpisode(with: episodeURL) else { return }

        // Do not let a manual switch discard a completion that still needs its
        // queue mutation. Retrying here also covers a transient store failure
        // without waiting for the next process launch.
        if PlaybackProgressDefaultsStore.pendingCompletion() != nil {
            await retryPendingFinishedEpisode()
        }

        let previousEpisodeURL = currentEpisodeURL
        let playbackPlaylistID = previousEpisodeURL == episodeURL
            ? currentPlaybackPlaylistID
            : await capturePlaybackPlaylistID(for: episodeURL)
        let previousProtectionOrigin = pendingSkipProtectionOrigin
            ?? currentSkipProtectionOrigin()
        let fastSwitchUnloadSnapshot: EpisodeUnloadSnapshot?
        if let currentEpisodeURL, currentEpisodeURL != episodeURL {
            fastSwitchUnloadSnapshot = await snapshotCurrentEpisodeForFastSwitch(episodeURL: currentEpisodeURL)
        } else {
            fastSwitchUnloadSnapshot = nil
        }

        if skipProtectionBehavior == .protect,
           previousEpisodeURL != episodeURL || time != nil,
           let previousProtectionOrigin {
            let origin: SkipProtectionOrigin
            if let fastSwitchUnloadSnapshot,
               pendingSkipProtectionOrigin == nil {
                origin = SkipProtectionOrigin(
                    episodeURL: previousProtectionOrigin.episodeURL,
                    episodeTitle: previousProtectionOrigin.episodeTitle,
                    position: fastSwitchUnloadSnapshot.playPosition,
                    mediaSelection: previousProtectionOrigin.mediaSelection,
                    wasPlaying: previousProtectionOrigin.wasPlaying
                )
            } else {
                origin = previousProtectionOrigin
            }

            let destinationPosition = sanitizedPosition(time)
            if SkipProtectionPolicy.shouldOfferUndo(
                from: origin.episodeURL,
                position: origin.position,
                to: episodeURL,
                position: destinationPosition
            ) {
                offerSkipProtectionUndo(from: origin)
            }
        }
        pendingSkipProtectionOrigin = nil

        let selectedMedia = normalizedMediaSelection(
            requestedMediaSelection ?? (previousEpisodeURL == episodeURL ? mediaSelection : .primary),
            for: episode
        )

        currentEpisode = episode
        currentLiveItem = nil
        if currentPlaybackSource == .liveRemote {
            suspendedPlaybackContext = nil
            liveStreamStatusObservation?.invalidate()
            liveStreamStatusObservation = nil
        }
        currentEpisodeURL = episodeURL
        finishingEpisodeURL = nil
        currentPlaybackPlaylistID = playbackPlaylistID
        mediaSelection = selectedMedia
        let playbackTrim = await loadPlaybackTrimSettings(
            for: episode.podcast?.feed,
            applyToCurrentPlayback: false
        )
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
        lastProgressSaveDate = Date()

        updateChapters()

        guard let playback = playbackItem(for: episode, mediaSelection: selectedMedia) else { return }
        let playbackGeneration = advancePlaybackLoadGeneration()
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

        engine.pause()
        await resetPlaybackAudioProcessing(for: item)
        engine.replaceCurrentItem(with: item)
        configureChapterBoundaryObserver()
        configureOutroBoundaryObserver()
        schedulePlaybackAudioProcessing(
            for: item,
            episodeURL: episodeURL,
            generation: playbackGeneration
        )

        AppDiagnostics.log(
            "playing episode \(episode.title) - playPosition \(String(describing: currentEpisode?.metaData?.playPosition)) maxPosition \(String(describing: currentEpisode?.metaData?.maxPlayposition)) snapshotPosition \(String(describing: snapshot?.playPosition))"
        )
        let inMemoryResumePosition = (previousEpisodeURL == episodeURL) ? playPosition : nil
        let resumePosition = resolvedResumePosition(
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
        let targetStartTime = PlaybackTrimPolicy.initialPosition(
            resumePosition: resumePosition,
            introSkipSeconds: playbackTrim.introSkipSeconds,
            duration: currentPlaybackDuration()
        )

        // When SharePlay loads an episode for this participant (without
        // playing it), the coordinator moves us to the group's position;
        // seeking to our own resume position would move the group instead.
        let loadingForSharedSession = isInSharedListeningSession && playDirectly == false
        if targetStartTime > 0, loadingForSharedSession == false {
            await jumpTo(time: targetStartTime, protectLargeSeek: false)
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
        if playback.source == .remote,
           playback.usesAlternateMedia == false,
           episode.url?.pathExtension.lowercased() == "mp3" {
            if episode.duration.map({ $0.isFinite && $0 > 0 }) != true {
                Task(priority: .utility) { [weak self] in
                    await self?.fillMissingRemoteMP3Duration(
                        for: episodeURL,
                        generation: playbackGeneration,
                        item: item
                    )
                }
            }
            if (episode.chapters ?? []).contains(where: { $0.type == .mp3 }) == false {
                let podcastFeed = episode.podcast?.feed
                Task(priority: .utility) { [weak self] in
                    await self?.loadRemoteMP3Chapters(
                        for: episodeURL,
                        podcastFeed: podcastFeed,
                        generation: playbackGeneration,
                        item: item
                    )
                }
            }
        }
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        if let fastSwitchUnloadSnapshot {
            Task(priority: .utility) {
                await finishFastSwitchUnload(fastSwitchUnloadSnapshot)
            }
        }

        Task {
            await moveEpisodeToFrontOfActivePlaybackPlaylist(episodeURL)
            await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: episodeURL)
            WatchSyncCoordinator.refreshSoon(force: true)
        }

    }

    private func fillMissingRemoteMP3Duration(
        for episodeURL: URL,
        generation: UInt64,
        item: AVPlayerItem
    ) async {
        guard let duration = await RemoteMP3PlaybackDurationReader.duration(from: episodeURL),
              duration.isFinite, duration > 0,
              isCurrentPlaybackLoad(generation, episodeURL: episodeURL, item: item),
              let episode = currentEpisode,
              episode.duration.map({ $0.isFinite && $0 > 0 }) != true else {
            return
        }

        episode.duration = duration
        episode.refresh.toggle()
        episodeActor?.modelContainer.mainContext.saveIfNeeded()
        configureOutroBoundaryObserver()
        updateNowPlayingInfo()
    }

    private func loadRemoteMP3Chapters(
        for episodeURL: URL,
        podcastFeed: URL?,
        generation: UInt64,
        item: AVPlayerItem
    ) async {
        let remoteChapters = await ChapterExtractionHooks.loadRemoteMP3Chapters(episodeURL)
        guard remoteChapters.isEmpty == false else { return }
        let skipRules = await settingsActor?.getChapterSkipKeywords(for: podcastFeed) ?? []
        guard isCurrentPlaybackLoad(generation, episodeURL: episodeURL, item: item),
              let episode = currentEpisode else {
            return
        }

        EpisodeChapterMerger.replaceChapters(
            on: episode,
            replacingTypes: [.mp3],
            with: remoteChapters
        )
        _ = ChapterSkipKeywordPolicy.apply(skipRules, to: episode.chapters ?? [])
        episode.refresh.toggle()
        episodeActor?.modelContainer.mainContext.saveIfNeeded()
        updateChapters()
        _ = updateCurrentChapter()
        updateChapterProgress()
        await skipOverChapters()
        WatchSyncCoordinator.refreshSoon(force: true)
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

        let playbackGeneration = advancePlaybackLoadGeneration()
        mediaSelection = nextSelection
        currentPlaybackSource = playback.source
        currentPlaybackUsesAlternateMedia = playback.usesAlternateMedia
        await resetPlaybackAudioProcessing(for: playback.item)
        engine.replaceCurrentItem(with: playback.item)
        configureChapterBoundaryObserver()
        if let episodeURL = currentEpisodeURL {
            schedulePlaybackAudioProcessing(
                for: playback.item,
                episodeURL: episodeURL,
                generation: playbackGeneration
            )
        }
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

    func playLiveItem(
        _ liveItem: PodcastLiveItem,
        podcastTitle: String,
        artworkURL: URL?,
        link: URL?
    ) async {
        guard liveItem.preferredStream != nil else {
            livePlaybackState = .unsupported
            return
        }

        await suspendNormalPlaybackIfNeeded()
        let preferredStream = liveItem.preferredStream!
        liveStreamSources = [preferredStream]
            + liveItem.streamSources.filter { $0 != preferredStream }
        liveStreamSourceIndex = 0
        let firstURL = preferredStream.url

        let liveEpisode = Episode(
            guid: liveItem.id,
            title: liveItem.title,
            publishDate: nil,
            url: firstURL,
            podcast: nil,
            duration: nil,
            author: podcastTitle
        )
        liveEpisode.imageURL = liveItem.artworkURL ?? artworkURL
        liveEpisode.link = link ?? liveItem.link
        currentEpisode = liveEpisode
        currentLiveItem = liveItem
        currentEpisodeURL = firstURL
        currentPlaybackPlaylistID = nil
        currentPlaybackSource = .liveRemote
        livePlaybackState = .connecting
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        advancePlaybackLoadGeneration()
        configureChapterBoundaryObserver()
        playPosition = 0
        lastProgressSaveDate = .distantPast

        await installLiveStreamSource(at: liveStreamSourceIndex)
        isPlayerSheetPresented = true
    }

    /// Compatibility entry point for callers that only have a single URL.
    func playLiveStream(
        url: URL,
        title: String,
        podcastTitle: String,
        artworkURL: URL?,
        link: URL?
    ) async {
        let item = PodcastLiveItem(
            id: url.absoluteString,
            guid: nil,
            title: title,
            status: .live,
            start: nil,
            end: nil,
            summary: nil,
            artworkURL: artworkURL,
            link: link,
            streamSources: [PodcastLiveItem.StreamSource(url: url, isDefault: true)],
            chat: [],
            contentLinks: []
        )
        await playLiveItem(item, podcastTitle: podcastTitle, artworkURL: artworkURL, link: link)
    }

    private func suspendNormalPlaybackIfNeeded() async {
        if currentPlaybackSource == .liveRemote {
            stopPlaybackUpdates()
            engine.pause()
            liveStreamStatusObservation?.invalidate()
            liveStreamStatusObservation = nil
            return
        }

        guard let episodeURL = currentEpisodeURL else { return }
        playPosition = sanitizedPosition(engine.currentTime())
        await saveCurrentPlaybackState(force: true)
        suspendedPlaybackContext = SuspendedPlaybackContext(
            episodeURL: episodeURL,
            wasPlaying: isPlaying,
            position: playPosition,
            mediaSelection: mediaSelection
        )
        stopPlaybackUpdates()
        engine.pause()
        isPlaying = false
    }

    private func installLiveStreamSource(at index: Int) async {
        guard liveStreamSources.indices.contains(index) else {
            livePlaybackState = .failed("No playable live source is available")
            return
        }
        liveStreamSourceIndex = index
        let source = liveStreamSources[index]
        guard source.url.scheme?.lowercased() == "http" || source.url.scheme?.lowercased() == "https" else {
            await tryNextLiveStreamSource(after: index, error: "Unsupported live stream URL")
            return
        }

        liveStreamStatusObservation?.invalidate()
        liveStreamStatusObservation = nil
        currentEpisodeURL = source.url
        currentPlaybackSource = .liveRemote
        livePlaybackState = .connecting
        let item = AVPlayerItem(url: source.url)
        liveStreamStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentPlaybackSource == .liveRemote else { return }
                switch item.status {
                case .readyToPlay:
                    if self.livePlaybackState == .connecting {
                        self.livePlaybackState = .live
                    }
                case .failed:
                    await self.tryNextLiveStreamSource(
                        after: index,
                        error: item.error?.localizedDescription ?? "The live stream failed"
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        await resetPlaybackAudioProcessing(for: item)
        engine.replaceCurrentItem(with: item)
        setupStaticNowPlayingInfo()
        play()
    }

    private func tryNextLiveStreamSource(after index: Int, error: String) async {
        guard currentPlaybackSource == .liveRemote else { return }
        let nextIndex = liveStreamSources[(index + 1)...].firstIndex { source in
            source.url.scheme?.lowercased() == "http" || source.url.scheme?.lowercased() == "https"
        }
        guard let nextIndex else {
            livePlaybackState = .failed(error)
            isPlaying = false
            stopPlaybackUpdates()
            return
        }
        await installLiveStreamSource(at: nextIndex)
    }

    func endLivePlayback() async {
        guard currentPlaybackSource == .liveRemote else { return }
        let context = suspendedPlaybackContext
        suspendedPlaybackContext = nil
        liveStreamStatusObservation?.invalidate()
        liveStreamStatusObservation = nil
        liveStreamSources = []
        stopPlaybackUpdates()
        engine.pause()
        currentPlaybackSource = nil
        currentEpisode = nil
        currentEpisodeURL = nil
        currentLiveItem = nil
        livePlaybackState = .ended
        isPlaying = false

        if let context {
            await playEpisode(
                context.episodeURL,
                playDirectly: context.wasPlaying,
                startingAt: context.position,
                mediaSelection: context.mediaSelection,
                skipProtectionBehavior: .ignore
            )
        } else {
            isPlayerSheetPresented = false
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
                // Slider gestures record their origin and final value explicitly,
                // so intermediate drag updates must not create competing undo snapshots.
                await jumpTo(time: newTime.seconds, protectLargeSeek: false)
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
        if currentPlaybackSource == .liveRemote {
            switch observedPlayer.timeControlStatus {
            case .waitingToPlayAtSpecifiedRate:
                livePlaybackState = .buffering
            case .playing:
                livePlaybackState = .live
            case .paused:
                switch livePlaybackState {
                case .ended, .failed(_), .unsupported:
                    break
                default:
                    livePlaybackState = .paused
                }
            @unknown default:
                break
            }
            if observedPlayer.rate > 0 {
                isPlaying = true
            }
            return
        }

        if observedPlayer.rate > 0 || observedPlayer.timeControlStatus == .playing {
            finishEpisodeTransitionBackgroundTask()
            if isPlaying == false {
                // In SharePlay the coordinator has already applied the group's
                // rate; re-applying ours would change it for everyone.
                transitionToPlaying(
                    updateEngineRate: isInSharedListeningSession == false,
                    preparePlaybackSource: false
                )
            }
        } else if isInSharedListeningSession,
                  isPlaying,
                  observedPlayer.timeControlStatus == .paused {
            // Another SharePlay participant paused.
            transitionToPaused(pauseEngine: false)
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
        // A background transition assertion is no longer needed once the app
        // is active. This also covers opening the app while a replacement item
        // is still buffering.
        finishEpisodeTransitionBackgroundTask()
        let powerModeChanged = playbackPowerMode != .foreground
        playbackPowerMode = .foreground
        restartSleepTimerIfNeeded()

        guard currentEpisodeURL != nil else { return }
        playPosition = sanitizedPosition(engine.currentTime())
        if currentEpisode?.chapters?.isEmpty == false {
            _ = updateCurrentChapter()
            updateChapterProgress()
        }
        updateNowPlayingInfo()
        if powerModeChanged {
            restartPlaybackUpdatesIfNeeded()
        }

        // Becoming active can race the system releasing a higher-priority audio
        // session, or expose a player that kept advancing after its route was
        // lost. Reassert the listener's existing play intent so the engine
        // reacquires an output route even when SwiftUI already shows Pause.
        if isPlaying {
            let effectiveRate = silenceGapReductionActive
                ? AudioSilenceGapDetector.silenceReducedRate(
                    for: playbackRate,
                    level: silenceGapReductionLevel
                )
                : playbackRate
            engine.resume(atRate: effectiveRate)
        }
    }

    private func restartPlaybackUpdatesIfNeeded() {
        guard playbackTask != nil else { return }
        startPlaybackUpdates()
    }

    private func beginEpisodeTransitionBackgroundTask() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return }

        finishEpisodeTransitionBackgroundTask()
        let taskID = UIApplication.shared.beginBackgroundTask(
            withName: "StartNextPlaybackEpisode"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishEpisodeTransitionBackgroundTask()
            }
        }
        guard taskID != .invalid else {
            AppDiagnostics.log("Could not acquire background time for next episode")
            return
        }

        episodeTransitionBackgroundTaskID = taskID
        // This is a safety net, not the normal completion path. The task is
        // normally released by the AVPlayer rate/status observation above.
        episodeTransitionBackgroundTaskTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard Task.isCancelled == false else { return }
            self?.finishEpisodeTransitionBackgroundTask()
        }
#endif
    }

    private func finishEpisodeTransitionBackgroundTask() {
#if canImport(UIKit)
        episodeTransitionBackgroundTaskTimeout?.cancel()
        episodeTransitionBackgroundTaskTimeout = nil

        guard episodeTransitionBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(episodeTransitionBackgroundTaskID)
        episodeTransitionBackgroundTaskID = .invalid
#endif
    }

    private func restartSleepTimerIfNeeded() {
        guard endDate != nil else { return }
        startSleepTimer()
    }

    private func transitionToPlaying(updateEngineRate: Bool, preparePlaybackSource: Bool) {
        let desiredRate = playbackRate
        let desiredEngineRate = silenceGapReductionActive
            ? AudioSilenceGapDetector.silenceReducedRate(for: desiredRate, level: silenceGapReductionLevel)
            : desiredRate

        // Start audio before caching progress or scheduling persistence/sync work.
        // In particular, MPRemoteCommandCenter invokes this path while the app is
        // backgrounded, where a queued main-actor task can otherwise be delayed
        // long enough to make AirPods and CarPlay appear unresponsive.
        if updateEngineRate {
            engine.resume(atRate: desiredEngineRate)
        }

        isPlaying = true
        updateNowPlayingInfo()
        loadSkipDurations()
        startPlaybackUpdates()
        initRemoteCommandCenter()
        WatchSyncCoordinator.refreshSoon(force: true)

        let position = playPosition
        let currentEpisodeURL = currentEpisode?.url
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        Task {
            cacheCurrentPlaybackState()

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
                engine.pause()
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
        engine.setInterruptionHandler { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.handleInterruptionBegan()
                case .pause:
                    self.pause()
                case .ended:
                    self.wasPlayingBeforeInterruption = false
                    AppDiagnostics.log("Interruption Ended Without Resume")
                case .resume:
                    let shouldResume = self.wasPlayingBeforeInterruption
                    self.wasPlayingBeforeInterruption = false
                    if shouldResume {
                        self.resumeAfterInterruption()
                    }
                case .activationFailed(let description):
                    AppDiagnostics.log("Audio Session Activation Failed: \(description)")
                    if self.currentPlaybackSource == .liveRemote {
                        self.livePlaybackState = .failed(description)
                    }
                    if self.isPlaying {
                        self.transitionToPaused(pauseEngine: true)
                    }
                case .finished:
                    self.handlePlaybackEndedEvent(source: "interruption_finished_event")
                }
            }
        }
    }

    private func handleInterruptionBegan(){
        AppDiagnostics.log("Interruption Began")
        pause()
    }
    
    private func resumeAfterInterruption(){
        AppDiagnostics.log("Interruption Ended")
        play()
    }
    
    func play(){
        loadPlayBackSpeed()
        transitionToPlaying(updateEngineRate: true, preparePlaybackSource: true)
    }

    private func playPreparedEpisode() async {
        engine.resume(atRate: playbackRate)
        transitionToPlaying(updateEngineRate: false, preparePlaybackSource: true)
    }
    
    

    func pause() {
        transitionToPaused(pauseEngine: true)
    }
    
    func skipback(){
        guard currentPlaybackSource != .liveRemote else { return }
        jumpPlaypostion(by: -skipBackStep.seconds, protectLargeSeek: false)
        
    }
    
    func skipforward(){
        guard currentPlaybackSource != .liveRemote else { return }
        jumpPlaypostion(by: skipForwardStep.seconds, protectLargeSeek: false)
    }

    func remoteSkipBack() {
        guard currentPlaybackSource != .liveRemote else { return }
        if remoteSkipBackUsesChapter {
            Task {
                await skipToPreviousChapter(protectLargeSeek: false)
            }
            return
        }

        jumpPlaypostion(by: -skipBackStep.seconds, protectLargeSeek: false)
    }

    func remoteSkipForward() {
        guard currentPlaybackSource != .liveRemote else { return }
        if remoteSkipForwardUsesChapter {
            Task {
                await skipToNextChapter(protectLargeSeek: false)
            }
            return
        }

        jumpPlaypostion(by: skipForwardStep.seconds, protectLargeSeek: false)
    }
    
    func jumpPlaypostion(by seconds: Double, protectLargeSeek: Bool = true) {
        guard currentPlaybackSource != .liveRemote else { return }
        Task{
             let secondsToAdd = CMTimeMakeWithSeconds(seconds,preferredTimescale: 1)
             
             let now = CMTimeMakeWithSeconds(playPosition,preferredTimescale: 1)
             let jumpToTime = CMTimeAdd(now, secondsToAdd).seconds
             await jumpTo(time: jumpToTime, protectLargeSeek: protectLargeSeek)
         }
    }

    func jumpTo(time: Double, protectLargeSeek: Bool = true) async {
        guard currentPlaybackSource != .liveRemote else { return }
        let safeTime = max(0, time)
        if protectLargeSeek,
           pendingSkipProtectionOrigin == nil,
           let episodeURL = currentEpisodeURL {
            let enginePosition = sanitizedPosition(engine.currentTime())
            if let origin = currentSkipProtectionOrigin(position: enginePosition),
               SkipProtectionPolicy.shouldOfferUndo(
                from: origin.episodeURL,
                position: origin.position,
                to: episodeURL,
                position: safeTime
               ) {
                offerSkipProtectionUndo(from: origin)
            }
        }
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
            let stream = engine.playbackStream(interval: playbackPowerMode.progressUpdateInterval)
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .position(let time):
                    let sanitizedTime = self.sanitizedPosition(time)
                    self.playPosition = sanitizedTime
                    self.updateEpisodeProgress(to: sanitizedTime)
                    if self.finishAtOutroIfNeeded(
                        position: sanitizedTime,
                        source: "progress_update"
                    ) {
                        break
                    }
                case .ended:
                    let finalPosition = engine.currentTime()
                    let itemDuration = engine.currentItemDuration()
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
        if currentPlaybackSource == .liveRemote {
            livePlaybackState = .ended
            isPlaying = false
            stopPlaybackUpdates()
            updateNowPlayingInfo()
            return
        }

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
            AppDiagnostics.log("Ignoring ended event from \(source): episode duration unavailable")
            return
        }

        let finishThreshold = max(resolvedDuration * progressThreshold, resolvedDuration - 2.0)
        guard trustedEndEvent || resolvedPosition >= finishThreshold else {
            AppDiagnostics.log(
                "Ignoring premature ended event from \(source): position=\(resolvedPosition), duration=\(resolvedDuration)"
            )
            return
        }

        playPosition = resolvedPosition
        AppDiagnostics.log("Playback finished automatically (\(source))")
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
        guard isSkippingChapters == false, isInSharedListeningSession == false else { return }
        guard let segment = chapterSkipPlan.segment(at: playPosition) else { return }

        isSkippingChapters = true
        defer { isSkippingChapters = false }

        let chapterActor = self.chapterActor
        for id in segment.chapterIDs {
            Task.detached(priority: .background) {
                await chapterActor?.markChapterAsSkipped(id)
            }
        }

        guard let resumeAt = segment.resumeAt else {
            handlePlaybackFinished()
            return
        }

        guard resumeAt < (currentEpisode?.duration ?? .greatestFiniteMagnitude) else {
            handlePlaybackFinished()
            return
        }

        // This seek is app-directed: the listener explicitly marked these
        // chapters as "don't play". It must never create skip-protection UI or
        // an undo notification, regardless of the skipped segment's length.
        await jumpTo(time: resumeAt, protectLargeSeek: false)
    }

    func chapterPlaybackPreferenceChanged(_ chapter: Marker, shouldPlay: Bool) {
        chapter.shouldPlay = shouldPlay
        rebuildChapterSkipPlan()
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
    
    func skipToNextChapter(protectLargeSeek: Bool = true) async {
        let nextChapter = chapters?.first(where: { ($0.start ?? 0) > playPosition + 0.5 })

        if let start = nextChapter?.start{
             await jumpTo(time: start, protectLargeSeek: protectLargeSeek)
        }else if let end = currentChapter?.end{
            await jumpTo(time: end, protectLargeSeek: protectLargeSeek)
        }
    }

    func skipToPreviousChapter(protectLargeSeek: Bool = true) async {
        let preferredChapters = chapters ?? currentEpisode?.preferredChapters ?? []
        guard preferredChapters.isEmpty == false else { return }

        guard let targetChapter = preferredChapters.last(where: { chapter in
            (chapter.start ?? 0) < playPosition - 0.5
        }) ?? preferredChapters.first else {
            return
        }

        await jumpTo(
            time: targetChapter.start ?? 0,
            protectLargeSeek: protectLargeSeek
        )
    }
    
    func skipToChapterStart(protectLargeSeek: Bool = true) async {
        guard let currentChapter else {
            return
        }
        if let start = currentChapter.start{
             await jumpTo(time: start, protectLargeSeek: protectLargeSeek)
        }
    }


    private func handlePlaybackFinished() {
        stopPlaybackUpdates()
        let finishedEpisodeURL = currentEpisodeURL
        guard let finishedEpisodeURL else {
            finishingEpisodeURL = nil
            return
        }
        guard finishingEpisodeURL != finishedEpisodeURL else {
            AppDiagnostics.log("Ignoring duplicate playback finish for \(finishedEpisodeURL.redactedPodcastURLString)")
            return
        }
        finishingEpisodeURL = finishedEpisodeURL
        let finalPlaybackPosition = max(playPosition, currentEpisode?.duration ?? 0.0)
        let playbackPlaylistID = currentPlaybackPlaylistID
        AppDiagnostics.log(
            "Playback finished; captured final position for \(finishedEpisodeURL.redactedPodcastURLString)"
        )
        PlaybackProgressDefaultsStore.savePendingCompletion(
            episodeURL: finishedEpisodeURL,
            playlistID: playbackPlaylistID,
            finalPlaybackPosition: finalPlaybackPosition
        )
        beginEpisodeTransitionBackgroundTask()

        Task {
            let continuePlaying = await settingsActor?.getContiniousPlay() ?? true
            let sleepTimerContinuePlaying = !stopAfterEpisode

            let queuedSuccessor = await commitFinishedEpisode(
                episodeURL: finishedEpisodeURL,
                finalPlaybackPosition: finalPlaybackPosition,
                playlistID: playbackPlaylistID
            )

            let nextEpisodeURL: URL?
            if sleepTimerContinuePlaying,
               continuePlaying,
               isInSharedListeningSession == false,
               queuedSuccessor != nil {
                nextEpisodeURL = queuedSuccessor
            } else {
                // In a SharePlay session each participant's queue differs, so
                // auto-advancing would split the group; stop at the end instead.
                nextEpisodeURL = nil
            }

            // Clear the in-memory playback state only after the durable completion
            // phase. A failed phase leaves a retry marker in UserDefaults and does
            // not silently advance to a successor.
            await resetPlaybackStateForFinishedEpisode(refreshPresentation: nextEpisodeURL == nil)

            if let nextEpisodeURL {
                AppDiagnostics.log(
                    "Successor activated after completion commit: \(nextEpisodeURL.redactedPodcastURLString)"
                )
                await playEpisode(
                    nextEpisodeURL,
                    playDirectly: true,
                    skipProtectionBehavior: .ignore
                )

                // Keep the lease while the replacement item activates its
                // audio session. If loading failed before it installed the
                // next item, there is nothing left for the lease to protect.
                if currentEpisodeURL != nextEpisodeURL {
                    finishEpisodeTransitionBackgroundTask()
                }
            } else {
                finishingEpisodeURL = nil
                finishEpisodeTransitionBackgroundTask()
            }
        }
    }

    /// Completes the finished episode before playback state is cleared or the
    /// transition lease is released. A failed queue mutation is left in the
    /// pending-completion store so the next launch retries it before restoring
    /// playback.
    private func commitFinishedEpisode(
        episodeURL: URL,
        finalPlaybackPosition: Double,
        playlistID: UUID?
    ) async -> URL? {
        do {
            guard let episodeActor else {
                throw EpisodeCompletionError.episodeNotFound(episodeURL)
            }

            AppDiagnostics.log(
                "Committing completion state for \(episodeURL.redactedPodcastURLString)"
            )
            try await episodeActor.commitFinishedEpisode(
                episodeURL: episodeURL,
                finalPlaybackPosition: finalPlaybackPosition
            )

            let successor: URL?
            if let playlistID {
                let playlistActor = try PlaylistModelActor(
                    modelContainer: ModelContainerManager.shared.container,
                    playlistID: playlistID
                )
                successor = try await playlistActor.dequeueFinishedEpisodeAndReturnNext(
                    after: episodeURL
                )
            } else {
                // This episode was not supplied by the selected queue. Remove
                // any stale copies without inventing a successor.
                let playlistActor = try PlaylistModelActor(
                    modelContainer: ModelContainerManager.shared.container
                )
                try await playlistActor.removeFromAllPlaylists(episodeURL: episodeURL)
                successor = nil
            }

            PlaybackProgressDefaultsStore.removeProgress(for: episodeURL)
            PlaybackProgressDefaultsStore.removePendingCompletion()
            AppDiagnostics.log(
                "Completion transaction finished for \(episodeURL.redactedPodcastURLString)"
            )
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            WatchSyncCoordinator.refreshSoon(force: true)
            return successor
        } catch {
            AppDiagnostics.log(
                "Completion transaction failed for \(episodeURL.redactedPodcastURLString): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func retryPendingFinishedEpisode() async {
        guard let pending = PlaybackProgressDefaultsStore.pendingCompletion() else { return }

        AppDiagnostics.log(
            "Retrying pending completion for \(pending.episodeURL.redactedPodcastURLString)"
        )
        _ = await commitFinishedEpisode(
            episodeURL: pending.episodeURL,
            finalPlaybackPosition: pending.finalPlaybackPosition,
            playlistID: pending.playlistID
        )
    }

    /// Resets the in-memory state left behind by the episode that just finished, so the next
    /// episode can be loaded without inheriting stale chapters/artwork/audio-processing state.
    private func resetPlaybackStateForFinishedEpisode(refreshPresentation: Bool) async {
        stopPlaybackUpdates()
        currentEpisode = nil
        currentEpisodeURL = nil
        currentPlaybackPlaylistID = nil
        currentChapter = nil
        chapterProgress = nil
        nextChapter = nil
        chapters = []
        advancePlaybackLoadGeneration()
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

        // Only refresh the widget/watch for an "empty" state when there is no next episode.
        // When a next episode follows, `playEpisode` refreshes them with the correct URL.
        if refreshPresentation {
            await PlayNextWidgetSync.refresh(using: ModelContainerManager.shared.container, currentEpisodeURL: nil)
            WatchSyncCoordinator.refreshSoon(force: true)
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

        _ = await DownloadManager.shared.download(
            from: remoteURL,
            saveTo: episode.localFile,
            profile: accessProfile(for: episode)
        )
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
        let playbackGeneration = advancePlaybackLoadGeneration()

        await resetPlaybackAudioProcessing(for: replacementItem)
        engine.replaceCurrentItem(with: replacementItem)
        currentPlaybackSource = .local
        if let episodeURL = currentEpisodeURL {
            schedulePlaybackAudioProcessing(
                for: replacementItem,
                episodeURL: episodeURL,
                generation: playbackGeneration
            )
        }
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
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playPosition,
            MPNowPlayingInfoPropertyPlaybackRate: effectivePlaybackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let duration = episode.duration, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
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
    
  
    /// Keeps one resolved artwork image for both the in-app player and Now Playing.
    /// The only synchronous operation here is an in-memory cache lookup; decoding,
    /// disk access, and downloads stay outside the main actor.
    private func scheduleCurrentArtworkUpdate() {
        artworkLoadGeneration &+= 1
        let generation = artworkLoadGeneration
        artworkLoadTask?.cancel()
        artworkLoadTask = nil

        guard let episode = currentEpisode else {
            applyCurrentArtwork(nil)
            return
        }

        let chapter = currentChapter.flatMap { candidate in
            episode.preferredChapters.contains { episodeChapter in
                episodeChapter === candidate ||
                    (candidate.uuid != nil && episodeChapter.uuid == candidate.uuid)
            } ? candidate : nil
        }
        let chapterData = chapter?.imageData.flatMap { $0.isEmpty ? nil : $0 }
        let imageURLs = [
            chapter?.image,
            episode.imageURL,
            episode.podcast?.imageURL
        ].compactMap { $0 }

        if chapterData == nil,
           let primaryURL = imageURLs.first,
           let cachedImage = SharedImageRepository.cachedImage(for: primaryURL) {
            applyCurrentArtwork(cachedImage)
            return
        }

        applyCurrentArtwork(nil)
        artworkLoadTask = Task(priority: .userInitiated) { [weak self] in
            let image = await Self.loadCurrentArtwork(
                chapterData: chapterData,
                imageURLs: imageURLs
            )
            guard Task.isCancelled == false,
                  let self,
                  artworkLoadGeneration == generation else {
                return
            }
            applyCurrentArtwork(image)
            artworkLoadTask = nil
        }
    }

    private func applyCurrentArtwork(_ image: UIImage?) {
        currentArtworkImage = image
        if let image {
            nowPlayingInfoActor.setArtwork(image)
        } else {
            nowPlayingInfoActor.setArtwork(nil)
        }
    }

    nonisolated private static func loadCurrentArtwork(
        chapterData: Data?,
        imageURLs: [URL]
    ) async -> UIImage? {
        if let chapterData,
           let chapterImage = await Task.detached(priority: .userInitiated, operation: {
               ImageLoaderAndCache.makeUIImage(from: chapterData)
           }).value {
            return chapterImage
        }

        var loadedURLs = Set<URL>()
        for imageURL in imageURLs where loadedURLs.insert(imageURL).inserted {
            if Task.isCancelled { return nil }
            if let image = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                return image
            }
        }
        return nil
    }
}
