import Foundation

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
/// Publisher captions require an alignment for the actual media variant.
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
                        publisherAlignment: TranscriptSynchronizationTimeline?,
                        allowUnalignedPublisherTiming: Bool = false) -> ClipCaptionTimeline? {
        let needsAlignment: Bool
        switch snapshot.origin {
        case .generated(let expected):
            guard expected == mediaFingerprint else { return nil }
            needsAlignment = false
        case .publisher:
            guard publisherAlignment != nil || allowUnalignedPublisherTiming else { return nil }
            needsAlignment = publisherAlignment != nil
        }
        let segments = TranscriptSegmentBuilder.makeSegments(from: snapshot.lines, options: .compact)
        guard var timeline = resolve(segments: segments, publisherAlignmentRequired: needsAlignment, alignment: publisherAlignment) else { return nil }
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
