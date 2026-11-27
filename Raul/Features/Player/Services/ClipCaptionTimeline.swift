import Foundation
import SwiftData

struct ClipTranscriptSnapshot: Sendable {
    enum Origin: Sendable {
        case generated(mediaFingerprint: String)
        case publisher(revision: String)
    }
    let episodeID: String
    let origin: Origin
    let lines: [TranscriptSegmentSource]
    var coverage: [LiveTranscriptState.Coverage]? = nil
}

/// A caption timeline resolved once before preview/export, in source-media time.
/// Preview and export use the same half-open caption intervals.
struct ClipCaptionTimeline: Sendable, Equatable {
    struct Caption: Sendable, Equatable {
        let text: String
        let location: Int
        let length: Int
        let start: TimeInterval
        let end: TimeInterval
        let cueLevel: Bool
        var speaker: String? = nil

        /// Keeps the active timed span in a short, sentence-aware subtitle
        /// window. The caller derives this budget from the output aspect ratio
        /// and font size, so preview and export use the same words.
        func contextualized(maximumUTF16Length: Int) -> Caption {
            let source = text as NSString
            guard maximumUTF16Length > 0, location >= 0, length > 0,
                  location <= source.length, length <= source.length - location,
                  let sentenceExpression = try? NSRegularExpression(pattern: #"[.!?…。、！？][”’\"')\]]*"#),
                  let wordExpression = try? NSRegularExpression(pattern: #"\S+"#) else { return self }

            let activeEnd = location + length
            let sentenceMatches = sentenceExpression.matches(in: text, range: NSRange(location: 0, length: source.length))
            var sentenceStart = 0
            var sentenceEnd = source.length
            for match in sentenceMatches {
                let end = NSMaxRange(match.range)
                if end <= location { sentenceStart = end }
                else if match.range.location >= activeEnd {
                    sentenceEnd = end
                    break
                }
            }
            while sentenceStart < sentenceEnd,
                  let scalar = UnicodeScalar(source.character(at: sentenceStart)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                sentenceStart += 1
            }
            while sentenceEnd > sentenceStart,
                  let scalar = UnicodeScalar(source.character(at: sentenceEnd - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                sentenceEnd -= 1
            }
            guard sentenceStart < sentenceEnd else { return self }

            let sentenceRange = NSRange(location: sentenceStart, length: sentenceEnd - sentenceStart)
            let words = wordExpression.matches(in: text, range: sentenceRange).map(\.range)
            guard let firstActive = words.firstIndex(where: { NSIntersectionRange($0, NSRange(location: location, length: length)).length > 0 }),
                  let lastActive = words.lastIndex(where: { NSIntersectionRange($0, NSRange(location: location, length: length)).length > 0 }) else {
                return self
            }

            var lowerIndex = 0
            var upperIndex = words.count - 1
            let isCropped = sentenceRange.length > maximumUTF16Length
            let selectionBudget = max(1, maximumUTF16Length - 4)
            if isCropped {
                lowerIndex = firstActive
                upperIndex = lastActive
                while true {
                    let currentStart = words[lowerIndex].location
                    let currentEnd = NSMaxRange(words[upperIndex])
                    let currentLeftContext = location - currentStart
                    let currentRightContext = currentEnd - activeEnd
                    let leftCandidate = lowerIndex > 0 ? words[lowerIndex - 1].location : nil
                    let rightCandidate = upperIndex + 1 < words.count ? NSMaxRange(words[upperIndex + 1]) : nil
                    let canAddLeft = leftCandidate.map { currentEnd - $0 <= selectionBudget } ?? false
                    let canAddRight = rightCandidate.map { $0 - currentStart <= selectionBudget } ?? false
                    guard canAddLeft || canAddRight else { break }
                    if canAddLeft && canAddRight {
                        let leftBalance = abs((currentLeftContext + currentStart - (leftCandidate ?? currentStart)) - currentRightContext)
                        let rightBalance = abs(currentLeftContext - (currentRightContext + (rightCandidate ?? currentEnd) - currentEnd))
                        if leftBalance <= rightBalance { lowerIndex -= 1 } else { upperIndex += 1 }
                    } else if canAddLeft {
                        lowerIndex -= 1
                    } else {
                        upperIndex += 1
                    }
                }
            }

            // Timed runs can include whitespace around the active word. Keep
            // their exact UTF-16 span inside the selected window so converting
            // it to a display range can never produce a negative offset.
            let selectedStart = min(words[lowerIndex].location, location)
            let selectedEnd = max(NSMaxRange(words[upperIndex]), activeEnd)
            let prefix = isCropped && selectedStart > sentenceStart ? "… " : ""
            let suffix = isCropped && selectedEnd < sentenceEnd ? " …" : ""
            let selected = prefix + source.substring(with: NSRange(location: selectedStart, length: selectedEnd - selectedStart)) + suffix
            let activeLocation = prefix.utf16.count + location - selectedStart
            guard activeLocation >= 0, activeLocation <= selected.utf16.count,
                  length <= selected.utf16.count - activeLocation else { return self }
            let result = Caption(text: selected, location: activeLocation, length: length,
                                 start: start, end: end, cueLevel: cueLevel, speaker: speaker)
            return result.withLogicalLineBreak(maximumUTF16Length: maximumUTF16Length)
        }

        private func withLogicalLineBreak(maximumUTF16Length: Int) -> Caption {
            guard text.utf16.count > max(24, maximumUTF16Length / 2),
                  let expression = try? NSRegularExpression(pattern: #"[,;:—–-][ \t]+"#) else { return self }
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let candidates = expression.matches(in: text, range: fullRange).filter { match in
                let midpoint = Double(match.range.location) / Double(max(fullRange.length, 1))
                let intersectsActive = NSIntersectionRange(match.range, NSRange(location: location, length: length)).length > 0
                return (0.30...0.70).contains(midpoint) && !intersectsActive
            }
            guard let split = candidates.min(by: {
                abs(Double($0.range.location) / Double(max(fullRange.length, 1)) - 0.5)
                    < abs(Double($1.range.location) / Double(max(fullRange.length, 1)) - 0.5)
            }) else { return self }
            let before = (text as NSString).substring(to: split.range.location + 1)
            let after = (text as NSString).substring(from: NSMaxRange(split.range)).trimmingCharacters(in: .whitespaces)
            let lineBroken = before + "\n" + after
            let removedWhitespace = split.range.length - 1
            let adjustedLocation = location > split.range.location ? location - removedWhitespace + 1 : location
            return Caption(text: lineBroken, location: adjustedLocation, length: length,
                           start: start, end: end, cueLevel: cueLevel, speaker: speaker)
        }
    }

    let captions: [Caption]
    var coverage: [LiveTranscriptState.Coverage]? = nil

    static func resolve(snapshot: ClipTranscriptSnapshot, mediaFingerprint: String,
                        publisherAlignment: TranscriptSynchronizationTimeline?) -> ClipCaptionTimeline? {
        let needsAlignment: Bool
        switch snapshot.origin {
        case .generated(let expected):
            guard expected == mediaFingerprint else { return nil }
            needsAlignment = false
        case .publisher:
            needsAlignment = publisherAlignment != nil
        }
        let segments = TranscriptSegmentBuilder.makeSegments(from: snapshot.lines, options: .compact)
        guard var timeline = resolve(segments: segments, publisherAlignmentRequired: needsAlignment, alignment: publisherAlignment) else { return nil }
        if case .publisher = snapshot.origin, publisherAlignment == nil {
            return Self(captions: timeline.captions.filter { !$0.cueLevel })
        }
        timeline.coverage = snapshot.coverage
        return timeline
    }

    static func resolve(
        segments: [TranscriptSegment],
        publisherAlignmentRequired: Bool,
        alignment: TranscriptSynchronizationTimeline?
    ) -> ClipCaptionTimeline? {
        guard !publisherAlignmentRequired || alignment != nil else { return nil }
        let mapping = publisherAlignmentRequired ? alignment : nil
        var captions: [Caption] = []
        for segment in segments {
            for span in segment.timedSpans {
                guard span.startTime.isFinite, span.endTime.isFinite, span.startTime >= 0,
                      span.endTime > span.startTime, span.location >= 0, span.length > 0,
                      span.startTime >= segment.startTime,
                      segment.endTime.map({ span.endTime <= $0 }) ?? true,
                      span.location <= segment.text.utf16.count,
                      span.length <= segment.text.utf16.count - span.location,
                      Range(NSRange(location: span.location, length: span.length), in: segment.text) != nil else { continue }
                let lower = max(span.startTime, mapping?.anchors.first?.transcriptTime ?? span.startTime)
                let upper = min(span.endTime, mapping?.anchors.last?.transcriptTime ?? span.endTime)
                guard upper > lower else { continue }
                var pieces: [(TimeInterval, TimeInterval)] = [(lower, upper)]
                for gap in mapping?.gaps ?? [] {
                    let gapEnd = gap.transcriptEnd ?? gap.transcriptTime
                    pieces = pieces.flatMap { start, end -> [(TimeInterval, TimeInterval)] in
                        guard start < gapEnd && end > gap.transcriptTime else { return [(start, end)] }
                        var result: [(TimeInterval, TimeInterval)] = []
                        if start < gap.transcriptTime { result.append((start, min(end, gap.transcriptTime))) }
                        if end > gapEnd { result.append((max(start, gapEnd), end)) }
                        return result
                    }
                }
                for (start, end) in pieces {
                    let audioStart: TimeInterval
                    if let mapping {
                        guard let mapped = mapping.audioTime(forTranscriptTime: start) else { continue }
                        audioStart = mapped
                    } else { audioStart = start }
                    // End at the near side of a gap; start at its far side.
                    let audioEnd: TimeInterval
                    if let mapping {
                        guard let mapped = mapping.gaps.first(where: { $0.transcriptTime == end })?.audioStart
                            ?? mapping.audioTime(forTranscriptTime: end) else { continue }
                        audioEnd = mapped
                    } else { audioEnd = end }
                    guard audioStart.isFinite, audioEnd.isFinite, audioStart >= 0, audioEnd > audioStart else { continue }
                    captions.append(Caption(text: segment.text, location: span.location, length: span.length,
                                            start: audioStart, end: audioEnd, cueLevel: span.cueLevel == true,
                                            speaker: segment.speaker))
                }
            }
        }
        return ClipCaptionTimeline(captions: captions.sorted { $0.start < $1.start })
    }

    /// Clip-generated captions apply only while the current trim stays inside
    /// the source range they were generated for; anything else is stale.
    static func generatedRange(_ range: ClosedRange<Double>?, covers start: Double, _ end: Double) -> Bool {
        guard let range, start.isFinite, end.isFinite, end > start else { return false }
        return start >= range.lowerBound && end <= range.upperBound
    }

    /// Resolve against the preview player's source-media clock.
    func caption(atMediaTime time: TimeInterval) -> Caption? {
        guard time.isFinite else { return nil }
        var low = 0
        var high = captions.count
        while low < high {
            let mid = (low + high) / 2
            if captions[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let caption = captions[low - 1]
        return time < caption.end ? caption : nil
    }

    /// Intersect with the trim in source time, then convert to presentation time.
    func clipped(start: TimeInterval, end: TimeInterval, playbackRate: Double) -> ClipCaptionTimeline {
        guard start.isFinite, end.isFinite, playbackRate.isFinite,
              start >= 0, end > start, playbackRate > 0 else { return ClipCaptionTimeline(captions: []) }
        let clippedCaptions = captions.compactMap { caption -> Caption? in
            let lower = max(caption.start, start)
            let upper = min(caption.end, end)
            guard upper > lower else { return nil }
            return Caption(text: caption.text, location: caption.location, length: caption.length,
                           start: (lower - start) / playbackRate, end: (upper - start) / playbackRate,
                           cueLevel: caption.cueLevel, speaker: caption.speaker)
        }
        let clippedCoverage = coverage?.compactMap { interval -> LiveTranscriptState.Coverage? in
            let lower = max(interval.start, start), upper = min(interval.end, end)
            guard upper > lower else { return nil }
            return .init(start: (lower - start) / playbackRate, end: (upper - start) / playbackRate)
        }
        return ClipCaptionTimeline(captions: clippedCaptions, coverage: clippedCoverage)
    }
}

extension EpisodeActor {
    /// Resolve publisher rows even in libraries where a previous import left mixed sources.
    func publisherClipDocument(for url: URL) async -> TranscriptDocumentSnapshot? {
        guard let episode = await fetchEpisode(byURL: url) else { return nil }
        let episodeID = episode.persistentModelID
        let publisher = CachedTranscriptSource.publisher.rawValue
        let rows = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { $0.episode?.persistentModelID == episodeID && $0.sourceRawValue == publisher },
            sortBy: [SortDescriptor(\.startTime)]
        )
        guard let lines = try? modelContext.fetch(rows) else { return nil }
        return TranscriptDocumentSnapshot.resolve(episodeID: episode.stableEpisodeIdentity.key, storedLines: lines.map {
            .init(id: $0.id, speaker: $0.speaker, text: $0.text, startTime: $0.startTime, endTime: $0.endTime,
                  sourceRawValue: $0.sourceRawValue, timedSpans: $0.timedSpans)
        })
    }
}

/// Immutable publisher document plus timing for one local media variant.
struct PublisherClipCaptionResolver: Sendable {
    typealias Mapping = PublisherTranscriptTimingOverlay.Mapping
    typealias Caption = ClipCaptionTimeline.Caption
    let key: PublisherTranscriptTimingOverlay.Key
    let alignment: TranscriptSynchronizationTimeline?
    private let lines: [TranscriptSegment]
    private let lineByID: [UUID: TranscriptSegment]
    private let native: [Caption]
    private let coarse: [Caption]

    /// - Parameter overlayFingerprint: The bounded `v2:` fingerprint that keys
    ///   the shared word-timing overlay cache (#488), so clip export reuses the
    ///   pages playback enrichment wrote. Defaults to `mediaFingerprint`.
    init?(
        document: TranscriptDocumentSnapshot,
        mediaFingerprint: String,
        overlayFingerprint: String? = nil,
        alignment: TranscriptSynchronizationTimeline?
    ) {
        let overlayFingerprint = overlayFingerprint ?? mediaFingerprint
        guard document.source == .publisher, let revision = document.timingRevision,
              !mediaFingerprint.isEmpty, !overlayFingerprint.isEmpty else { return nil }
        key = .init(episodeID: document.episodeID, mediaFingerprint: overlayFingerprint, transcriptRevision: revision)
        self.alignment = alignment
        // Matcher and cache offsets refer to original, untrimmed individual lines.
        lines = document.lines.map {
            .init(id: $0.id, speaker: $0.speaker, text: $0.text, startTime: $0.startTime, endTime: $0.endTime,
                  lineIDs: [$0.id], timedSpans: $0.timedSpans)
        }
        lineByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let segments = TranscriptSegmentBuilder.makeSegments(fromSorted: document.lines, options: .compact)
        let timed = ClipCaptionTimeline.resolve(segments: segments, publisherAlignmentRequired: alignment != nil,
                                                alignment: alignment)?.captions ?? []
        native = timed.filter { !$0.cueLevel }
        coarse = alignment == nil ? [] : timed.filter(\.cueLevel)
    }

    func resolve(in range: Range<Double>, speech: [TranscriptSegmentSource] = [], language: String? = nil,
                 cache: PublisherTranscriptTimingOverlayCache = .shared) async -> ClipCaptionTimeline {
        let cached = (try? await cache.mappings(for: key, in: range)) ?? []
        let speechSegments = TranscriptSegmentBuilder.makeSegments(from: speech, options: .compact)
        let local = ClipCaptionTimeline.resolve(segments: speechSegments, publisherAlignmentRequired: false,
                                               alignment: nil)?.captions ?? []
        let additions = language.map { match(local, language: $0, in: range) } ?? []
        if !additions.isEmpty, !Task.isCancelled { try? await cache.merge(additions, for: key) }
        let layers = [native, cached.compactMap(caption), additions.compactMap(caption), coarse, local]
        return Self.layered(layers, in: range)
    }

    private func intersectsGap(_ start: Double, _ end: Double) -> Bool {
        alignment?.gaps.contains { $0.audioStart < end && $0.audioEnd > start } == true
    }

    private func caption(_ mapping: Mapping) -> Caption? {
        guard let line = lineByID[mapping.lineID], !intersectsGap(mapping.audioStart, mapping.audioEnd),
              mapping.location >= 0, mapping.length > 0, mapping.location <= line.text.utf16.count,
              mapping.length <= line.text.utf16.count - mapping.location,
              Range(NSRange(location: mapping.location, length: mapping.length), in: line.text) != nil
        else { return nil }
        return Caption(text: line.text, location: mapping.location, length: mapping.length,
                       start: mapping.audioStart, end: mapping.audioEnd, cueLevel: false, speaker: line.speaker)
    }

    private func match(_ speech: [Caption], language: String, in range: Range<Double>) -> [Mapping] {
        let words: [PublisherTranscriptWordMatcher.SpeechWord] = speech.compactMap { item in
            guard !item.cueLevel, item.start < range.upperBound, item.end > range.lowerBound,
                  !intersectsGap(item.start, item.end),
                  let word = Range(NSRange(location: item.location, length: item.length), in: item.text)
            else { return nil }
            return .init(text: String(item.text[word]), audioStart: item.start, audioEnd: item.end)
        }
        var matches: [PublisherWordTimingMatch] = []
        for index in stride(from: 0, to: words.count, by: 40) {
            let window = Array(words[index..<min(index + 48, words.count)])
            let start = window[0].audioStart
            matches += PublisherTranscriptWordMatcher.match(words: window, segments: lines,
                expectedTranscriptTime: alignment?.transcriptTime(forAudioTime: start) ?? start,
                publisherLanguage: language, speechLanguage: language)
        }
        guard !matches.isEmpty else { return [] }
        // The overlay uses word ordinals across the entire revision, including unmatched words.
        let byLine = Dictionary(grouping: matches, by: \.segmentID)
        let pattern = Self.wordPattern
        var tokenBase = 0
        var mappings: [Int: Mapping] = [:]
        for line in lines {
            let full = NSRange(location: 0, length: line.text.utf16.count)
            guard let matched = byLine[line.id] else {
                tokenBase += pattern.numberOfMatches(in: line.text, range: full)
                continue
            }
            let tokens = pattern.matches(in: line.text, range: full)
            for word in matched where word.confidence >= 0.82 && !intersectsGap(word.audioStart, word.audioEnd) {
                guard let ordinal = tokens.firstIndex(where: { $0.range.location == word.textRange.lowerBound }) else { continue }
                let index = tokenBase + ordinal
                if let previous = mappings[index], previous.confidence >= word.confidence { continue }
                mappings[index] = Mapping(tokenIndex: index, lineID: line.id, location: word.textRange.lowerBound,
                    length: word.textRange.count, audioStart: word.audioStart, audioEnd: word.audioEnd,
                    confidence: word.confidence)
            }
            tokenBase += tokens.count
        }
        return mappings.values.sorted { $0.audioStart < $1.audioStart }
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*"#
    )

    /// At each boundary choose the first active caption in priority order. Splitting
    /// the lower-priority cue lets it resume immediately after an enhanced word ends.
    static func layered(_ layers: [[Caption]], in range: Range<Double>) -> ClipCaptionTimeline {
        var items: [Caption] = []
        var events: [(time: Double, index: Int, begins: Bool)] = []
        for layer in layers {
            for item in layer {
                let start = max(range.lowerBound, item.start), end = min(range.upperBound, item.end)
                guard end > start else { continue }
                events.append((start, items.count, true))
                events.append((end, items.count, false))
                items.append(item)
            }
        }
        events.sort { $0.time < $1.time }
        var active: Set<Int> = []
        var result: [Caption] = []
        var previous = range.lowerBound
        var lastIndex: Int?
        for event in events {
            if event.time > previous {
                let index = active.min()
                if let index {
                    let item = items[index]
                    let start = lastIndex == index ? result.removeLast().start : previous
                    result.append(Caption(text: item.text, location: item.location, length: item.length,
                                          start: start, end: event.time, cueLevel: item.cueLevel, speaker: item.speaker))
                }
                lastIndex = index
                previous = event.time
            }
            if event.begins { active.insert(event.index) } else { active.remove(event.index) }
        }
        return ClipCaptionTimeline(captions: result)
    }
}
