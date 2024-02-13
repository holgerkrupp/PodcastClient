//
//  TranscriptScollView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 11.02.24.
//

import SwiftUI
import AVKit


/*
 
 
struct TranscriptScrollView: View {
    let vttContent: String
    @Binding var currentTime: TimeInterval
    
    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines()) { line in
                        VStack(alignment: .leading) {
                            Text("\(line.speaker):")
                                .font(.headline)
                                .foregroundColor(.blue)
                            Text(line.text)
                                .font(.body)
                        }
                        .id(line.id)
                        .onAppear {
                            // Scroll to the current time when the line appears
                            if line.startTime <= currentTime && currentTime <= line.endTime {
                                scrollView.scrollTo(line.id, anchor: .top)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationBarTitle("Transcript")
            .onAppear {
                // Scroll to the initial position when the view appears
                let initialLine = lines().first
                scrollView.scrollTo(initialLine?.id, anchor: .top)
            }
        }
    }

    
    private func lines() -> [TranscriptLine] {
        let linesArray = vttContent.components(separatedBy: .newlines)
        var transcriptLines: [TranscriptLine] = []
        var currentTime: TimeInterval = 0
        
        for lineIndex in stride(from: 3, to: linesArray.count, by: 4) {
            let timestampComponents = linesArray[lineIndex - 1].components(separatedBy: " --> ")
            if let startTime = (timestampComponents.first ?? "0").durationAsSeconds,
               let endTime = (timestampComponents.last ?? "0").durationAsSeconds{
                let speakerTag = linesArray[lineIndex - 2]
                let speaker = speakerTag.replacingOccurrences(of: "<v ", with: "").replacingOccurrences(of: ">", with: "")
                let text = linesArray[lineIndex]
                transcriptLines.append(TranscriptLine(id: UUID(), speaker: speaker, text: text, startTime: startTime, endTime: endTime))
            }
        }
        
        return transcriptLines
    }
}

struct TranscriptLine: Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let startTime: Double
    let endTime: Double
}

*/


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

