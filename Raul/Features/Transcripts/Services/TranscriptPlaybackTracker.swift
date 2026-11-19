import AVFoundation
import Foundation
import Observation
import SwiftUI

extension TranscriptSegment {
    func highlightedText(_ active: TranscriptPlaybackTracker.Active?) -> Text {
        guard active?.segmentID == id,
              let location = active?.location, let length = active?.length,
              location >= 0, length > 0, location <= text.utf16.count,
              length <= text.utf16.count - location,
              let range = Range(NSRange(location: location, length: length), in: text) else {
            return Text(text)
        }
        return Text(String(text[..<range.lowerBound]))
            + Text(String(text[range])).bold().underline()
            + Text(String(text[range.upperBound...]))
    }
}

/// A transcript owns this observer only while visible. It never replaces the
/// player's normal progress observer and only publishes a changed caption.
@MainActor
@Observable
final class TranscriptPlaybackTracker {
    struct Active: Equatable {
        let segmentID: UUID
        let location: Int?
        let length: Int?
    }

    private(set) var active: Active?
    @ObservationIgnored private var segments: [TranscriptSegment] = []
    @ObservationIgnored private var episodeURL: URL?
    @ObservationIgnored private var useAlignment = false
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var isRunning = false

    func start(segments: [TranscriptSegment], episodeURL: URL?, useAlignment: Bool) {
        isRunning = true
        self.segments = segments
        self.episodeURL = episodeURL
        self.useAlignment = useAlignment
        attachIfNeeded()
        refresh()
    }

    func update(segments: [TranscriptSegment], episodeURL: URL?, useAlignment: Bool) {
        self.segments = segments
        self.episodeURL = episodeURL
        self.useAlignment = useAlignment
        attachIfNeeded()
        refresh()
    }

    func refresh() {
        guard isRunning else { return }
        guard let episodeURL, episodeURL == Player.shared.currentEpisodeURL else {
            if active != nil { active = nil }
            return
        }
        attachIfNeeded()
        guard let player = observedPlayer else {
            if active != nil { active = nil }
            return
        }
        let audioTime = player.currentTime().seconds
        let transcriptTime = useAlignment
            ? TranscriptSynchronizationStore.shared.transcriptTime(forAudioTime: audioTime, episodeURL: episodeURL)
            : audioTime
        guard let transcriptTime, transcriptTime.isFinite else {
            if active != nil { active = nil }
            return
        }
        let newValue = Self.lookup(segments: segments, at: transcriptTime)
        if active != newValue { active = newValue }
    }

    func stop() {
        isRunning = false
        detach()
        if active != nil { active = nil }
    }

    private func detach() {
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        timeObserver = nil
        jumpObserver = nil
        observedPlayer = nil
    }

    private func attachIfNeeded() {
        guard isRunning else { return }
        let player = Player.shared.videoPlayer
        guard observedPlayer !== player else { return }
        detach()
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        jumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: nil, queue: .main
        ) { [weak self, weak player] notification in
            guard notification.object as? AVPlayerItem === player?.currentItem else { return }
            Task { @MainActor in self?.refresh() }
        }
    }

    static func lookup(segments: [TranscriptSegment], at time: TimeInterval) -> Active? {
        guard time.isFinite else { return nil }
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].startTime <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let segment = segments[low - 1]
        let end = segment.endTime ?? (low < segments.count ? segments[low].startTime : .infinity)
        guard time < end else { return nil }
        let span = segment.activeSpan(at: time)
        return Active(segmentID: segment.id, location: span?.location, length: span?.length)
    }
}
