//
//  TranscriptView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI
import Combine

/// Compact, scrollable transcript used inside the player.
///
/// Short lines coming from automatic transcriptions are merged into readable
/// paragraphs by ``TranscriptSegmentBuilder``. The list follows playback, but the
/// user can scroll freely at any time and jump back to the current position.
struct TranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let transcriptLines: [TranscriptLineAndTime]
    @Binding var currentTime: TimeInterval
    /// Called when the user taps a caption, e.g. to open the full transcript.
    var onOpenFullTranscript: (() -> Void)?

    @State private var segments: [TranscriptSegment] = []
    @State private var speakerHeaderIDs: Set<UUID> = []
    @State private var speakerColorMap: [String: Color] = [:]
    @State private var followPlayback: Bool = true

    private let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in
                        segmentView(segment)
                            .id(segment.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in
                        guard followPlayback else { return }
                        followPlayback = false
                    }
            )
            .overlay(alignment: .bottomTrailing) {
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
                scroll(to: activeSegmentID, with: proxy, animated: false)
            }
            .onChange(of: transcriptLines) {
                rebuildSegments()
                // A different episode starts over, following playback again.
                followPlayback = true
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

        VStack(alignment: .leading, spacing: 2) {
            if let speaker = segment.speaker, speakerHeaderIDs.contains(segment.id) {
                Text("\(speaker):")
                    .font(.headline)
                    .foregroundColor(differentiateWithoutColor ? .primary : (speakerColorMap[speaker] ?? .accent))
            }

            Text(segment.text)
                .font(.body)
                .foregroundStyle(isActive ? .primary : .secondary)
                .multilineTextAlignment(.leading)
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
        guard currentTime.isFinite else { return nil }
        return segmentID(at: currentTime)
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

    /// Binary search for the segment covering `time`, falling back to the last
    /// segment that already started so gaps between segments stay highlighted.
    private func segmentID(at time: TimeInterval) -> UUID? {
        guard segments.isEmpty == false else { return nil }
        guard time >= segments[0].startTime else { return nil }

        var low = 0
        var high = segments.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            let end = effectiveEndTime(for: mid)

            if time < segment.startTime {
                high = mid - 1
            } else if time >= end {
                low = mid + 1
            } else {
                return segment.id
            }
        }

        let fallbackIndex = max(0, min(low - 1, segments.count - 1))
        return segments[fallbackIndex].id
    }

    private func effectiveEndTime(for index: Int) -> TimeInterval {
        if let endTime = segments[index].endTime {
            return endTime
        }

        if index + 1 < segments.count {
            return segments[index + 1].startTime
        }

        return .infinity
    }
}
