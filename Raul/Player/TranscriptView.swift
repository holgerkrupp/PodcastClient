//
//  TranscriptScollView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI
import AVKit

struct TranscriptLine: Identifiable, Hashable {
    let id = UUID()
    let speaker: String?
    let text: String
}


struct TranscriptView: View {
    let vttContent: String
    @Binding var currentTime: TimeInterval
    
    var body: some View {
       
            VStack(alignment: .leading, spacing: 10) {
                
                ForEach(lines(for: currentTime), id: \.id) { line in
                    VStack(alignment: .leading) {
                        if let speaker = line.speaker{
                            Text("\(speaker):")
                                .font(.headline)
                                .foregroundColor(.accent)
                                .padding()
                                .frame(maxWidth: .infinity)
                        }
                        Text(line.text)
                            .font(.body)
                            .padding()
                    }
                    
                    
                }
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            
       
    }
    
    private func lines(for currentTime: TimeInterval) -> [TranscriptLine] {
        let linesArray = vttContent.components(separatedBy: .newlines)
        var currentLines: [TranscriptLine] = []
        
        for lineIndex in stride(from: 3, to: linesArray.count, by: 1) {
            let timestampComponents = linesArray[lineIndex - 1].components(separatedBy: " --> ")
            if let startTime = (timestampComponents.first ?? "0").durationAsSeconds,
               let endTime = (timestampComponents.last ?? "0").durationAsSeconds,
               startTime <= currentTime && currentTime <= endTime {

                
                let (speaker, text) = separateSpeakerAndText(from: linesArray[lineIndex])
                currentLines.append(TranscriptLine(speaker: speaker, text: text))
            }
        }
        
        return currentLines
    }
    
    func separateSpeakerAndText(from line: String) -> (speaker: String?, text: String) {
        let components = line.components(separatedBy: ">")
        
        if components.count > 1 {
            var speaker = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker.hasPrefix("<v ") {
                speaker.removeFirst(3)
                
            }
            
            
            let text = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (speaker, text)
        } else {
            return (nil, line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

