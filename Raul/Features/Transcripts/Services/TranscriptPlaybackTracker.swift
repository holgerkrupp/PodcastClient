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
        return Text("\(Text(String(text[..<range.lowerBound])))\(Text(String(text[range])).bold().underline())\(Text(String(text[range.upperBound...])))")
    }
}

/// Display-only continuity for word highlights. When one or two publisher
/// words between two confidently timed neighbours stayed unmatched, the
/// highlight is held on the earlier word until the later one begins, instead of
/// flickering off. Nothing is written back: the unmatched words keep no timing,
/// and they are never themselves highlighted as spoken.
enum TranscriptHighlightContinuity {
    /// The most unmatched words a bridge may hold the highlight across.
    static let maximumUnmatchedWords = 2
    /// The longest silence (transcript seconds, and audio seconds when
    /// synchronized) between the two timed neighbours that may be bridged.
    static let maximumGap: TimeInterval = 1.5

    /// Returns the earlier timed neighbour when `time` falls in a short gap
    /// that only holds a few unmatched words. `isBridgeAllowed` receives the
    /// gap's transcript-time bounds and must reject ad/unverified audio.
    static func bridgedSpan(
        in segment: TranscriptSegment,
        at time: TimeInterval,
        isBridgeAllowed: (TimeInterval, TimeInterval) -> Bool
    ) -> TranscriptTimedSpan? {
        guard time.isFinite else { return nil }
        let text = segment.text
        let utf16Count = text.utf16.count
        let wordSpans = segment.timedSpans
            .filter {
                $0.cueLevel != true && $0.location >= 0 && $0.length > 0
                    && $0.location <= utf16Count && $0.length <= utf16Count - $0.location
                    && $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
            }
            .sorted { $0.location < $1.location }
        guard wordSpans.count >= 2 else { return nil }
        for index in 0..<(wordSpans.count - 1) {
            let before = wordSpans[index]
            let after = wordSpans[index + 1]
            guard time >= before.endTime, time < after.startTime else { continue }
            let gap = after.startTime - before.endTime
            let gapStart = before.location + before.length
            guard gap > 0, gap <= maximumGap, gapStart <= after.location,
                  let range = Range(NSRange(location: gapStart, length: after.location - gapStart), in: text) else {
                return nil
            }
            var words = 0
            text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, stop in
                words += 1
                if words > maximumUnmatchedWords { stop = true }
            }
            guard (1...maximumUnmatchedWords).contains(words),
                  isBridgeAllowed(before.endTime, after.startTime) else { return nil }
            return before
        }
        return nil
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
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
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
        let store = TranscriptSynchronizationStore.shared
        let alignment = useAlignment
        let newValue = Self.lookup(segments: segments, at: transcriptTime) { gapStart, gapEnd in
            // Never hold a highlight across an advertising insertion or audio
            // the synchronization could not verify: the audio gap between the
            // neighbours must itself be short and verified.
            guard !store.isUnverifiedAudioTime(audioTime, episodeURL: episodeURL) else { return false }
            guard alignment else { return true }
            guard let audioStart = store.audioTime(forTranscriptTime: gapStart, episodeURL: episodeURL),
                  let audioEnd = store.audioTime(forTranscriptTime: gapEnd, episodeURL: episodeURL),
                  audioEnd >= audioStart,
                  audioEnd - audioStart <= TranscriptHighlightContinuity.maximumGap else { return false }
            return !store.isUnverifiedAudioTime(audioStart, episodeURL: episodeURL)
                && !store.isUnverifiedAudioTime(audioEnd, episodeURL: episodeURL)
        }
        if active != newValue { active = newValue }
    }

    func stop() {
        isRunning = false
        detach()
        if active != nil { active = nil }
    }

    private func detach() {
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        itemObserver?.invalidate()
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        timeObserver = nil
        itemObserver = nil
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
        // The player object is reused when episodes change. Observe its item
        // directly so the transcript updates as soon as the replacement item
        // becomes current, even before the next periodic tick.
        itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        jumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: nil, queue: .main
        ) { [weak self, weak player] notification in
            guard notification.object as? AVPlayerItem === player?.currentItem else { return }
            Task { @MainActor in self?.refresh() }
        }
    }

    /// `isBridgeAllowed` enables `TranscriptHighlightContinuity` for the gap's
    /// transcript-time bounds; without it, gaps between words stay unhighlighted.
    static func lookup(
        segments: [TranscriptSegment],
        at time: TimeInterval,
        isBridgeAllowed: ((TimeInterval, TimeInterval) -> Bool)? = nil
    ) -> Active? {
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
        // Cue-level timing is enough to identify the current caption, but it is
        // not enough to claim that the whole caption is the spoken word. Older
        // publisher and Speech rows predate the explicit cue-level marker, so
        // only `true` means cue-level; nil remains valid word timing.
        var wordSpan = span?.cueLevel == true ? nil : span
        if span == nil, let isBridgeAllowed {
            wordSpan = TranscriptHighlightContinuity.bridgedSpan(in: segment, at: time, isBridgeAllowed: isBridgeAllowed)
        }
        return Active(
            segmentID: segment.id,
            location: wordSpan?.location,
            length: wordSpan?.length
        )
    }
}
