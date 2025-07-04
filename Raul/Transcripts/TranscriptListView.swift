import SwiftUI

extension Set where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var addedDict = [Element: Bool]()

        return filter {
            addedDict.updateValue(true, forKey: $0) == nil
        }
    }

    mutating func removeDuplicates() {
        self = Set(self.removingDuplicates())
    }
}



struct TranscriptListView: View {
    let transcriptLines: [TranscriptLineAndTime]
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
        let speakers = Set(filteredLines.compactMap { $0.speaker }).removingDuplicates().sorted(by: <)
        
        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }
        
        return colorMap
    }
    
    private var filteredLines: [TranscriptLineAndTime] {
        if searchText.isEmpty {
            return transcriptLines
        }
        return transcriptLines.filter { line in
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
    
    private func groupedLines() -> [TranscriptLineAndTime] {
        var grouped: [TranscriptLineAndTime] = []
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
    
    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    // Sample transcript lines extracted and mapped from WaitingForReviewText for demonstration
    let sampleTranscriptLines: [TranscriptLineAndTime] = [
        TranscriptLineAndTime(speaker: "Daniel", text: "Dave, how do you feel about cold opens? I don't care. I'm going to open coldly. So I have a thing. have a thing where I personally with my private money, I'm sponsoring a tiny podcast.", startTime: 9.0),

    ]
    
    TranscriptListView(transcriptLines: sampleTranscriptLines)
}
