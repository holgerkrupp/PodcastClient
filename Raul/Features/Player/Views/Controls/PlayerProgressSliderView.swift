//
//  PlayerProgressSliderView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 19.01.24.
//

import SwiftUI
import ESADesignKit
#if os(iOS)
import UIKit
#endif

struct PlayerProgressSliderView: View {
    @Environment(\.esaThemePalette) private var themePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double
    @Binding var markers: [Marker]?
    @State var allowTouch: Bool = true
    var chapterTimelineDuration: Double?
    var adSegments: [AdSegment] = []
    var onEditingChanged: ((Bool, Double) -> Void)?
    
    @State var lastCoordinateValue: CGFloat = 0.0
    @State private var isEditing = false
    @State private var editingValue: Double?
    @State private var lastSnappedChapter: Double?
    var sliderRange: ClosedRange<Double> = 1...100
    var thumbColor: Color = .yellow
    var minTrackColor: Color = .blue
    var maxTrackColor: Color = .gray
    
    var body: some View {
        GeometryReader { gr in
         //   let thumbHeight = gr.size.height * 1.0
         //   let thumbWidth = gr.size.width * 0.03
            let radius = gr.size.height * 0.3
            let minValue = 0.0
            let maxValue = (gr.size.width)
            
            let scaleFactor = (maxValue - minValue) / (sliderRange.upperBound - sliderRange.lowerBound)
            let lower = sliderRange.lowerBound
            let sliderVal = abs((self.value - lower) * scaleFactor + minValue)
            
            let chapterMarkerPositions = chapterMarkerPositions(width: gr.size.width)
            let adRangeRects = advertisementRangeRects(width: gr.size.width)
            let trackShape = RoundedRectangle(cornerRadius: radius)
            
            ZStack {
                trackShape
                
                               .fill(.ultraThinMaterial)
                    .frame(width: gr.size.width, height: gr.size.height)
                /*
                if player.currentEpisode.url == episode.url {
                    if maxProgress > self.value {
                        Rectangle()
                            .fill(Color.red.opacity(0.7))
                            .frame(width: 2, height: gr.size.height * 0.85)
                            .position(x: maxPlayProgressVal, y: gr.size.height / 2)
                    }
                }
                 */
            
                HStack {
                    Rectangle()
                     //   .fill(.thinMaterial)
                        .foregroundColor(.accent)
                       
                        .frame(width: sliderVal, height: gr.size.height)
                    Spacer()
                }
                .clipShape(trackShape)
                if markers != nil {
                    ZStack {
                        ForEach(Array(chapterMarkerPositions.enumerated()), id: \.offset) { _, xPosition in
                            Rectangle()
                                .fill(themePalette.primaryForeground.opacity(0.25))
                                .frame(width: 1.5, height: gr.size.height)
                                .position(x: xPosition, y: gr.size.height / 2)
                                .shadow(color: .black.opacity(0.25), radius: 0.5, x: 0, y: 0)
                        }
                    }
                    .frame(width: gr.size.width, height: gr.size.height)
                    .clipShape(trackShape)
                }

                if adRangeRects.isEmpty == false {
                    ForEach(Array(adRangeRects.enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.orange.opacity(0.82))
                            .frame(width: max(rect.width, 3), height: gr.size.height * 0.55)
                            .position(x: rect.midX, y: gr.size.height / 2)
                            .accessibilityHidden(true)
                    }
                }

            }
            .contentShape(Rectangle())
            .gesture(

                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if allowTouch{
                            if isEditing == false {
                                isEditing = true
                                onEditingChanged?(true, value)
                            }
                            if (abs(v.translation.width) < 0.1) {
                                self.lastCoordinateValue = sliderVal
                            }
                            if v.translation.width > 0 {
                                let nextCoordinateValue = min(maxValue, self.lastCoordinateValue + v.translation.width)

                                let nextValue = snappedValue(((nextCoordinateValue - minValue) / scaleFactor) + lower)
                                editingValue = nextValue
                                self.value = nextValue
                            } else {
                                let nextCoordinateValue = max(minValue, self.lastCoordinateValue + v.translation.width)
                                let nextValue = snappedValue(((nextCoordinateValue - minValue) / scaleFactor) + lower)
                                editingValue = nextValue
                                self.value = nextValue
                            }
                        }else{
                            // print("not allowed")
                        }
                    }
                    .onEnded { _ in
                        guard allowTouch, isEditing else { return }
                        let finalValue = editingValue ?? value
                        isEditing = false
                        editingValue = nil
                        lastSnappedChapter = nil
                        onEditingChanged?(false, finalValue)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(accessibilityProgressValue)
            .accessibilityHint(allowTouch ? "Adjusts the current playback position" : "Playback scrubbing is disabled")
            .accessibilityAdjustableAction { direction in
                guard allowTouch else { return }
                let step = max((sliderRange.upperBound - sliderRange.lowerBound) / 20, 0.01)
                let adjustedValue: Double
                switch direction {
                case .increment:
                    adjustedValue = min(sliderRange.upperBound, self.value + step)
                case .decrement:
                    adjustedValue = max(sliderRange.lowerBound, self.value - step)
                @unknown default:
                    return
                }
                onEditingChanged?(true, value)
                self.value = adjustedValue
                onEditingChanged?(false, adjustedValue)
            }
        }
    }

    private var accessibilityProgressValue: String {
        let progress = max(min((value - sliderRange.lowerBound) / max(sliderRange.upperBound - sliderRange.lowerBound, 0.0001), 1), 0)
        let timelineValue = (chapterTimelineDuration ?? 0) * value
        let time = Duration.seconds(max(timelineValue, 0)).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        if let chapter = markers?.filter({ $0.type != .bookmark && $0.shouldPlay }).compactMap({ marker -> (Double, String)? in
            guard let start = marker.start, start <= timelineValue else { return nil }
            return (start, marker.title)
        }).max(by: { $0.0 < $1.0 }) {
            return "\(time), \(chapter.1), \(progress.formatted(.percent.precision(.fractionLength(0))))"
        }
        return "\(time), \(progress.formatted(.percent.precision(.fractionLength(0))))"
    }

    private func snappedValue(_ proposedValue: Double) -> Double {
        guard let duration = chapterTimelineDuration, duration > 0,
              let chapters = markers else { return proposedValue }
        let timelineValue = proposedValue * duration
        guard let nearest = Self.chapterSnapTarget(
            proposedValue: timelineValue,
            duration: duration,
            range: (sliderRange.lowerBound * duration)...(sliderRange.upperBound * duration),
            markers: chapters,
            tolerance: min(8, duration * 0.01)
        ) else {
            lastSnappedChapter = nil
            return proposedValue
        }
        if lastSnappedChapter != nearest {
            #if os(iOS)
            if !reduceMotion {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            #endif
            lastSnappedChapter = nearest
        }
        return nearest / duration
    }

    static func chapterSnapTarget(
        proposedValue: Double,
        duration: Double,
        range: ClosedRange<Double>,
        markers: [Marker],
        tolerance: Double
    ) -> Double? {
        guard proposedValue.isFinite, duration.isFinite, duration > 0,
              tolerance.isFinite, tolerance >= 0 else { return nil }
        return markers
            .filter { $0.type != .bookmark && $0.shouldPlay }
            .compactMap(\.start)
            .filter { $0.isFinite && $0 >= range.lowerBound && $0 <= range.upperBound }
            .min { abs($0 - proposedValue) < abs($1 - proposedValue) }
            .flatMap { abs($0 - proposedValue) <= tolerance ? $0 : nil }
    }

    private func chapterMarkerPositions(width: CGFloat) -> [CGFloat] {
        Self.chapterMarkerPositions(
            width: width,
            duration: chapterTimelineDuration,
            markers: markers
        )
    }

    private func advertisementRangeRects(width: CGFloat) -> [CGRect] {
        guard width > 0,
              let duration = chapterTimelineDuration,
              duration > 0 else { return [] }
        return adSegments.compactMap { segment in
            guard let end = segment.end, end > segment.start else { return nil }
            let startX = width * CGFloat(min(max(segment.start / duration, 0), 1))
            let endX = width * CGFloat(min(max(end / duration, 0), 1))
            guard endX > startX else { return nil }
            return CGRect(x: startX, y: 0, width: endX - startX, height: 1)
        }
    }

    static func chapterMarkerPositions(
        width: CGFloat,
        duration: Double?,
        markers: [Marker]?
    ) -> [CGFloat] {
        guard width > 0,
              let duration,
              duration > 0,
              let chapters = markers else {
            return []
        }

        return chapters.compactMap { chapter in
            guard let start = chapter.start,
                  start > 0,
                  start < duration else {
                return nil
            }

            let progress = min(max(start / duration, 0), 1)
            return width * CGFloat(progress)
        }
    }
}


#Preview {
    @Previewable @State var progress = 0.5
    @Previewable @State var markers: [Marker]? = []
    PlayerProgressSliderView(value: $progress, markers: $markers, sliderRange: 0...1)
        .frame(height: 30)
}
