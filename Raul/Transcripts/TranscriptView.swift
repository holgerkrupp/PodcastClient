//
//  TranscriptScollView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI
import Combine

struct TranscriptLine: Identifiable, Hashable {
    let id = UUID()
    let speaker: String?
    let text: String
}


struct TranscriptView: View {
   // let decoder: TranscriptDecoder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let transcriptLines: [TranscriptLineAndTime]
    @Binding var currentTime: TimeInterval
    
    private let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]
    
    @State private var speakerColorMap: [String: Color] = [:]
    
    private func computeSpeakerColorMap() -> [String: Color] {
        var colorMap: [String: Color] = [:]
        let speakers = Set(transcriptLines.compactMap { $0.speaker }).sorted(by: <)
        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }
        return colorMap
    }
    
    var body: some View {
        if let line = currentLine {
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = line.speaker {
                    Text("\(speaker):")
                        .font(.headline)
                        .foregroundColor(differentiateWithoutColor ? .primary : (speakerColorMap[speaker] ?? .accent))
                        .transition(reduceMotion ? .identity : .opacity)
                }
                Text(line.text)
                    .font(.body)
                    .transition(reduceMotion ? .identity : .opacity)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
               
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: currentLine?.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current caption")
            .accessibilityValue(line.speaker == nil ? line.text : "\(line.speaker!), \(line.text)")
            .onAppear {
                self.speakerColorMap = computeSpeakerColorMap()
            }
            .onChange(of: transcriptLines) {
                self.speakerColorMap = computeSpeakerColorMap()
            }
        } else {
            Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                self.speakerColorMap = computeSpeakerColorMap()
            }
            .onChange(of: transcriptLines) {
                self.speakerColorMap = computeSpeakerColorMap()
            }
        }
    }
    /*
    private var currentLine: TranscriptDecoder.TranscriptLineWithTime? {
        decoder.transcriptLines.first { line in
            currentTime >= line.startTime && currentTime <= line.endTime
        }
    }
    */
    
    private func findCurrentLineIndex(for time: TimeInterval) -> Int? {
        var low = 0
        var high = transcriptLines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let line = transcriptLines[mid]
            let end = line.endTime ?? .infinity
            if time >= line.startTime && time <= end {
                return mid
            } else if time < line.startTime {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return nil
    }

    private var currentLine: TranscriptLineAndTime? {
        guard let idx = findCurrentLineIndex(for: currentTime) else { return nil }
        return transcriptLines[idx]
    }
    
}
