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
        return bridgedSpan(
            text: segment.text,
            sortedWordSpans: validWordSpans(segment.timedSpans, in: segment.text),
            at: time,
            isBridgeAllowed: isBridgeAllowed
        )
    }

    /// Word spans with valid UTF-16 bounds and a real interval, sorted by text
    /// location. Cue-level spans never count as words.
    static func validWordSpans(_ spans: [TranscriptTimedSpan], in text: String) -> [TranscriptTimedSpan] {
        let utf16Count = text.utf16.count
        return spans
            .filter {
                $0.cueLevel != true && $0.location >= 0 && $0.length > 0
                    && $0.location <= utf16Count && $0.length <= utf16Count - $0.location
                    && $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
            }
            .sorted { $0.location < $1.location }
    }

    /// Clock-agnostic core: `time` and the gap bounds handed to
    /// `isBridgeAllowed` are on whatever clock `sortedWordSpans` use.
    /// `sortedWordSpans` must already be validated and sorted by location.
    static func bridgedSpan(
        text: String,
        sortedWordSpans wordSpans: [TranscriptTimedSpan],
        at time: TimeInterval,
        isBridgeAllowed: (TimeInterval, TimeInterval) -> Bool
    ) -> TranscriptTimedSpan? {
        guard time.isFinite, wordSpans.count >= 2 else { return nil }
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
        /// Which timing produced the word highlight: `.nativeWords` for
        /// publisher word spans, `.enhancedWords` for verified audio-clock
        /// words; nil when only the caption is active.
        var quality: TranscriptPresentationSnapshot.TimingQuality? = nil

        /// Equality is what is highlighted, not which timing produced it, so a
        /// timing upgrade of the same word never re-renders the row.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.segmentID == rhs.segmentID && lhs.location == rhs.location && lhs.length == rhs.length
        }
    }

    /// Verified audio-clock words, precomputed once per update so a playback
    /// tick is a binary search plus a segment-local scan.
    struct EnhancedWordIndex: Sendable {
        struct Word: Sendable {
            let segmentID: UUID
            /// Position of the owning segment in the segments the index was built for.
            let segmentIndex: Int
            let span: TranscriptTimedSpan
        }

        static let empty = EnhancedWordIndex()

        /// Every valid word, sorted by audio start time.
        let wordsByStart: [Word]
        /// Valid words per segment position, sorted by UTF-16 location.
        let wordsBySegment: [Int: [TranscriptTimedSpan]]

        var isEmpty: Bool { wordsByStart.isEmpty }

        private init() {
            wordsByStart = []
            wordsBySegment = [:]
        }

        /// `words` are keyed by displayed segment ID with UTF-16 locations in
        /// that segment's text. Words for unknown segments or with invalid
        /// bounds are dropped.
        init(_ words: [UUID: [TranscriptTimedSpan]], segments: [TranscriptSegment]) {
            guard !words.isEmpty else {
                wordsByStart = []
                wordsBySegment = [:]
                return
            }
            var all: [Word] = []
            var bySegment: [Int: [TranscriptTimedSpan]] = [:]
            for (index, segment) in segments.enumerated() {
                guard let spans = words[segment.id], !spans.isEmpty else { continue }
                let valid = TranscriptHighlightContinuity.validWordSpans(spans, in: segment.text)
                    .filter { $0.startTime >= 0 && Range(NSRange(location: $0.location, length: $0.length), in: segment.text) != nil }
                guard !valid.isEmpty else { continue }
                bySegment[index] = valid
                all.append(contentsOf: valid.map { Word(segmentID: segment.id, segmentIndex: index, span: $0) })
            }
            wordsByStart = all.sorted {
                $0.span.startTime != $1.span.startTime
                    ? $0.span.startTime < $1.span.startTime
                    : $0.segmentIndex < $1.segmentIndex
            }
            wordsBySegment = bySegment
        }

        /// Number of words starting at or before `time`.
        func insertionIndex(for time: TimeInterval) -> Int {
            var low = 0
            var high = wordsByStart.count
            while low < high {
                let mid = (low + high) / 2
                if wordsByStart[mid].span.startTime <= time { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }

    private(set) var active: Active?
    @ObservationIgnored private var enhancedWords: [UUID: [TranscriptTimedSpan]] = [:]
    @ObservationIgnored private var enhancedIndex = EnhancedWordIndex.empty
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
        rebuildEnhancedIndex()
        attachIfNeeded()
        refresh()
    }

    func update(segments: [TranscriptSegment], episodeURL: URL?, useAlignment: Bool) {
        self.segments = segments
        self.episodeURL = episodeURL
        self.useAlignment = useAlignment
        rebuildEnhancedIndex()
        attachIfNeeded()
        refresh()
    }

    /// Replaces the verified audio-clock words, keyed by displayed segment ID
    /// (UTF-16 locations within that segment's text). Empty clears them.
    /// Follow state is untouched; only the highlight is refreshed.
    func updateEnhancedWords(_ words: [UUID: [TranscriptTimedSpan]]) {
        enhancedWords = words
        rebuildEnhancedIndex()
        refresh()
    }

    private func rebuildEnhancedIndex() {
        enhancedIndex = enhancedWords.isEmpty ? .empty : EnhancedWordIndex(enhancedWords, segments: segments)
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
        let store = TranscriptSynchronizationStore.shared
        // Only the transcript clock is converted. Enhanced words are already on
        // the audio clock and are matched against `audioTime` directly.
        let transcriptTime = useAlignment
            ? store.transcriptTime(forAudioTime: audioTime, episodeURL: episodeURL)
            : audioTime
        let hasTranscriptTime = transcriptTime?.isFinite == true
        guard hasTranscriptTime || (!enhancedIndex.isEmpty && audioTime.isFinite) else {
            if active != nil { active = nil }
            return
        }
        let alignment = useAlignment
        let newValue = Self.lookup(
            segments: segments,
            at: transcriptTime ?? .nan,
            audioTime: audioTime,
            enhancedWords: enhancedIndex,
            isAudioVerified: { !store.isUnverifiedAudioTime($0, episodeURL: episodeURL) }
        ) { gapStart, gapEnd in
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
        lookup(segments: segments, at: time, audioTime: nil, enhancedWords: .empty, isBridgeAllowed: isBridgeAllowed)
    }

    /// Resolves the highlight from two clocks without converting either twice.
    /// `transcriptTime` drives segment bounds and native publisher word spans;
    /// `audioTime` is the raw player time and only ever matches `enhancedWords`,
    /// which are already on the audio clock.
    ///
    /// Precedence: an active native word, then an enhanced word containing
    /// `audioTime`, then continuity bridges, then the caption alone. An enhanced
    /// word in a different segment than the transcript-time one is used only
    /// while `isAudioVerified(audioTime)`. `isBridgeAllowed` enables continuity
    /// (transcript-time bounds for native gaps); enhanced gaps additionally
    /// require every audio-clock bound to be verified.
    static func lookup(
        segments: [TranscriptSegment],
        at transcriptTime: TimeInterval,
        audioTime: TimeInterval?,
        enhancedWords: EnhancedWordIndex,
        isAudioVerified: (TimeInterval) -> Bool = { _ in true },
        isBridgeAllowed: ((TimeInterval, TimeInterval) -> Bool)? = nil
    ) -> Active? {
        let transcriptSegment = segment(in: segments, containing: transcriptTime)

        let nativeSpan = transcriptSegment?.activeSpan(at: transcriptTime)
        if let transcriptSegment, let span = nativeSpan {
            // Cue-level timing identifies the caption, not the spoken word.
            // Older rows predate the marker, so only `true` means cue-level.
            if span.cueLevel != true {
                return Active(segmentID: transcriptSegment.id, location: span.location, length: span.length, quality: .nativeWords)
            }
        }

        let audio = audioTime.flatMap { $0.isFinite ? $0 : nil }
        let canUseEnhanced = audio != nil && !enhancedWords.isEmpty
        // Moving to a segment the transcript clock does not place us in is only
        // trustworthy while the audio itself is verified.
        func mayUse(_ segmentID: UUID, at audio: TimeInterval) -> Bool {
            segmentID == transcriptSegment?.id || isAudioVerified(audio)
        }

        if canUseEnhanced, let audio,
           let word = enhancedWord(in: enhancedWords, segments: segments, at: audio, preferring: transcriptSegment?.id),
           mayUse(word.segmentID, at: audio) {
            return Active(segmentID: word.segmentID, location: word.span.location, length: word.span.length, quality: .enhancedWords)
        }

        if let isBridgeAllowed {
            if let transcriptSegment, nativeSpan == nil,
               let bridged = TranscriptHighlightContinuity.bridgedSpan(in: transcriptSegment, at: transcriptTime, isBridgeAllowed: isBridgeAllowed) {
                return Active(segmentID: transcriptSegment.id, location: bridged.location, length: bridged.length, quality: .nativeWords)
            }
            if canUseEnhanced, let audio, isAudioVerified(audio),
               let (segmentID, bridged) = enhancedBridge(in: enhancedWords, segments: segments, at: audio, isAudioVerified: isAudioVerified),
               mayUse(segmentID, at: audio) {
                return Active(segmentID: segmentID, location: bridged.location, length: bridged.length, quality: .enhancedWords)
            }
        }

        guard let transcriptSegment else { return nil }
        return Active(segmentID: transcriptSegment.id, location: nil, length: nil)
    }

    private static func segment(in segments: [TranscriptSegment], containing time: TimeInterval) -> TranscriptSegment? {
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
        return time < end ? segment : nil
    }

    private static func isCurrent(_ word: EnhancedWordIndex.Word, in segments: [TranscriptSegment]) -> Bool {
        word.segmentIndex < segments.count && segments[word.segmentIndex].id == word.segmentID
    }

    /// The enhanced word containing `audio`. Words rarely overlap, so only the
    /// few latest-starting candidates are checked.
    private static func enhancedWord(
        in index: EnhancedWordIndex,
        segments: [TranscriptSegment],
        at audio: TimeInterval,
        preferring segmentID: UUID?
    ) -> EnhancedWordIndex.Word? {
        var position = index.insertionIndex(for: audio)
        var first: EnhancedWordIndex.Word?
        var checked = 0
        while position > 0, checked < 4 {
            position -= 1
            checked += 1
            let word = index.wordsByStart[position]
            guard audio < word.span.endTime, isCurrent(word, in: segments) else { continue }
            if word.segmentID == segmentID { return word }
            if first == nil { first = word }
        }
        return first
    }

    /// #489 continuity on the audio clock: holds the earlier enhanced word
    /// across 1–2 unmatched words when the whole gap is short and verified.
    private static func enhancedBridge(
        in index: EnhancedWordIndex,
        segments: [TranscriptSegment],
        at audio: TimeInterval,
        isAudioVerified: (TimeInterval) -> Bool
    ) -> (UUID, TranscriptTimedSpan)? {
        let position = index.insertionIndex(for: audio)
        guard position > 0 else { return nil }
        let previous = index.wordsByStart[position - 1]
        guard audio >= previous.span.endTime, isCurrent(previous, in: segments),
              let words = index.wordsBySegment[previous.segmentIndex] else { return nil }
        let bridged = TranscriptHighlightContinuity.bridgedSpan(
            text: segments[previous.segmentIndex].text,
            sortedWordSpans: words,
            at: audio
        ) { gapStart, gapEnd in
            isAudioVerified(gapStart) && isAudioVerified(gapEnd)
        }
        return bridged.map { (previous.segmentID, $0) }
    }
}
