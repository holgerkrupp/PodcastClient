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
            guard publisherAlignment != nil else { return nil }
            needsAlignment = true
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
