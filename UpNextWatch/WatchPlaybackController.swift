import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class WatchPlaybackController: ObservableObject {
    @Published private(set) var currentEpisodeID: String?
    @Published private(set) var playPosition: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var playbackRate: Float = 1.0
    @Published private var remoteProgressTick = Date()
    @Published var errorMessage: String?

    private weak var store: WatchSyncStore?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var playbackStatusObservation: NSKeyValueObservation?
    private var playbackRateObservation: NSKeyValueObservation?
    private var remoteProgressTimer: Timer?
    private var currentSourceURL: URL?
    private var fallbackEpisode: WatchSyncEpisode?
    private var lastSyncedPosition: Double = 0
    private var lastSyncDate = Date.distantPast

    private let progressSyncInterval: TimeInterval = 20
    private let progressSyncDistance: Double = 15
    private let playbackRates: [Float] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]

    init() {
        installTimeObserver()
        installPlaybackStateObservers()
        installAudioSessionObservers()
        installRemoteProgressTimer()
    }

    func attach(store: WatchSyncStore) {
        self.store = store
    }

    var currentEpisode: WatchSyncEpisode? {
        if isRemoteControlEnabled {
            guard let remoteCurrentEpisodeID else { return fallbackEpisode }
            return store?.episode(withID: remoteCurrentEpisodeID) ?? fallbackEpisode
        }

        guard let currentEpisodeID else { return fallbackEpisode }
        return store?.episode(withID: currentEpisodeID) ?? fallbackEpisode
    }

    private var isRemoteControlEnabled: Bool {
        store?.isRemoteControlEnabled == true
    }

    private var remoteState: WatchPhonePlaybackState? {
        store?.phonePlaybackState
    }

    private var remoteCurrentEpisodeID: String? {
        guard isRemoteControlEnabled else { return nil }
        return remoteState?.currentEpisodeURL
    }

    var currentDuration: Double? {
        if isRemoteControlEnabled,
           let duration = remoteState?.duration,
           duration > 0 {
            return duration
        }

        if let duration = currentEpisode?.duration, duration > 0 {
            return duration
        }

        let loadedDuration = player.currentItem?.duration.seconds ?? 0
        guard loadedDuration.isFinite, loadedDuration > 0 else { return nil }
        return loadedDuration
    }

    var progress: Double {
        guard let currentDuration, currentDuration > 0 else { return 0 }
        return min(max(displayedPlayPosition / currentDuration, 0), 1)
    }

    var currentChapter: WatchSyncChapter? {
        currentEpisode?.chapter(at: displayedPlayPosition)
    }

    var nextChapter: WatchSyncChapter? {
        currentEpisode?.chapters.first(where: { $0.start > displayedPlayPosition + 0.5 })
    }

    var formattedPlaybackRate: String {
        String(format: "%.2gx", effectivePlaybackRate)
    }

    func formattedPlaybackRate(for episode: WatchSyncEpisode) -> String {
        if isCurrentEpisode(episode) {
            return formattedPlaybackRate
        }

        let rate = episode.playbackSettings?.playbackSpeed ?? store?.snapshot.playbackSettings.playbackSpeed ?? 1.0
        return String(format: "%.2gx", rate)
    }

    private var effectivePlaybackSettings: WatchPlaybackSettings {
        currentEpisode?.playbackSettings ?? store?.snapshot.playbackSettings ?? .default
    }

    private var effectivePlaybackRate: Float {
        isRemoteControlEnabled ? (remoteState?.playbackRate ?? playbackRate) : playbackRate
    }

    var displayedPlayPosition: Double {
        guard isRemoteControlEnabled else { return playPosition }
        guard let remoteState else { return 0 }

        let playbackRate = max(Double(remoteState.playbackRate), 0)
        let elapsed = remoteState.isPlaying ? remoteProgressTick.timeIntervalSince(remoteState.generatedAt) * playbackRate : 0
        let estimatedPosition = max(remoteState.playPosition + elapsed, 0)
        if let duration = remoteState.duration, duration > 0 {
            return min(estimatedPosition, duration)
        }

        return estimatedPosition
    }

    var skipBackSeconds: Int {
        effectivePlaybackSettings.skipBackSeconds
    }

    var skipForwardSeconds: Int {
        effectivePlaybackSettings.skipForwardSeconds
    }

    var skipBackSystemName: String {
        "gobackward.\(skipBackSeconds)"
    }

    var skipForwardSystemName: String {
        "goforward.\(skipForwardSeconds)"
    }

    func isCurrentEpisode(_ episode: WatchSyncEpisode) -> Bool {
        if isRemoteControlEnabled {
            return remoteCurrentEpisodeID == episode.episodeURL
        }

        return currentEpisodeID == episode.episodeURL
    }

    func isActivelyPlaying(_ episode: WatchSyncEpisode) -> Bool {
        if isRemoteControlEnabled {
            return isCurrentEpisode(episode) && (remoteState?.isPlaying ?? false)
        }

        return isCurrentEpisode(episode) && isPlaying
    }

    func displayedProgress(for episode: WatchSyncEpisode) -> Double? {
        if isCurrentEpisode(episode) {
            return progress
        }

        return episode.playbackProgress
    }

    func displayedPosition(for episode: WatchSyncEpisode) -> Double {
        if isCurrentEpisode(episode) {
            return displayedPlayPosition
        }

        return episode.playPosition ?? 0
    }

    func artworkURL(for episode: WatchSyncEpisode) -> URL? {
        if isCurrentEpisode(episode) {
            return currentEpisode?.artworkURL(at: displayedPlayPosition) ?? episode.resolvedImageURL
        }

        return episode.artworkURL(at: episode.playPosition)
    }

    func togglePlayback(for episode: WatchSyncEpisode) {
        if isCurrentEpisode(episode) {
            toggleCurrentPlayback()
            return
        }

        play(episode)
    }

    func toggleCurrentPlayback() {
        guard currentEpisode != nil else { return }
        if isRemoteControlEnabled {
            if remoteState?.isPlaying == true {
                store?.remotePause()
            } else {
                store?.remoteResume()
            }
            return
        }

        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func play(_ episode: WatchSyncEpisode, startingAt startTime: Double? = nil) {
        if isRemoteControlEnabled {
            fallbackEpisode = episode
            store?.remotePlay(episode, startingAt: startTime)
            return
        }

        guard let store else {
            errorMessage = "Open the watch app again to finish setting up playback."
            return
        }

        guard let sourceURL = store.playbackURL(for: episode) else {
            errorMessage = "This episode is not available for playback yet."
            return
        }

        errorMessage = nil
        configureAudioSessionIfNeeded()
        applyPlaybackSettings(for: episode)

        let shouldReplaceItem = currentEpisodeID != episode.episodeURL || currentSourceURL != sourceURL
        if shouldReplaceItem {
            flushProgressSync(force: true)
            replaceCurrentItem(with: sourceURL, episode: episode)
            seek(to: startTime ?? episode.playPosition ?? 0) { [weak self] in
                self?.resume()
            }
            return
        }

        if let startTime {
            seek(to: startTime) { [weak self] in
                self?.resume()
            }
            return
        }

        resume()
    }

    func pause() {
        if isRemoteControlEnabled {
            store?.remotePause()
            return
        }

        player.pause()
        isPlaying = false
        isBuffering = false
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: false)
        flushProgressSync(force: true)
    }

    func resume() {
        if isRemoteControlEnabled {
            store?.remoteResume()
            return
        }

        guard currentEpisode != nil else { return }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        isBuffering = false
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: true)
    }

    func cyclePlaybackRate(for episode: WatchSyncEpisode? = nil) {
        let targetEpisode = episode ?? currentEpisode
        let currentSettings = targetEpisode?.playbackSettings ?? store?.snapshot.playbackSettings ?? .default
        let targetsCurrentEpisode = targetEpisode.map(isCurrentEpisode) ?? false
        let currentRate = targetsCurrentEpisode ? playbackRate : currentSettings.playbackSpeed
        let currentIndex = playbackRates.enumerated().min {
            abs($0.element - currentRate) < abs($1.element - currentRate)
        }?.offset ?? 1
        let nextIndex = (currentIndex + 1) % playbackRates.count
        let newRate = playbackRates[nextIndex]

        if targetsCurrentEpisode {
            playbackRate = newRate
        }

        if isRemoteControlEnabled {
            store?.remoteSetPlaybackRate(newRate, for: targetEpisode)
            return
        }

        if isPlaying, targetsCurrentEpisode {
            player.rate = playbackRate
        }

        let updatedSettings = WatchPlaybackSettings(
            playbackSpeed: newRate,
            skipBackSeconds: currentSettings.skipBackSeconds,
            skipForwardSeconds: currentSettings.skipForwardSeconds,
            continuousPlay: currentSettings.continuousPlay,
            isPodcastSpecific: currentSettings.isPodcastSpecific
        )
        store?.setPlaybackSettings(updatedSettings, for: targetEpisode)
    }

    func skipBackward() {
        if isRemoteControlEnabled {
            store?.remoteSkipBackward()
            return
        }

        seek(to: playPosition - Double(skipBackSeconds))
    }

    func skipForward() {
        if isRemoteControlEnabled {
            store?.remoteSkipForward()
            return
        }

        seek(to: playPosition + Double(skipForwardSeconds))
    }

    func skipToNextChapter() {
        if isRemoteControlEnabled {
            store?.remoteSkipToNextChapter()
            return
        }

        guard let nextChapter else { return }
        seek(to: nextChapter.start)
    }

    func skipToChapterStart() {
        if isRemoteControlEnabled {
            store?.remoteSkipToChapterStart()
            return
        }

        guard let chapters = currentEpisode?.chapters, chapters.isEmpty == false else { return }

        let referenceTime = max(playPosition - 3, 0)
        let targetChapter = chapters.last(where: { $0.start <= referenceTime }) ?? currentChapter
        guard let targetChapter else { return }
        seek(to: targetChapter.start)
    }

    func playChapter(_ chapter: WatchSyncChapter) {
        if isRemoteControlEnabled {
            store?.remoteSeek(to: chapter.start)
            return
        }

        if let currentEpisode {
            play(currentEpisode, startingAt: chapter.start)
        }
    }

    func flushProgress() {
        flushProgressSync(force: true)
    }

    private func configureAudioSessionIfNeeded() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPlaybackSettings(for episode: WatchSyncEpisode) {
        let settings = episode.playbackSettings ?? store?.snapshot.playbackSettings ?? .default
        guard settings.playbackSpeed > 0 else { return }
        playbackRate = settings.playbackSpeed
        if isPlaying {
            player.rate = playbackRate
        }
    }

    private func replaceCurrentItem(with sourceURL: URL, episode: WatchSyncEpisode) {
        player.pause()
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        fallbackEpisode = episode
        currentEpisodeID = episode.episodeURL
        currentSourceURL = sourceURL
        playPosition = episode.playPosition ?? 0
        lastSyncedPosition = playPosition
        lastSyncDate = .now
        isPlaying = false
        isBuffering = false
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: false)
        installEndObserver(for: item)
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.handleTimeUpdate(time.seconds)
            }
        }
    }

    private func installPlaybackStateObservers() {
        playbackStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleObservedPlaybackState()
            }
        }

        playbackRateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleObservedPlaybackState()
            }
        }
    }

    private func installAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                self?.handleAudioSessionInterruption(typeValue: typeValue)
            }
        }
    }

    private func installRemoteProgressTimer() {
        remoteProgressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isRemoteControlEnabled,
                      self.remoteState?.isPlaying == true
                else {
                    return
                }

                self.remoteProgressTick = .now
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
    }

    private func handleTimeUpdate(_ seconds: Double) {
        guard seconds.isFinite else { return }

        playPosition = max(seconds, 0)
        syncPlaybackStateFromPlayer()
        skipCurrentChapterIfNeeded()
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: isPlaying)

        flushProgressSync(force: false)
    }

    private func handleObservedPlaybackState() {
        let wasPlaying = isPlaying
        syncPlaybackStateFromPlayer()

        if wasPlaying, isPlaying == false {
            flushProgressSync(force: true)
        }
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: isPlaying)
    }

    private func syncPlaybackStateFromPlayer() {
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isPlaying = player.rate > 0
    }

    private func handleAudioSessionInterruption(typeValue: UInt?) {
        guard let typeValue,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began
        else {
            return
        }

        isPlaying = false
        isBuffering = false
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: false)
        flushProgressSync(force: true)
    }

    private func handlePlaybackFinished() {
        guard let currentDuration else {
            pause()
            return
        }

        playPosition = currentDuration
        isPlaying = false
        isBuffering = false
        player.pause()
        store?.updateComplicationSnapshot(currentEpisodeID: currentEpisodeID, playPosition: playPosition, isPlaying: false)
        flushProgressSync(force: true)
    }

    private func skipCurrentChapterIfNeeded() {
        guard isPlaying,
              let currentChapter,
              currentChapter.shouldPlay == false
        else {
            return
        }

        if let nextChapter {
            seek(to: nextChapter.start)
            return
        }

        handlePlaybackFinished()
    }

    private func seek(to requestedTime: Double, completion: (@MainActor () -> Void)? = nil) {
        let clampedTime: Double
        if let currentDuration, currentDuration > 0 {
            clampedTime = min(max(requestedTime, 0), currentDuration)
        } else {
            clampedTime = max(requestedTime, 0)
        }

        let target = CMTime(seconds: clampedTime, preferredTimescale: 600)
        let completionSnapshot: (@MainActor () -> Void)? = completion
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playPosition = clampedTime
                self.flushProgressSync(force: true)
            }
            if let completionSnapshot {
                Task { @MainActor in
                    completionSnapshot()
                }
            }
        }
    }

    private func flushProgressSync(force: Bool) {
        guard let store, let currentEpisodeID else { return }

        let distance = abs(playPosition - lastSyncedPosition)
        let shouldSync = force
            || distance >= progressSyncDistance
            || Date.now.timeIntervalSince(lastSyncDate) >= progressSyncInterval

        guard shouldSync else { return }

        store.syncPlaybackProgress(for: currentEpisodeID, position: playPosition)
        lastSyncedPosition = playPosition
        lastSyncDate = .now
    }
}
