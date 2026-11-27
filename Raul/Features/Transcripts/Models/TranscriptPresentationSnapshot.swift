import Foundation

/// Stored full-episode text. Partial live recognition enters the presentation separately.
struct TranscriptDocumentSnapshot: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case publisher, generated, legacyUnknown
    }

    let episodeID: String
    let source: Source
    /// The same line-based identity used by publisher synchronization and clip export.
    /// Missing identity disables derived timing while leaving the document readable.
    let timingRevision: String?
    let lines: [TranscriptSegmentSource]
    let segments: [TranscriptSegment]
    fileprivate let baseQuality: TranscriptPresentationSnapshot.TimingQuality
    /// Every paragraph consists of consecutive, nonblank source lines.
    fileprivate let paragraphByLine: [UUID: Range<Int>]

    static func resolve(episodeID: String, storedLines: [TranscriptSegmentSource]) -> Self? {
        let usable = storedLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func source(of line: TranscriptSegmentSource) -> Source {
            switch line.sourceRawValue.flatMap(CachedTranscriptSource.init(rawValue:)) {
            case .publisher: .publisher
            case .ai, .localAI: .generated
            case .unknown, nil: .legacyUnknown
            }
        }
        guard !usable.isEmpty else { return nil }
        let selected: Source
        if usable.contains(where: { source(of: $0) == .publisher }) {
            selected = .publisher
        } else if usable.contains(where: { source(of: $0) == .generated }) {
            selected = .generated
        } else {
            selected = .legacyUnknown
        }
        let lines = usable.filter { source(of: $0) == selected }.sorted {
            // Keep the stored order for simultaneous speakers/cues and place invalid times last.
            ($0.startTime.isFinite ? $0.startTime : .infinity) < ($1.startTime.isFinite ? $1.startTime : .infinity)
        }
        let revision = TranscriptSynchronizationRevision.make(candidates: lines.map {
            TranscriptAlignmentCandidate(id: $0.id.uuidString, transcriptTime: $0.startTime, text: $0.text,
                                         source: $0.sourceRawValue.flatMap(CachedTranscriptSource.init(rawValue:)),
                                         endTime: $0.endTime, timedSpans: $0.timedSpans)
        })
        let segments = TranscriptSegmentBuilder.makeSegments(fromSorted: lines, options: .full)
        var paragraphByLine: [UUID: Range<Int>] = [:]
        var offset = 0
        for paragraph in segments {
            let range = offset..<(offset + paragraph.lineIDs.count)
            for id in paragraph.lineIDs { paragraphByLine[id] = range }
            offset = range.upperBound
        }
        return Self(episodeID: episodeID, source: selected, timingRevision: revision, lines: lines,
                    segments: segments, baseQuality: .native(in: segments), paragraphByLine: paragraphByLine)
    }
}

/// Verified timing supplied by an on-device matcher. Ranges refer to the exact, untrimmed
/// publisher line identified by its UUID. Times are on the downloaded audio's clock.
struct PublisherTranscriptTimingEvidence: Sendable {
    let episodeID: String
    let mediaFingerprint: String
    let transcriptRevision: String
    let timeline: TranscriptSynchronizationTimeline?
    let wordsByLine: [UUID: [TranscriptTimedSpan]]
}

struct TranscriptPresentationSnapshot: Equatable, Sendable {
    enum TimingQuality: Equatable, Sendable {
        case nativeWords, enhancedWords, verifiedCues, rawCues, unavailable

        fileprivate static func native(in segments: [TranscriptSegment]) -> Self {
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

    let document: TranscriptDocumentSnapshot?
    let segments: [TranscriptSegment]
    /// The best available precision anywhere in this snapshot. Individual words can have gaps.
    let timingQuality: TimingQuality
    let timeline: TranscriptSynchronizationTimeline?
    /// Audio-clock word spans rebased onto the grouped display text. Native spans in
    /// `segments` stay on the document clock, including when a verified timeline is present.
    let enhancedWordsBySegment: [UUID: [TranscriptTimedSpan]]

    static func resolve(
        document: TranscriptDocumentSnapshot?,
        livePartial: [TranscriptSegmentSource] = [],
        mediaFingerprint: String? = nil,
        evidence: PublisherTranscriptTimingEvidence? = nil
    ) -> Self {
        let segments = document?.segments ?? TranscriptSegmentBuilder.makeSegments(from: livePartial, options: .full)
        var quality = document?.baseQuality ?? .native(in: segments)
        var timeline: TranscriptSynchronizationTimeline?
        var enhancedWords: [UUID: [TranscriptTimedSpan]] = [:]
        if let document, document.source == .publisher, let evidence,
           let mediaFingerprint, !mediaFingerprint.isEmpty, mediaFingerprint == evidence.mediaFingerprint,
           document.episodeID == evidence.episodeID, document.timingRevision == evidence.transcriptRevision {
            timeline = evidence.timeline
            let affected = Set(evidence.wordsByLine.keys.compactMap { document.paragraphByLine[$0] })
            for paragraph in affected {
                // Rebase only the touched paragraphs using the builder's existing trimming rules.
                let mapped = document.lines[paragraph].map { line in
                    let text = line.text as NSString
                    return TranscriptSegmentSource(id: line.id, speaker: line.speaker, text: line.text,
                                            startTime: line.startTime, endTime: line.endTime,
                                            timedSpans: (evidence.wordsByLine[line.id] ?? []).filter {
                                                $0.cueLevel != true && $0.startTime >= 0 &&
                                                Self.isComposedCharacterAligned($0, in: text)
                                            })
                }
                for segment in TranscriptSegmentBuilder.makeSegments(fromSorted: mapped, options: .full) {
                    let words = segment.timedSpans.filter { $0.cueLevel != true }
                    if !words.isEmpty { enhancedWords[segment.id] = words }
                }
            }
        }
        if quality != .nativeWords {
            if !enhancedWords.isEmpty {
                quality = .enhancedWords
            } else if timeline != nil {
                quality = .verifiedCues
            }
        }
        return Self(document: document, segments: segments, timingQuality: quality,
                    timeline: timeline, enhancedWordsBySegment: enhancedWords)
    }

    /// Derived spans must cover whole graphemes. `Range(_:in:)` accepts UTF-16 offsets that
    /// split a surrogate pair or cluster, which would duplicate highlighting inside one emoji.
    private static func isComposedCharacterAligned(_ span: TranscriptTimedSpan, in text: NSString) -> Bool {
        guard span.location >= 0, span.length > 0, span.length <= text.length - min(span.location, text.length) else {
            return false
        }
        let range = NSRange(location: span.location, length: span.length)
        return text.rangeOfComposedCharacterSequences(for: range) == range
    }
}
