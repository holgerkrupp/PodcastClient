//
//  TranscriptSegmentBuilder.swift
//  Raul
//
//  Groups short transcript lines into readable paragraphs.
//

import Foundation

/// A lightweight, storage independent representation of a single transcript line.
///
/// Used as the input of ``TranscriptSegmentBuilder`` so the grouping logic can be
/// exercised without a SwiftData container.
struct TranscriptSegmentSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let speaker: String?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let sourceRawValue: String?
    let timedSpans: [TranscriptTimedSpan]

    init(id: UUID = UUID(), speaker: String? = nil, text: String, startTime: TimeInterval, endTime: TimeInterval? = nil, sourceRawValue: String? = nil, timedSpans: [TranscriptTimedSpan] = []) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.sourceRawValue = sourceRawValue
        self.timedSpans = timedSpans
    }
}

/// Transcript-wide source facts that should be captured once per transcript
/// revision instead of recomputed while SwiftUI renders individual rows.
struct TranscriptSourceMetadata: Equatable, Sendable {
    let usesPublisherAlignment: Bool

    static func make(from lines: [TranscriptLineAndTime]) -> Self {
        Self(usesPublisherAlignment: lines.contains { $0.transcriptSource == .publisher })
    }

    static func make(from sources: [TranscriptSegmentSource]) -> Self {
        Self(usesPublisherAlignment: sources.contains {
            $0.sourceRawValue == CachedTranscriptSource.publisher.rawValue
        })
    }
}

/// The immutable, prepared values needed by transcript views. SwiftUI rows
/// consume this snapshot instead of live SwiftData transcript models.
struct TranscriptPreparedSnapshot: Equatable, Sendable {
    let segments: [TranscriptSegment]
    let sourceMetadata: TranscriptSourceMetadata
    /// The canonical document and independently resolved timing capability used
    /// to prepare these rows. Views keep consuming the lightweight segment list,
    /// while callers that need provenance can inspect the same immutable model.
    let presentation: TranscriptPresentationSnapshot

    /// - Parameter episodeID: `Episode.stableEpisodeIdentity.key`; the canonical
    ///   document carries it so cached publisher word timing can be matched (#492).
    static func make(
        from sources: [TranscriptSegmentSource],
        sourcesAreSorted: Bool = false,
        episodeID: String = ""
    ) -> Self {
        let orderedSources = sourcesAreSorted
            ? sources
            : sources.sorted { $0.startTime < $1.startTime }
        let document = TranscriptDocumentSnapshot.resolve(
            episodeID: episodeID,
            storedLines: orderedSources
        )
        let presentation = TranscriptPresentationSnapshot.resolve(
            document: document,
            livePartial: document == nil ? orderedSources : []
        )
        let selectedSources = document?.lines ?? orderedSources
        return Self(
            segments: presentation.segments,
            sourceMetadata: TranscriptSourceMetadata.make(from: selectedSources),
            presentation: presentation
        )
    }

    /// Whether `other` shows the same canonical rows: identical segment IDs, order,
    /// speakers and text. A timing-only upgrade (cue -> verified alignment -> word
    /// timing) keeps this true, so views update highlighting in place instead of
    /// reloading, and search/copy results stay identical (#487).
    func hasSameDocumentLayout(as other: Self) -> Bool {
        segments.count == other.segments.count
            && zip(segments, other.segments).allSatisfy {
                $0.id == $1.id && $0.speaker == $1.speaker && $0.lineIDs == $1.lineIDs && $0.text == $1.text
            }
    }
}

/// Several consecutive transcript lines of the same speaker, merged into one block of text.
struct TranscriptSegment: Identifiable, Hashable, Sendable {
    /// Identifier of the first line the segment was built from, so segments keep a
    /// stable identity across rebuilds.
    let id: UUID
    let speaker: String?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
    /// Identifiers of every source line contained in this segment.
    let lineIDs: [UUID]
    let timedSpans: [TranscriptTimedSpan]

    /// Returns only spans with valid boundaries and a real time interval.
    func activeSpan(at time: TimeInterval) -> TranscriptTimedSpan? {
        guard time.isFinite else { return nil }
        return timedSpans.first {
            time >= $0.startTime && time < $0.endTime
                && $0.location >= 0 && $0.length > 0
                && $0.location <= text.utf16.count && $0.length <= text.utf16.count - $0.location
                && Range(NSRange(location: $0.location, length: $0.length), in: text) != nil
        }
    }
}

/// Merges the very short lines automatic transcription services produce into
/// paragraphs that are comfortable to read, without letting them grow too long.
enum TranscriptSegmentBuilder {

    struct Options: Hashable, Sendable {
        /// Once a segment is at least this long it ends at the next sentence boundary.
        var softCharacterLimit: Int
        /// A segment never grows beyond this length, even without a sentence boundary.
        var hardCharacterLimit: Int
        /// A segment never spans more than this many seconds of audio.
        var maximumDuration: TimeInterval
        /// A pause longer than this between two lines always starts a new segment.
        var maximumSilence: TimeInterval

        init(
            softCharacterLimit: Int,
            hardCharacterLimit: Int,
            maximumDuration: TimeInterval,
            maximumSilence: TimeInterval
        ) {
            self.softCharacterLimit = softCharacterLimit
            self.hardCharacterLimit = hardCharacterLimit
            self.maximumDuration = maximumDuration
            self.maximumSilence = maximumSilence
        }

        /// Tuned for the small transcript card inside the player.
        static let compact = Options(
            softCharacterLimit: 90,
            hardCharacterLimit: 180,
            maximumDuration: 20,
            maximumSilence: 2.0
        )

        /// Tuned for the full screen transcript list.
        static let full = Options(
            softCharacterLimit: 180,
            hardCharacterLimit: 360,
            maximumDuration: 45,
            maximumSilence: 2.5
        )
    }

    static func makeSegments(from lines: [TranscriptLineAndTime], options: Options) -> [TranscriptSegment] {
        makeSegments(
            from: lines.map {
                TranscriptSegmentSource(
                    id: $0.id,
                    speaker: $0.speaker,
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    sourceRawValue: $0.sourceRawValue,
                    timedSpans: $0.timedSpans
                )
            },
            options: options
        )
    }

    static func makeSegments(from lines: [TranscriptSegmentSource], options: Options) -> [TranscriptSegment] {
        makeSegments(fromSorted: lines.sorted { $0.startTime < $1.startTime }, options: options)
    }

    static func makeSegments(fromSorted lines: [TranscriptSegmentSource], options: Options) -> [TranscriptSegment] {
        makeIndexedSegments(fromSorted: lines, startingAt: 0, options: options).map(\.segment)
    }

    /// Groups `lines[startIndex...]` and reports, for every segment, the index in
    /// `lines` of its first source line. Grouping is greedy and left to right, so a
    /// suffix can be regrouped from any segment start without touching earlier
    /// segments (see ``InlineSegmentAccumulator``).
    static func makeIndexedSegments(
        fromSorted lines: [TranscriptSegmentSource],
        startingAt startIndex: Int,
        options: Options
    ) -> [(segment: TranscriptSegment, sourceIndex: Int)] {
        guard startIndex < lines.count else { return [] }

        var segments: [(segment: TranscriptSegment, sourceIndex: Int)] = []
        var builder: PartialSegment?
        var builderStart = startIndex

        for index in startIndex..<lines.count {
            let line = lines[index]
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }

            if var current = builder, current.canAppend(line, text: text, options: options) {
                current.append(line, text: text)
                builder = current
            } else {
                if let finished = builder?.finalized() {
                    segments.append((finished, builderStart))
                }
                builder = PartialSegment(line: line, text: text)
                builderStart = index
            }
        }

        if let finished = builder?.finalized() {
            segments.append((finished, builderStart))
        }

        return segments
    }

    private struct PartialSegment {
        let speaker: String?
        let startTime: TimeInterval
        private(set) var endTime: TimeInterval?
        private(set) var text: String
        private(set) var lineIDs: [UUID]
        private(set) var timedSpans: [TranscriptTimedSpan]
        private let firstLineID: UUID

        init(line: TranscriptSegmentSource, text: String) {
            self.speaker = line.speaker
            self.startTime = line.startTime
            self.endTime = line.endTime
            self.text = text
            self.lineIDs = [line.id]
            self.timedSpans = Self.displaySpans(for: line, trimmedText: text, offset: 0)
            self.firstLineID = line.id
        }

        func canAppend(_ line: TranscriptSegmentSource, text: String, options: Options) -> Bool {
            guard line.speaker == speaker else { return false }

            // A longer pause reads as a new thought.
            let previousEnd = endTime ?? line.startTime
            if line.startTime - previousEnd > options.maximumSilence { return false }

            // Keep segments short enough to stay readable in a small card.
            let combinedLength = self.text.count + 1 + text.count
            if combinedLength > options.hardCharacterLimit { return false }

            let combinedEnd = line.endTime ?? line.startTime
            if combinedEnd - startTime > options.maximumDuration { return false }

            // Prefer to break at a sentence boundary once the segment is long enough.
            if self.text.count >= options.softCharacterLimit, TranscriptSegmentBuilder.endsSentence(self.text) {
                return false
            }

            return true
        }

        mutating func append(_ line: TranscriptSegmentSource, text: String) {
            let offset = self.text.utf16.count + 1
            self.text += " " + text
            self.timedSpans += Self.displaySpans(for: line, trimmedText: text, offset: offset)
            self.endTime = line.endTime ?? self.endTime
            self.lineIDs.append(line.id)
        }

        func finalized() -> TranscriptSegment {
            TranscriptSegment(
                id: firstLineID,
                speaker: speaker,
                text: text,
                startTime: startTime,
                endTime: endTime,
                lineIDs: lineIDs,
                timedSpans: timedSpans
            )
        }

        private static func displaySpans(for line: TranscriptSegmentSource, trimmedText: String, offset: Int) -> [TranscriptTimedSpan] {
            let source = line.text as NSString
            let trimmedRange = source.range(of: trimmedText)
            guard trimmedRange.location != NSNotFound else { return [] }
            let valid = line.timedSpans.compactMap { span -> TranscriptTimedSpan? in
                guard span.location >= 0, span.length > 0,
                      span.startTime.isFinite, span.endTime.isFinite, span.endTime > span.startTime,
                      span.location <= source.length, span.length <= source.length - span.location,
                      Range(NSRange(location: span.location, length: span.length), in: line.text) != nil,
                      // A range that splits a surrogate pair or other composed
                      // character still bridges to Swift; never draw half an emoji.
                      source.rangeOfComposedCharacterSequences(for: NSRange(location: span.location, length: span.length))
                        == NSRange(location: span.location, length: span.length) else { return nil }
                let intersection = NSIntersectionRange(NSRange(location: span.location, length: span.length), trimmedRange)
                guard intersection.length > 0,
                      Range(intersection, in: line.text) != nil else { return nil }
                return TranscriptTimedSpan(location: offset + intersection.location - trimmedRange.location,
                                           length: intersection.length, startTime: span.startTime, endTime: span.endTime,
                                           cueLevel: span.cueLevel)
            }
            if !valid.isEmpty { return valid }
            guard let end = line.endTime, line.startTime.isFinite, end.isFinite, end > line.startTime else { return [] }
            return [TranscriptTimedSpan(location: offset, length: trimmedText.utf16.count, startTime: line.startTime, endTime: end, cueLevel: true)]
        }
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "»", "”", "’", "“"]

    /// Whether the given text ends on a sentence boundary, ignoring trailing quotes and brackets.
    static func endsSentence(_ text: String) -> Bool {
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))

        while let last = characters.last, closingCharacters.contains(last) {
            characters.removeLast()
        }

        guard let last = characters.last else { return false }
        return sentenceTerminators.contains(last)
    }
}

/// Keeps compact segments for a growing, start-sorted source list (#520).
///
/// Live recognition appends cues and revises only the trailing window. Instead
/// of regrouping the whole transcript for every cue, the accumulator finds the
/// first changed source, keeps every segment that was closed before it and
/// regroups only from the segment that contained the last unchanged source.
/// The result is always identical to
/// `TranscriptSegmentBuilder.makeSegments(fromSorted:options:)`.
struct InlineSegmentAccumulator: Sendable {
    struct Update: Equatable, Sendable {
        /// Leading segments carried over unchanged (same values and IDs).
        let reusedSegments: Int
        /// Segments regrouped by this update.
        let rebuiltSegments: Int
        let changed: Bool
    }

    let options: TranscriptSegmentBuilder.Options
    private(set) var sources: [TranscriptSegmentSource] = []
    private(set) var segments: [TranscriptSegment] = []
    /// Sorted speaker names, used for stable speaker colours.
    private(set) var speakers: [String] = []
    private var segmentSourceStarts: [Int] = []
    private var speakerCounts: [String: Int] = [:]

    init(options: TranscriptSegmentBuilder.Options = .compact) {
        self.options = options
    }

    @discardableResult
    mutating func update(with newSources: [TranscriptSegmentSource]) -> Update {
        // Value comparison is cheap here: unchanged cues share string and
        // array storage, so equality takes the identity fast path.
        let common = min(sources.count, newSources.count)
        var firstChange = 0
        while firstChange < common && sources[firstChange] == newSources[firstChange] {
            firstChange += 1
        }
        if firstChange == sources.count && firstChange == newSources.count {
            return Update(reusedSegments: segments.count, rebuiltSegments: 0, changed: false)
        }

        // The segment holding the last unchanged source may still grow; every
        // earlier segment was closed by an unchanged source and is final.
        var keep = 0
        var restart = 0
        if firstChange > 0, let holder = Self.lastIndex(in: segmentSourceStarts, notAfter: firstChange - 1) {
            keep = holder
            restart = segmentSourceStarts[holder]
        }

        for segment in segments[keep...] {
            if let speaker = segment.speaker { adjustSpeaker(speaker, by: -1) }
        }
        segments.removeSubrange(keep...)
        segmentSourceStarts.removeSubrange(keep...)

        let tail = TranscriptSegmentBuilder.makeIndexedSegments(
            fromSorted: newSources,
            startingAt: restart,
            options: options
        )
        segments.reserveCapacity(keep + tail.count)
        for entry in tail {
            segments.append(entry.segment)
            segmentSourceStarts.append(entry.sourceIndex)
            if let speaker = entry.segment.speaker { adjustSpeaker(speaker, by: 1) }
        }
        sources = newSources
        return Update(reusedSegments: keep, rebuiltSegments: tail.count, changed: true)
    }

    private mutating func adjustSpeaker(_ speaker: String, by delta: Int) {
        let count = (speakerCounts[speaker] ?? 0) + delta
        if count <= 0 {
            speakerCounts.removeValue(forKey: speaker)
            speakers.removeAll { $0 == speaker }
        } else {
            if speakerCounts[speaker] == nil {
                let index = speakers.firstIndex { $0 > speaker } ?? speakers.endIndex
                speakers.insert(speaker, at: index)
            }
            speakerCounts[speaker] = count
        }
    }

    /// Largest index whose value is <= `limit` in an ascending array.
    private static func lastIndex(in values: [Int], notAfter limit: Int) -> Int? {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= limit { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

extension TranscriptPreparedSnapshot {
    /// Whether `self` continues `older`'s rows: the same layout, or an update
    /// that keeps the first row and only appends or revises later rows (a live
    /// or partial transcript growing). Views keep their rows, scroll position,
    /// search and Follow state instead of showing a loading state.
    func continuesDocumentLayout(of older: Self) -> Bool {
        if hasSameDocumentLayout(as: older) { return true }
        guard let first = segments.first, let olderFirst = older.segments.first else { return false }
        // The first row may still grow while the transcript is short.
        return first.id == olderFirst.id && first.speaker == olderFirst.speaker
    }
}

/// Keeps a full-transcript ``TranscriptPreparedSnapshot`` for a growing,
/// start-sorted live or saved-partial source list.
///
/// A full rebuild re-sorts, regroups and hashes every line for each new cue.
/// This regroups only the changed tail through ``InlineSegmentAccumulator``
/// (with `.full` options), so earlier segments keep identical IDs and values.
/// The resulting `segments`, `sourceMetadata` and `presentation.timingQuality`
/// equal `TranscriptPreparedSnapshot.make(from:sourcesAreSorted:)`; the
/// presentation carries no stored-document provenance (`document == nil`),
/// which partial transcripts never use. Inputs the document path would filter
/// or reorder (mixed sources, unsorted or non-finite starts) fall back to a
/// full rebuild.
struct PartialTranscriptSnapshotAccumulator: Sendable {
    private var accumulator = InlineSegmentAccumulator(options: .full)
    private(set) var snapshot: TranscriptPreparedSnapshot?
    /// What the most recent incremental update reused; nil after a fallback.
    private(set) var lastUpdate: InlineSegmentAccumulator.Update?

    @discardableResult
    mutating func update(with sources: [TranscriptSegmentSource]) -> TranscriptPreparedSnapshot {
        guard Self.supportsIncrementalUpdate(sources) else {
            accumulator = InlineSegmentAccumulator(options: .full)
            lastUpdate = nil
            // The cache mirrors the (now reset) incremental accumulator only, so
            // an unchanged incremental update can never return this rebuild.
            snapshot = nil
            return TranscriptPreparedSnapshot.make(from: sources, sourcesAreSorted: true)
        }
        let update = accumulator.update(with: sources)
        lastUpdate = update
        if !update.changed, let snapshot { return snapshot }
        let segments = accumulator.segments
        let publisher = sources.first?.sourceRawValue == CachedTranscriptSource.publisher.rawValue
        let prepared = TranscriptPreparedSnapshot(
            segments: segments,
            sourceMetadata: TranscriptSourceMetadata(usesPublisherAlignment: publisher),
            presentation: TranscriptPresentationSnapshot(
                document: nil,
                segments: segments,
                timingQuality: Self.nativeTimingQuality(in: segments),
                timeline: nil,
                enhancedWordsBySegment: [:]
            )
        )
        snapshot = prepared
        return prepared
    }

    /// Sorted by finite start and one document source class, so the document
    /// path would select every nonblank line in the given order.
    static func supportsIncrementalUpdate(_ sources: [TranscriptSegmentSource]) -> Bool {
        guard let first = sources.first else { return true }
        let sourceClass = documentSourceClass(first.sourceRawValue)
        var previousStart = -TimeInterval.infinity
        for source in sources {
            guard source.startTime.isFinite, source.startTime >= previousStart,
                  documentSourceClass(source.sourceRawValue) == sourceClass else { return false }
            previousStart = source.startTime
        }
        return true
    }

    private static func documentSourceClass(_ rawValue: String?) -> Int {
        switch rawValue.flatMap(CachedTranscriptSource.init(rawValue:)) {
        case .publisher: 0
        case .ai, .localAI: 1
        case .unknown, nil: 2
        }
    }

    /// Mirrors `TranscriptPresentationSnapshot.TimingQuality.native(in:)`;
    /// the equivalence tests guard against drift.
    private static func nativeTimingQuality(in segments: [TranscriptSegment]) -> TranscriptPresentationSnapshot.TimingQuality {
        if segments.contains(where: { $0.timedSpans.contains { $0.cueLevel != true && $0.startTime >= 0 } }) {
            return .nativeWords
        }
        if segments.contains(where: {
            $0.startTime.isFinite && $0.startTime >= 0 &&
            ($0.startTime > 0 || ($0.endTime.map { $0.isFinite && $0 > 0 } ?? false) ||
             $0.timedSpans.contains { $0.startTime >= 0 })
        }) {
            return .rawCues
        }
        return .unavailable
    }
}

/// Supersedes asynchronous preparation runs: only the most recently begun run
/// may publish its result.
struct TranscriptPreparationGeneration: Sendable {
    private(set) var current = 0

    mutating func begin() -> Int {
        current &+= 1
        return current
    }

    func isCurrent(_ token: Int) -> Bool { token == current }
}
