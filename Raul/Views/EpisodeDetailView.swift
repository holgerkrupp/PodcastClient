//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI

struct EpisodeDetailView: View {
    
    enum Selection {
        case chapters, transcript
    }
    @State private var listSelection:Selection = .chapters
    
    
    @State var episode: Episode
    @State private var image: Image?
    var body: some View {
        ScrollView {
            
       
        HStack {
            EpisodeCoverView(episode: episode)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading) {
                HStack {
                    Text(episode.podcast?.title ?? "")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text((episode.publishDate?.formatted(date: .numeric, time: .shortened) ?? ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(4)
                    .minimumScaleFactor(0.1)
                    .truncationMode(.tail)
                if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                        Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }else{
                        Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

              
            }
        }
        Spacer(minLength: 10)
        ExpandableTextView(text: episode.desc ?? "")
                
                .lineLimit(10)
                .padding()
       
        if let episodeLink = episode.link {
            Link(destination: episodeLink) {
                Text("Open in Safari")
            }
        }
            
            Picker(selection: $listSelection) {
                if episode.preferredChapters.count > 0{
                    Text("Chapters").tag(Selection.chapters)
                }
                if episode.transcriptData != nil{
                    Text("Transcript").tag(Selection.transcript)
                }
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
            
            switch listSelection {
            case .chapters:
                if episode.preferredChapters.count > 0 {
                    ChapterListView(chapters: episode.preferredChapters)
                }
            case .transcript:
                if let vttFileContent = episode.transcriptData
                    {
            
                    TranscriptListView(vttContent: vttFileContent)
                   
                }else{
                    Text("no transcript available")
                }
            }
        }
       
    }

}
