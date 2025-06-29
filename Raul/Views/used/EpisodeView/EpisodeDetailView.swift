//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var context

    enum Selection: String, CaseIterable, Hashable {
        case chapters
        case transcript
    }
    @State private var listSelection:Selection = .chapters
    
    
    @State var episode: Episode
    @State private var image: Image?
    
    var episodeDescription: AttributedString {
        HTMLTextView.parse(html: episode.content ?? episode.desc ?? "") ?? ""
    }

    
    var body: some View {
        ScrollView {
            
                HStack {
                    
                    EpisodeCoverView(episode: episode)
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading) {
                        HStack {
                            Group{
                                if let podcast = episode.podcast {
                                    NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                                        Text(podcast.title)
                                    }
                                }else{
                                    Text(episode.podcast?.title ?? "")
                                }
                            }
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
                .padding()
            
        Spacer(minLength: 10)
            

            HTMLTextView(html: episode.content ?? episode.desc ?? "")
                .padding()
                .font(.caption)
 
            
       
       
        if let episodeLink = episode.link {
            Link(destination: episodeLink) {
                Text("Open in Safari")
            }
        }
            
            Button("Extract Chapters") {
                Task{
                    await EpisodeActor(modelContainer: context.container).createChapters(episode.url)
                }
            }
            
            Picker("Show", selection: $listSelection) {
                if episode.preferredChapters.count > 0 {
                    Text("Chapters").tag(Selection.chapters)
                }
                if episode.transcriptData != nil {
                    Text("Transcript").tag(Selection.transcript)
                }
            }
            .pickerStyle(.segmented)
            .id(UUID())
            
            switch listSelection {
            case .chapters:
                if episode.preferredChapters.count > 0 {
                    ChapterListView(episodeURL: episode.url)
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
