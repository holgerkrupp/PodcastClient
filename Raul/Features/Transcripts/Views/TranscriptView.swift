//
//  TranscriptView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI
import Combine

/// Compact, scrollable caption overlay used inside the player.
///
/// When following playback and word timing is available, this presents only the
/// current caption in a stable two-line region, matching live-caption
/// conventions. Without word timing it keeps the complete current snippet
/// visible instead of truncating it. Turning following off restores the
/// scrollable transcript context.
struct TranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let transcriptLines: [TranscriptLineAndTime]
    /// Captured once with the transcript snapshot; playback ticks must not
    /// rescan SwiftData models for transcript-global metadata.
    let usesPublisherAlignment: Bool
    @Binding var currentTime: TimeInterval
    /// Called when the user taps a caption, e.g. to open the full transcript.
    var onOpenFullTranscript: (() -> Void)?
    /// Leaves the bottom-trailing corner free for controls supplied by the parent.
    var reservesBottomTrailingAccessory = false
    var canFollowPlayback = true

    @State private var segments: [TranscriptSegment] = []
    @State private var speakerHeaderIDs: Set<UUID> = []
    @State private var speakerColorMap: [String: Color] = [:]
    @State private var followPlayback: Bool = true
    @State private var tracker = TranscriptPlaybackTracker()

    private let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]

    init(
        transcriptLines: [TranscriptLineAndTime],
        currentTime: Binding<TimeInterval>,
        onOpenFullTranscript: (() -> Void)? = nil,
        reservesBottomTrailingAccessory: Bool = false,
        canFollowPlayback: Bool = true
    ) {
        self.transcriptLines = transcriptLines
        self.usesPublisherAlignment = TranscriptSourceMetadata.make(from: transcriptLines).usesPublisherAlignment
        self._currentTime = currentTime
        self.onOpenFullTranscript = onOpenFullTranscript
        self.reservesBottomTrailingAccessory = reservesBottomTrailingAccessory
        self.canFollowPlayback = canFollowPlayback
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleSegments) { segment in
                        segmentView(segment)
                            .id(segment.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(followPlayback ? .hidden : .automatic)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in
                        guard followPlayback else { return }
                        followPlayback = false
                    }
            )
            .overlay(alignment: reservesBottomTrailingAccessory ? .bottomLeading : .bottomTrailing) {
                if followPlayback == false, activeSegmentID != nil {
                    Button {
                        followPlayback = true
                        scroll(to: activeSegmentID, with: proxy, animated: true)
                    } label: {
                        Label("Follow", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Follow playback")
                    .accessibilityHint("Scrolls the transcript back to the line that is playing")
                    .accessibilityInputLabels([Text("Follow captions"), Text("Follow playback")])
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .onAppear {
                rebuildSegments()
                if canFollowPlayback {
                    tracker.start(segments: segments, episodeURL: transcriptLines.first?.episode?.url ?? Player.shared.currentEpisodeURL, useAlignment: usesPublisherAlignment)
                }
                scroll(to: activeSegmentID, with: proxy, animated: false)
            }
            .onDisappear { tracker.stop() }
            .onChange(of: currentTime) { tracker.refresh() }
            .onChange(of: Player.shared.currentEpisodeURL) {
                followPlayback = true
                tracker.update(segments: segments, episodeURL: transcriptLines.first?.episode?.url ?? Player.shared.currentEpisodeURL, useAlignment: usesPublisherAlignment)
            }
            .onChange(of: canFollowPlayback) {
                if canFollowPlayback {
                    tracker.start(segments: segments, episodeURL: transcriptLines.first?.episode?.url ?? Player.shared.currentEpisodeURL, useAlignment: usesPublisherAlignment)
                } else { tracker.stop() }
            }
            .onChange(of: transcriptLines) {
                rebuildSegments()
                tracker.update(segments: segments, episodeURL: transcriptLines.first?.episode?.url ?? Player.shared.currentEpisodeURL, useAlignment: usesPublisherAlignment)
                scroll(to: activeSegmentID, with: proxy, animated: false)
            }
            .onChange(of: activeSegmentID) {
                scroll(to: activeSegmentID, with: proxy, animated: true)
            }
        }
        .accessibilityLabel("Transcript")
    }

    @ViewBuilder
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        let isActive = segment.id == activeSegmentID
        let hasWordLevelTiming = isActive
            && tracker.active?.location != nil
            && tracker.active?.length != nil

        VStack(alignment: .leading, spacing: 2) {
            if let speaker = segment.speaker, speakerHeaderIDs.contains(segment.id) {
                Text("\(speaker):")
                    .font(.headline)
                    .foregroundColor(differentiateWithoutColor ? .primary : (speakerColorMap[speaker] ?? .accent))
            }

            segment.highlightedText(tracker.active)
                .font(.body)
                .foregroundStyle(isActive ? .primary : .secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(followPlayback && hasWordLevelTiming ? 2 : nil)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullTranscript?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? Text("Current caption") : Text("Caption"))
        .accessibilityValue(segment.speaker == nil ? segment.text : "\(segment.speaker!), \(segment.text)")
        .accessibilityAddTraits(onOpenFullTranscript == nil ? AccessibilityTraits() : AccessibilityTraits.isButton)
    }

    private var activeSegmentID: UUID? {
        tracker.active?.segmentID
    }

    private var visibleSegments: [TranscriptSegment] {
        guard followPlayback else { return segments }
        if let activeSegmentID,
           let active = segments.first(where: { $0.id == activeSegmentID }) {
            return [active]
        }
        if let current = segments.last(where: { $0.startTime <= currentTime }) {
            return [current]
        }
        return Array(segments.prefix(1))
    }

    private func scroll(to id: UUID?, with proxy: ScrollViewProxy, animated: Bool) {
        guard followPlayback, let id else { return }

        if animated && !reduceMotion {
            withAnimation(.snappy(duration: 0.2, extraBounce: 0.0)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func rebuildSegments() {
        let newSegments = TranscriptSegmentBuilder.makeSegments(
            from: transcriptLines,
            options: .compact
        )
        segments = newSegments
        speakerHeaderIDs = Self.makeSpeakerHeaderIDs(from: newSegments)
        speakerColorMap = makeSpeakerColorMap(from: newSegments)
    }

    /// Identifiers of the segments that start a new speaker turn and therefore show a name.
    private static func makeSpeakerHeaderIDs(from segments: [TranscriptSegment]) -> Set<UUID> {
        var ids: Set<UUID> = []
        var previousSpeaker: String?

        for segment in segments {
            if segment.speaker != previousSpeaker {
                ids.insert(segment.id)
            }
            previousSpeaker = segment.speaker
        }

        return ids
    }

    private func makeSpeakerColorMap(from segments: [TranscriptSegment]) -> [String: Color] {
        var colorMap: [String: Color] = [:]
        let speakers = Set(segments.compactMap(\.speaker)).sorted(by: <)

        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }

        return colorMap
    }

}
