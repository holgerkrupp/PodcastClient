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

    static func make(
        from sources: [TranscriptSegmentSource],
        sourcesAreSorted: Bool = false
    ) -> Self {
        let orderedSources = sourcesAreSorted
            ? sources
            : sources.sorted { $0.startTime < $1.startTime }
        return Self(
            segments: TranscriptSegmentBuilder.makeSegments(fromSorted: orderedSources, options: .full),
            sourceMetadata: TranscriptSourceMetadata.make(from: orderedSources)
        )
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
        let sourceLines = lines
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        guard sourceLines.isEmpty == false else { return [] }

        var segments: [TranscriptSegment] = []
        var builder: PartialSegment?

        for line in sourceLines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if var current = builder, current.canAppend(line, text: text, options: options) {
                current.append(line, text: text)
                builder = current
            } else {
                if let finished = builder?.finalized() {
                    segments.append(finished)
                }
                builder = PartialSegment(line: line, text: text)
            }
        }

        if let finished = builder?.finalized() {
            segments.append(finished)
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
                      Range(NSRange(location: span.location, length: span.length), in: line.text) != nil else { return nil }
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
