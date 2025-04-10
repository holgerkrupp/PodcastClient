import SwiftUI

struct TranscriptListView: View {
    let vttContent: String
    @State private var searchText: String = ""
    
    // Predefined colors for speakers
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
        let speakers = Set(filteredLines.compactMap { $0.speaker })
        
        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }
        
        return colorMap
    }
    
    private var filteredLines: [TranscriptLineWithTime] {
        let allLines = parseAllLines()
        if searchText.isEmpty {
            return allLines
        }
        return allLines.filter { line in
            line.text.localizedCaseInsensitiveContains(searchText) ||
            (line.speaker?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var body: some View {
        VStack {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search transcript...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // Transcript list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedLines(), id: \.id) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(formatTime(group.startTime))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                if let speaker = group.speaker {
                                    Text("\(speaker):")
                                        .font(.headline)
                                        .foregroundColor(speakerColorMap[speaker] ?? .accent)
                                }
                            }
                            Text(group.text)
                                .font(.body)
                                .foregroundColor(.primary)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Player.shared.jumpTo(time: group.startTime)
                                }
                        }
                        .padding(.horizontal)
                        Divider()
                    }
                }
            }
        }
    }
    
    private func groupedLines() -> [TranscriptLineWithTime] {
        var grouped: [TranscriptLineWithTime] = []
        var currentSpeaker: String?
        
        for line in filteredLines {
            if let speaker = line.speaker {
                // New speaker or first line
                if speaker != currentSpeaker {
                    currentSpeaker = speaker
                    grouped.append(line)
                } else {
                    // Same speaker, append text to the last entry
                    if var lastLine = grouped.last {
                        lastLine.text += " " + line.text
                        grouped[grouped.count - 1] = lastLine
                    }
                }
            } else {
                // No speaker, always add as new line
                grouped.append(line)
                currentSpeaker = nil
            }
        }
        
        return grouped
    }
    
    private func parseAllLines() -> [TranscriptLineWithTime] {
        let linesArray = vttContent.components(separatedBy: .newlines)
        var transcriptLines: [TranscriptLineWithTime] = []
        var currentIndex = 0
        
        // Find the first timestamp line
        while currentIndex < linesArray.count {
            let line = linesArray[currentIndex]
            if line.contains(" --> ") {
                break
            }
            currentIndex += 1
        }
        
        // Process transcript lines
        while currentIndex < linesArray.count {
            // Skip empty lines
            while currentIndex < linesArray.count && linesArray[currentIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentIndex += 1
            }
            
            // Check if we've reached the end of the file
            if currentIndex >= linesArray.count {
                break
            }
            
            // Process timestamp line
            let timestampLine = linesArray[currentIndex]
            let timestampComponents = timestampLine.components(separatedBy: " --> ")
            
            if timestampComponents.count == 2,
               let startTime = timestampComponents[0].durationAsSeconds,
               let endTime = timestampComponents[1].durationAsSeconds {
                
                // Move to the next line which should contain the transcript text
                currentIndex += 1
                if currentIndex < linesArray.count {
                    let (speaker, text) = separateSpeakerAndText(from: linesArray[currentIndex])
                    transcriptLines.append(TranscriptLineWithTime(
                        id: UUID(),
                        speaker: speaker,
                        text: text,
                        startTime: startTime,
                        endTime: endTime
                    ))
                }
            }
            
            currentIndex += 1
        }
        
        return transcriptLines
    }
    
    private func separateSpeakerAndText(from line: String) -> (speaker: String?, text: String) {
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
    
    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct TranscriptLineWithTime: Identifiable {
    let id: UUID
    let speaker: String?
    var text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
} 
