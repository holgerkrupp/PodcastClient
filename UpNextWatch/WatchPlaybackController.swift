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
    @Published var errorMessage: String?

    private weak var store: WatchSyncStore?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentSourceURL: URL?
    private var fallbackEpisode: WatchSyncEpisode?
    private var lastSyncedPosition: Double = 0
    private var lastSyncDate = Date.distantPast

    private let progressSyncInterval: TimeInterval = 20
    private let progressSyncDistance: Double = 15
    private let playbackRates: [Float] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    init() {
        installTimeObserver()
    }

    func attach(store: WatchSyncStore) {
        self.store = store
    }

    var currentEpisode: WatchSyncEpisode? {
        guard let currentEpisodeID else { return fallbackEpisode }
        return store?.episode(withID: currentEpisodeID) ?? fallbackEpisode
    }

    var currentDuration: Double? {
        if let duration = currentEpisode?.duration, duration > 0 {
            return duration
        }

        let loadedDuration = player.currentItem?.duration.seconds ?? 0
        guard loadedDuration.isFinite, loadedDuration > 0 else { return nil }
        return loadedDuration
    }

    var progress: Double {
        guard let currentDuration, currentDuration > 0 else { return 0 }
        return min(max(playPosition / currentDuration, 0), 1)
    }

    var currentChapter: WatchSyncChapter? {
        currentEpisode?.chapter(at: playPosition)
    }

    var nextChapter: WatchSyncChapter? {
        currentEpisode?.chapters.first(where: { $0.start > playPosition + 0.5 })
    }

    var formattedPlaybackRate: String {
        String(format: "%.2gx", playbackRate)
    }

    func isCurrentEpisode(_ episode: WatchSyncEpisode) -> Bool {
        currentEpisodeID == episode.id
    }

    func isActivelyPlaying(_ episode: WatchSyncEpisode) -> Bool {
        isCurrentEpisode(episode) && isPlaying
    }

    func displayedProgress(for episode: WatchSyncEpisode) -> Double? {
        if isCurrentEpisode(episode) {
            return progress
        }

        return episode.playbackProgress
    }

    func displayedPosition(for episode: WatchSyncEpisode) -> Double {
        if isCurrentEpisode(episode) {
            return playPosition
        }

        return episode.playPosition ?? 0
    }

    func artworkURL(for episode: WatchSyncEpisode) -> URL? {
        if isCurrentEpisode(episode) {
            return currentEpisode?.artworkURL(at: playPosition) ?? episode.resolvedImageURL
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
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func play(_ episode: WatchSyncEpisode, startingAt startTime: Double? = nil) {
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

        let shouldReplaceItem = currentEpisodeID != episode.id || currentSourceURL != sourceURL
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
        player.pause()
        isPlaying = false
        isBuffering = false
        flushProgressSync(force: true)
    }

    func resume() {
        guard currentEpisode != nil else { return }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        isBuffering = false
    }

    func cyclePlaybackRate() {
        let currentIndex = playbackRates.firstIndex(of: playbackRate) ?? 1
        let nextIndex = (currentIndex + 1) % playbackRates.count
        playbackRate = playbackRates[nextIndex]

        if isPlaying {
            player.rate = playbackRate
        }
    }

    func skipBackward() {
        seek(to: playPosition - 15)
    }

    func skipForward() {
        seek(to: playPosition + 30)
    }

    func skipToNextChapter() {
        guard let nextChapter else { return }
        seek(to: nextChapter.start)
    }

    func skipToChapterStart() {
        guard let chapters = currentEpisode?.chapters, chapters.isEmpty == false else { return }

        let referenceTime = max(playPosition - 3, 0)
        let targetChapter = chapters.last(where: { $0.start <= referenceTime }) ?? currentChapter
        guard let targetChapter else { return }
        seek(to: targetChapter.start)
    }

    func playChapter(_ chapter: WatchSyncChapter) {
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
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceCurrentItem(with sourceURL: URL, episode: WatchSyncEpisode) {
        player.pause()
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        fallbackEpisode = episode
        currentEpisodeID = episode.id
        currentSourceURL = sourceURL
        playPosition = episode.playPosition ?? 0
        lastSyncedPosition = playPosition
        lastSyncDate = .now
        isPlaying = false
        isBuffering = false
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
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if player.rate > 0 {
            isPlaying = true
        }

        flushProgressSync(force: false)
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
        flushProgressSync(force: true)
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
