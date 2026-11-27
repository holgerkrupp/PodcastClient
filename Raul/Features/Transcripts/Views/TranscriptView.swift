//
//  TranscriptView.swift
//  PodcastClient
//
//  Drop-in replacement: compact, BBC-inspired playback captions.
//

import SwiftUI
import Combine
import Foundation
import CryptoKit
import NaturalLanguage
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Compact, display-only caption card for the player's inline transcript
/// overlay. It paints immutable compact segments prepared by
/// ``PlayerTranscriptOverlayHost`` and wraps only a small window of captions
/// around the playback position, so neither a long publisher transcript nor a
/// growing live transcript is re-wrapped in full (#495, #520).
struct TranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var captionFontSize: CGFloat = 13
    #else
    @ScaledMetric(relativeTo: .body) private var captionFontSize: CGFloat = 17
    #endif

    let snapshot: InlineCaptionSnapshot
    @Binding var currentTime: TimeInterval
    var onOpenFullTranscript: (() -> Void)?
    var reservesBottomTrailingAccessory = false

    @State private var window = InlineCaptionWindow()
    @State private var followPlayback = true
    @State private var tracker = TranscriptPlaybackTracker()

    private let speakerColors: [Color] = [.blue, .green, .orange, .purple, .red, .teal]
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 10

    init(
        snapshot: InlineCaptionSnapshot,
        currentTime: Binding<TimeInterval>,
        onOpenFullTranscript: (() -> Void)? = nil,
        reservesBottomTrailingAccessory: Bool = false
    ) {
        self.snapshot = snapshot
        self._currentTime = currentTime
        self.onOpenFullTranscript = onOpenFullTranscript
        self.reservesBottomTrailingAccessory = reservesBottomTrailingAccessory
    }

    private var usesPublisherAlignment: Bool { snapshot.usesPublisherAlignment }
    private var canFollowPlayback: Bool { snapshot.canFollowPlayback }
    private var episodeURL: URL? { snapshot.episodeURL }

    var body: some View {
        GeometryReader { geometry in
            let layout = CaptionLayout(
                width: max(1, geometry.size.width - 2 * horizontalPadding),
                height: max(1, geometry.size.height - 2 * verticalPadding - accessoryInset),
                fontSize: captionFontSize
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleCaptions) { caption in
                            captionView(caption)
                                .id(caption.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, verticalPadding)
                    .padding(.bottom, verticalPadding + accessoryInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(followPlayback ? .hidden : .automatic)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if followPlayback && canFollowPlayback { followPlayback = false }
                        }
                )
                .overlay(alignment: reservesBottomTrailingAccessory ? .bottomLeading : .bottomTrailing) {
                    if !followPlayback && canFollowPlayback && playbackCaption != nil {
                        Button {
                            followPlayback = true
                        } label: {
                            Label("Follow", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .accessibilityLabel("Follow playback")
                        .accessibilityHint("Returns to the currently playing caption")
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .onChange(of: layout, initial: true) { _, newLayout in
                    materialize(layout: newLayout, recenter: true)
                }
                .onChange(of: snapshot) {
                    materialize(layout: layout, recenter: followPlayback)
                }
                .onChange(of: followPlayback) {
                    materialize(layout: layout, recenter: true)
                }
                .onAppear {
                    if canFollowPlayback { startTracker() }
                }
                .onDisappear { tracker.stop() }
                .publisherTimingDemand(episodeURL: usesPublisherAlignment ? episodeURL : nil)
                .onChange(of: currentTime) {
                    // Never move a window the listener is reading; a saved
                    // partial transcript cannot follow, so it stays put too.
                    if followPlayback && canFollowPlayback {
                        let center = currentCenter
                        if window.needsRecentering(around: center, segmentCount: snapshot.segments.count) {
                            materialize(layout: layout, recenter: true)
                        }
                    }
                    tracker.refresh()
                }
                .onChange(of: Player.shared.currentEpisodeURL) {
                    followPlayback = true
                    updateTracker()
                }
                .onChange(of: canFollowPlayback) {
                    if canFollowPlayback {
                        followPlayback = true
                        startTracker()
                    } else {
                        tracker.stop()
                    }
                }
                // A new caption or a new highlighted line changes this key.
                // A word change within the same line does not scroll the view.
                .task(id: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    // Give the lazy stack an opportunity to lay out the new caption.
                    await Task.yield()
                    guard !Task.isCancelled, followPlayback, scrollTarget == target else { return }
                    // Immediate positioning: an animated scroll could leave the
                    // highlighted word outside the viewport at fast playback rates.
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Transcript")
    }

    private var accessoryInset: CGFloat { reservesBottomTrailingAccessory ? 28 : 0 }

    private var activeCaption: PlaybackCaption? {
        guard let id = tracker.active?.segmentID, let index = window.captionIndex[id],
              window.captions.indices.contains(index) else { return nil }
        return window.captions[index]
    }

    /// Live recognition can lag behind audio playback. For transcripts on the
    /// audio timeline, retain the last caption whose start is not in the future.
    /// Never use this fallback for publisher alignment: a missing active caption
    /// may represent an advertisement or an unverified alignment interval.
    private var fallbackCaption: PlaybackCaption? {
        guard !usesPublisherAlignment,
              let episodeURL, episodeURL == Player.shared.currentEpisodeURL,
              currentTime.isFinite else { return nil }

        // Same chronological lookup as the playback tracker, intentionally
        // ignoring the end time to tolerate delayed speech recognition.
        let captions = window.captions
        var low = 0
        var high = captions.count
        while low < high {
            let mid = low + (high - low) / 2
            if captions[mid].segment.startTime <= currentTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low > 0 else { return nil }
        return captions[low - 1]
    }

    private var playbackCaption: PlaybackCaption? {
        guard let episodeURL, episodeURL == Player.shared.currentEpisodeURL else { return nil }
        return activeCaption ?? fallbackCaption
    }

    private var visibleCaptions: [PlaybackCaption] {
        guard followPlayback && canFollowPlayback else { return window.captions }
        return playbackCaption.map { [$0] } ?? []
    }

    private var scrollTarget: CaptionLineID? {
        guard followPlayback, canFollowPlayback, let caption = playbackCaption else { return nil }
        // Only use a real active word belonging to this caption. A fallback
        // caption is readable but does not receive speculative highlighting.
        let location = tracker.active?.segmentID == caption.id ? tracker.active?.location : nil
        let line = location.flatMap { location in
            caption.lines.firstIndex { NSLocationInRange(location, $0) }
        } ?? 0
        return CaptionLineID(captionID: caption.id, lineIndex: line)
    }

    /// Segment index nearest the playback position on the transcript clock.
    private var currentCenter: Int {
        guard episodeURL == Player.shared.currentEpisodeURL, currentTime.isFinite else {
            return window.center
        }
        let time = usesPublisherAlignment
            ? (TranscriptSynchronizationStore.shared.transcriptTime(forAudioTime: currentTime, episodeURL: episodeURL) ?? currentTime)
            : currentTime
        return InlineCaptionWindow.segmentIndex(in: snapshot.segments, at: time)
    }

    private func speakerColor(_ speaker: String) -> Color {
        guard let index = snapshot.speakers.firstIndex(of: speaker) else { return .accentColor }
        return speakerColors[index % speakerColors.count]
    }

    private func captionView(_ caption: PlaybackCaption) -> some View {
        let segment = caption.segment
        let isActive = tracker.active?.segmentID == caption.id
        let isFallback = followPlayback && canFollowPlayback && !isActive
            && playbackCaption?.id == caption.id
        return VStack(alignment: .leading, spacing: 2) {
            if let speaker = segment.speaker, window.speakerHeaderIDs.contains(caption.id) {
                Text("\(speaker):")
                    .font(.system(size: captionFontSize, weight: .semibold))
                    .foregroundStyle(differentiateWithoutColor ? Color.primary : speakerColor(speaker))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(caption.lines.indices, id: \.self) { index in
                let range = caption.lines[index]
                highlightedLine(caption, range: range)
                    .font(.system(size: captionFontSize))
                    .foregroundStyle(isActive || isFallback ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(CaptionLineID(captionID: caption.id, lineIndex: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpenFullTranscript?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? Text("Current caption") : (isFallback ? Text("Latest available caption") : Text("Caption")))
        .accessibilityValue(segment.speaker.map { "\($0), \(segment.text)" } ?? segment.text)
        .accessibilityAddTraits(onOpenFullTranscript == nil ? [] : .isButton)
    }

    private func highlightedLine(_ caption: PlaybackCaption, range: NSRange) -> Text {
        let text = caption.segment.text
        guard let lineRange = Range(range, in: text) else { return Text("") }
        guard let active = tracker.active, active.segmentID == caption.id,
              let location = active.location, let length = active.length,
              location >= 0, length > 0, location <= text.utf16.count,
              length <= text.utf16.count - location else {
            return Text(String(text[lineRange]))
        }
        let intersection = NSIntersectionRange(range, NSRange(location: location, length: length))
        guard intersection.length > 0, let word = Range(intersection, in: text) else {
            return Text(String(text[lineRange]))
        }
        // Underline + accent preserve the original glyph advances. Changing
        // font weight on each word could rewrap an otherwise fitting line.
        let before = Text(String(text[lineRange.lowerBound..<word.lowerBound]))
        let selected = Text(String(text[word])).underline()
            .foregroundColor(differentiateWithoutColor ? .primary : .accentColor)
        let after = Text(String(text[word.upperBound..<lineRange.upperBound]))
        return Text("\(before)\(selected)\(after)")
    }

    private func startTracker() {
        tracker.start(segments: window.captionSegments, episodeURL: episodeURL, useAlignment: usesPublisherAlignment)
    }

    private func updateTracker() {
        guard canFollowPlayback else { return }
        tracker.update(segments: window.captionSegments, episodeURL: episodeURL, useAlignment: usesPublisherAlignment)
    }

    /// Wraps only the captions near the playback position. Unchanged segments
    /// reuse their cached captions, so a new live cue re-wraps just the
    /// trailing segment(s) and a layout change re-wraps only the window.
    private func materialize(layout: CaptionLayout, recenter: Bool) {
        let radius = followPlayback && canFollowPlayback
            ? InlineCaptionWindow.followRadius
            : InlineCaptionWindow.browseRadius
        let center = recenter ? currentCenter : window.center
        let previous = window.captionSegments
        window.materialize(segments: snapshot.segments, center: center, radius: radius, layout: layout)
        if window.captionSegments != previous { updateTracker() }
    }
}

/// The compact, immutable caption input for ``TranscriptView``. Segments are
/// already grouped (off the main actor for stored transcripts, incrementally for
/// live recognition); `revision` changes whenever they do.
struct InlineCaptionSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case document, live, savedPartial }

    let episodeURL: URL
    let kind: Kind
    let revision: Int
    let segments: [TranscriptSegment]
    let speakers: [String]
    let usesPublisherAlignment: Bool
    let canFollowPlayback: Bool

    /// Cheap identity comparison: `revision` is bumped for every new segment list.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episodeURL == rhs.episodeURL && lhs.kind == rhs.kind && lhs.revision == rhs.revision
            && lhs.usesPublisherAlignment == rhs.usesPublisherAlignment
            && lhs.canFollowPlayback == rhs.canFollowPlayback
    }
}

/// A bounded window of wrapped captions around one segment (#520). Captions
/// are cached per segment and reused while the segment and its successor's
/// start time are unchanged, which keeps live updates O(changed segments).
struct InlineCaptionWindow {
    /// While following playback only the current caption is shown.
    static let followRadius = 3
    /// After the listener scrolls the card, keep a readable neighbourhood.
    static let browseRadius = 20

    private struct Entry {
        let segment: TranscriptSegment
        let nextStart: TimeInterval?
        let captions: [PlaybackCaption]
    }

    private(set) var layout: CaptionLayout?
    private(set) var range: Range<Int> = 0..<0
    private(set) var center = 0
    private(set) var radius = 0
    private(set) var captions: [PlaybackCaption] = []
    private(set) var captionSegments: [TranscriptSegment] = []
    private(set) var captionIndex: [UUID: Int] = [:]
    private(set) var speakerHeaderIDs: Set<UUID> = []
    /// Segments wrapped since creation; exposes reuse to tests and diagnostics.
    private(set) var wrappedSegmentCount = 0
    private var cache: [UUID: Entry] = [:]

    /// Index of the last segment starting at or before `time`, clamped to the list.
    static func segmentIndex(in segments: [TranscriptSegment], at time: TimeInterval) -> Int {
        guard !segments.isEmpty, time.isFinite else { return 0 }
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].startTime <= time { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    func needsRecentering(around newCenter: Int, segmentCount: Int) -> Bool {
        guard segmentCount > 0 else { return false }
        if range.isEmpty { return true }
        return abs(newCenter - center) > max(1, radius / 2)
    }

    mutating func materialize(
        segments: [TranscriptSegment],
        center requestedCenter: Int,
        radius: Int,
        layout: CaptionLayout
    ) {
        if layout != self.layout {
            cache.removeAll()
            self.layout = layout
        }
        guard !segments.isEmpty else {
            range = 0..<0
            center = 0
            self.radius = radius
            captions = []
            captionSegments = []
            captionIndex = [:]
            speakerHeaderIDs = []
            cache.removeAll()
            return
        }

        let center = min(max(0, requestedCenter), segments.count - 1)
        let range = max(0, center - radius)..<min(segments.count, center + radius + 1)
        var newCache: [UUID: Entry] = [:]
        var newCaptions: [PlaybackCaption] = []
        var headers = Set<UUID>()
        for index in range {
            let segment = segments[index]
            let nextStart = index + 1 < segments.count ? segments[index + 1].startTime : nil
            let wrapped: [PlaybackCaption]
            if let entry = cache[segment.id], entry.nextStart == nextStart, entry.segment == segment {
                wrapped = entry.captions
            } else {
                wrapped = InlineCaptionBuilder.captions(for: segment, nextStart: nextStart, layout: layout)
                wrappedSegmentCount += 1
            }
            newCache[segment.id] = Entry(segment: segment, nextStart: nextStart, captions: wrapped)
            // Captions of one segment share its speaker, so only a segment's
            // first caption can start a new speaker turn.
            let previousSpeaker = index > 0 ? segments[index - 1].speaker : nil
            if let first = wrapped.first, segment.speaker != previousSpeaker {
                headers.insert(first.id)
            }
            newCaptions.append(contentsOf: wrapped)
        }

        cache = newCache
        self.range = range
        self.center = center
        self.radius = radius
        captions = newCaptions
        captionSegments = newCaptions.map(\.segment)
        captionIndex = Dictionary(
            newCaptions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        speakerHeaderIDs = headers
    }
}

// MARK: - Presentation-only captions

private struct CaptionLineID: Hashable {
    let captionID: UUID
    let lineIndex: Int
}

struct PlaybackCaption: Identifiable, Equatable {
    let segment: TranscriptSegment
    // UTF-16 ranges into segment.text, not the original source segment.
    let lines: [NSRange]
    var id: UUID { segment.id }
}

struct CaptionLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat

    init(width: CGFloat, height: CGFloat, fontSize: CGFloat) {
        // Ignore sub-point geometry noise during a live window resize.
        self.width = width.rounded(.down)
        self.height = height.rounded(.down)
        self.fontSize = fontSize
    }

    var lineHeight: CGFloat {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: fontSize).lineHeight
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
        #else
        return fontSize * 1.3
        #endif
    }

    func width(of text: String) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: fontSize)
        return (text as NSString).size(withAttributes: [.font: font]).width
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: fontSize)
        return (text as NSString).size(withAttributes: [.font: font]).width
        #else
        return CGFloat(text.count) * fontSize * 0.6
        #endif
    }
}

// MARK: - BBC-inspired line and caption segmentation

enum InlineCaptionBuilder {
    private static let maxDuration: TimeInterval = 5
    private static let targetCharactersPerLine = 37
    private static let maxWords = 14

    private static let weakEndings: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from",
        "and", "or", "but", "is", "are", "was", "were", "have", "has", "will",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "einem",
        "einen", "mit", "zu", "zum", "zur", "von", "im", "am", "auf", "für",
        "und", "oder", "aber", "ist", "sind", "war", "wird", "hat", "haben"
    ]

    /// Wraps every segment. Used as the reference result in tests; views use
    /// ``InlineCaptionWindow`` to wrap only the captions they can show.
    static func makeCaptions(from segments: [TranscriptSegment], layout: CaptionLayout) -> [PlaybackCaption] {
        var result: [PlaybackCaption] = []
        for (index, segment) in segments.enumerated() {
            let nextStart = index + 1 < segments.count ? segments[index + 1].startTime : nil
            result.append(contentsOf: captions(for: segment, nextStart: nextStart, layout: layout))
        }
        return result
    }

    /// Captions for one segment. The result depends only on the segment, the
    /// following segment's start time and the layout.
    static func captions(for segment: TranscriptSegment, nextStart: TimeInterval?, layout: CaptionLayout) -> [PlaybackCaption] {
        split(segment, nextStart: nextStart, layout: layout)
    }

    private static func split(_ source: TranscriptSegment, nextStart: TimeInterval?, layout: CaptionLayout) -> [PlaybackCaption] {
        let ns = source.text as NSString
        let tokens = tokenRanges(in: source.text)
        guard !tokens.isEmpty else { return [] }
        let validSpans = source.timedSpans.filter {
            $0.location >= 0 && $0.length > 0 && $0.location <= ns.length &&
            $0.length <= ns.length - $0.location && $0.startTime.isFinite &&
            $0.endTime.isFinite && $0.endTime > $0.startTime &&
            Range(NSRange(location: $0.location, length: $0.length), in: source.text) != nil
        }
        let words: [TranscriptTimedSpan] = validSpans.filter { $0.cueLevel == false }.sorted { $0.location < $1.location }
        // An open-ended final cue has no honest duration estimate. Keep it
        // whole rather than inventing timing or hiding subsequent words.
        let knownEnd = source.endTime ?? nextStart ?? validSpans.map { $0.endTime }.max()
        guard let knownEnd, knownEnd.isFinite, knownEnd > source.startTime else {
            return [PlaybackCaption(segment: source, lines: [NSRange(location: 0, length: ns.length)])]
        }
        let end = max(knownEnd, words.map { $0.endTime }.max() ?? knownEnd)
        let timing = boundaryTimes(source: source, end: end, spans: validSpans, tokens: tokens)
        let headerHeight = source.speaker == nil ? 0 : layout.lineHeight + 2
        let lineCount = layout.height - headerHeight >= 2 * layout.lineHeight + 4 ? 2 : 1

        func range(_ start: Int, _ finish: Int) -> NSRange {
            NSRange(location: tokens[start].location,
                    length: NSMaxRange(tokens[finish - 1]) - tokens[start].location)
        }
        func fitsLine(_ start: Int, _ finish: Int) -> Bool {
            let value = ns.substring(with: range(start, finish))
            // An exceptionally long word stays intact; SwiftUI can wrap it
            // as a last resort and the line remains scrollable.
            if finish == start + 1 { return true }
            return value.count <= targetCharactersPerLine &&
                layout.width(of: value) <= layout.width * 0.94 &&
                !value.contains("\n") && !value.contains("\r")
        }
        func safeBreak(_ i: Int) -> Bool {
            guard i > 0 && i < tokens.count else { return true }
            guard timing[i] < end else { return false }
            let boundary = tokens[i].location
            // Never split a real timed span or split between temporally
            // overlapping real spans, which the tracker cannot display together.
            if words.contains(where: { $0.location < boundary && $0.location + $0.length > boundary }) { return false }
            let earlierEnd = words.lazy.filter { $0.location + $0.length <= boundary }.map { $0.endTime }.max()
            let laterStart = words.lazy.filter { $0.location >= boundary }.map { $0.startTime }.min()
            if let earlierEnd, let laterStart, earlierEnd > laterStart { return false }
            // Approximate cue times must never switch away from a real word early.
            if let earlierEnd, timing[i] < earlierEnd { return false }
            if let laterStart, timing[i] > laterStart { return false }
            return timing[i] > timing[i - 1]
        }
        func boundaryScore(_ i: Int) -> Int {
            guard i > 0 else { return 0 }
            let word = ns.substring(with: tokens[i - 1])
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
            if let last = trimmed.last {
                if ".!?…。！？".contains(last) { return 9 }
                if ",;:，；：—".contains(last) { return 5 }
            }
            if weakEndings.contains(trimmed.lowercased()) { return -6 }
            return 0
        }
        func lineRanges(_ start: Int, _ finish: Int) -> [NSRange]? {
            if fitsLine(start, finish) { return [range(start, finish)] }
            guard lineCount == 2, finish > start + 1 else { return nil }
            var best: (index: Int, score: Double)?
            for i in (start + 1)..<finish where fitsLine(start, i) && fitsLine(i, finish) {
                let boundary = tokens[i].location
                guard !words.contains(where: { $0.location < boundary && $0.location + $0.length > boundary }) else { continue }
                // Prefer a natural line break and similarly sized lines.
                let leftRange = range(start, i)
                let rightRange = range(i, finish)
                guard layout.width(of: ns.substring(with: leftRange)) <= layout.width * 0.94,
                      layout.width(of: ns.substring(with: rightRange)) <= layout.width * 0.94 else { continue }
                let left = leftRange.length
                let right = rightRange.length
                let score = Double(boundaryScore(i)) * 5 - Double(abs(left - right)) * 0.25
                if best == nil || score > best!.score { best = (i, score) }
            }
            guard let i = best?.index else { return nil }
            return [range(start, i), range(i, finish)]
        }

        var result: [PlaybackCaption] = []
        var start = 0
        while start < tokens.count {
            var candidates: [(end: Int, lines: [NSRange])] = []
            let limit = min(tokens.count, start + maxWords)
            for finish in (start + 1)...limit {
                guard let lines = lineRanges(start, finish) else { break }
                if finish > start + 1 && timing[finish] - timing[start] > maxDuration { break }
                if safeBreak(finish) { candidates.append((finish, lines)) }
            }
            var selected: (end: Int, lines: [NSRange])
            if let last = candidates.last {
                // Do not make a tiny caption solely because it has punctuation.
                let minimum = start + max(1, (last.end - start) / 2)
                selected = candidates.filter { $0.end >= minimum }.max {
                    let a = $0.end - start + boundaryScore($0.end)
                    let b = $1.end - start + boundaryScore($1.end)
                    return a == b ? $0.end < $1.end : a < b
                } ?? last
            } else {
                // Malformed/overlapping timing or an unsplittable word takes
                // priority over the two-line guideline. Never lose text.
                var finish = start + 1
                while finish < tokens.count && !safeBreak(finish) { finish += 1 }
                selected = (finish, lineRanges(start, finish) ?? [range(start, finish)])
            }
            let finish = selected.end
            let slice = range(start, finish)
            let text = ns.substring(with: slice)
            let startTime = timing[start]
            let endTime = timing[finish]
            let spans = validSpans.compactMap { span -> TranscriptTimedSpan? in
                let intersection = NSIntersectionRange(slice, NSRange(location: span.location, length: span.length))
                guard intersection.length > 0 else { return nil }
                // Real word timing is untouched. Cue timing may be clipped
                // because one original cue can now cover several captions.
                let spanStart = span.cueLevel != false ? max(startTime, span.startTime) : span.startTime
                let spanEnd = span.cueLevel != false ? min(endTime, span.endTime) : span.endTime
                guard spanEnd > spanStart else { return nil }
                let local = NSRange(location: intersection.location - slice.location, length: intersection.length)
                guard Range(local, in: text) != nil else { return nil }
                return TranscriptTimedSpan(location: local.location, length: local.length,
                                           startTime: spanStart, endTime: spanEnd, cueLevel: span.cueLevel)
            }
            let segment = TranscriptSegment(
                id: stableID(source: source.id, range: slice), speaker: source.speaker,
                text: text, startTime: startTime, endTime: endTime,
                lineIDs: source.lineIDs, timedSpans: spans
            )
            let localLines = selected.lines.map { NSRange(location: $0.location - slice.location, length: $0.length) }
            result.append(PlaybackCaption(segment: segment, lines: localLines))
            start = finish
        }
        return result
    }

    // Word/cue timestamps become anchors. Interpolation is used only between
    // known anchors; it never creates a fake word-level highlight.
    private static func boundaryTimes(source: TranscriptSegment, end: TimeInterval,
                                      spans: [TranscriptTimedSpan], tokens: [NSRange]) -> [TimeInterval] {
        let length = (source.text as NSString).length
        var anchors: [Int: TimeInterval] = [0: source.startTime, length: end]
        for span in spans.sorted(by: { $0.cueLevel != false && $1.cueLevel == false }) {
            anchors[span.location] = span.startTime
            // A following word start at the same position wins below.
            if anchors[span.location + span.length] == nil {
                anchors[span.location + span.length] = span.endTime
            }
        }
        anchors[0] = source.startTime
        anchors[length] = end
        let positions = anchors.keys.sorted()
        var times: [TimeInterval] = []
        var cursor = 0
        for token in tokens {
            let position = token.location
            while cursor + 1 < positions.count && positions[cursor + 1] <= position { cursor += 1 }
            let lower = positions[cursor]
            let upper = positions[min(cursor + 1, positions.count - 1)]
            let a = anchors[lower] ?? source.startTime
            let b = anchors[upper] ?? end
            let fraction = upper > lower ? Double(position - lower) / Double(upper - lower) : 0
            let estimate = min(end, max(source.startTime, a + (b - a) * fraction))
            times.append(max(times.last ?? source.startTime, estimate))
        }
        times[0] = source.startTime
        times.append(end)
        return times
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\S+"#)

    private static func tokenRanges(in text: String) -> [NSRange] {
        // Keep punctuation and Unicode graphemes intact. NaturalLanguage also
        // provides word boundaries for scripts that do not separate words by spaces.
        let ns = text as NSString
        let matches = tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var ranges: [NSRange] = []
        for match in matches {
            let raw = ns.substring(with: match.range)
            let hasUnspacedScript = raw.unicodeScalars.contains {
                (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) ||
                (0x0E00...0x0E7F).contains($0.value)
            }
            guard hasUnspacedScript, raw.count > 8 else { ranges.append(match.range); continue }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = raw
            var starts = [0]
            tokenizer.enumerateTokens(in: raw.startIndex..<raw.endIndex) { range, _ in
                let offset = NSRange(range, in: raw).location
                if offset > 0 { starts.append(offset) }
                return true
            }
            starts = Array(Set(starts)).sorted()
            starts.append(raw.utf16.count)
            for i in 0..<(starts.count - 1) {
                ranges.append(NSRange(location: match.range.location + starts[i], length: starts[i + 1] - starts[i]))
            }
        }
        return ranges
    }

    private static func stableID(source: UUID, range: NSRange) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(source.uuidString):\(range.location):\(range.length)".utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }
}
