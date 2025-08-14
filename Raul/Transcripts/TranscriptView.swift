//
//  TranscriptScollView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI

struct TranscriptLine: Identifiable, Hashable {
    let id = UUID()
    let speaker: String?
    let text: String
}


struct TranscriptView: View {
   // let decoder: TranscriptDecoder
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
    
    private var speakerColorMap: [String: Color] {
        var colorMap: [String: Color] = [:]
        let speakers = Set(transcriptLines.compactMap { $0.speaker }).removingDuplicates().sorted(by: <)
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
                        .foregroundColor(speakerColorMap[speaker] ?? .accent)
                        .transition(.opacity)
                }
                Text(line.text)
                    .font(.body)
                    .transition(.opacity)
                    .minimumScaleFactor(0.5)
               
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .animation(.easeInOut(duration: 0.3), value: currentLine?.id)
        } else {
            EmptyView()
        }
    }
    /*
    private var currentLine: TranscriptDecoder.TranscriptLineWithTime? {
        decoder.transcriptLines.first { line in
            currentTime >= line.startTime && currentTime <= line.endTime
        }
    }
    */
    private var currentLine: TranscriptLineAndTime? {
        transcriptLines.first { line in
            currentTime >= line.startTime && currentTime <= line.endTime ?? TimeInterval.infinity
        }
    }
    
}
