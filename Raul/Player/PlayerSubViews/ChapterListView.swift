//
//  ChapterListView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI
import SwiftData

struct ChapterListView: View {
    @Environment(\.modelContext) private var modelContext
    var player = Player.shared


    let episodeURL: URL?

    @Query var chapters: [Chapter]

    
    init(episodeURL: URL?) {
        self.episodeURL = episodeURL
    
        // Set up the query with a filter that uses the instance value
        _chapters = Query(filter: #Predicate<Chapter> {
            $0.episode?.url == episodeURL
        })
    }
    
    private var preferredChapters: [Chapter] {

        let preferredOrder: [ChapterType] = [.mp3, .mp4, .podlove, .extracted, .ai]
        
        let categoryGroups = Dictionary(grouping: chapters, by: { $0.title + (Duration.seconds($0.start ?? 0).formatted(.units(width: .narrow))) })
        
        return categoryGroups.values.flatMap { group in
            let highestCategory = group.max(by: { preferredOrder.firstIndex(of: $0.type) ?? 0 < preferredOrder.firstIndex(of: $1.type) ?? preferredOrder.count })?.type
          //  print(highestCategory?.rawValue ?? "no category")
            return group.filter { $0.type == highestCategory }
        }
    }
    
    private var sortedChapters: [Chapter] {
        preferredChapters.sorted(by: { first, second in
            first.start ?? 0.0 < second.start ?? 0
        })
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Chapters")
                        .font(.title)
                        .padding()
                    Spacer()
                    Button(chapters.first?.type.desc ?? "Unknown") {
                        if let url = episodeURL {
                            Task{
                              await EpisodeActor(modelContainer: modelContext.container).updateChapterDurations(episodeURL: url)
                            }}
                    }
                        .font(.caption)
                }
                .padding()
               
                
                ForEach(sortedChapters, id: \.id) { chapter in
                    ZStack{
                        GeometryReader { geometry in
                            // Background layer
                            
                            if chapter.id == player.currentChapter?.id {
                                Rectangle()
                                    .fill(Color.yellow.opacity(0.1))
                                    .frame(width: geometry.size.width * (player.chapterProgress ?? 0.0), height: geometry.size.height)
                            }else{
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.05))
                                    .frame(width: geometry.size.width * (chapter.progress ?? 0.0), height: geometry.size.height)
                            }
                            
                                
                        }
                        VStack{
                            ChapterRowView(chapter: chapter)
                                .padding()
                            if chapter.id != sortedChapters.last?.id {
                                Divider()
                                    
                                  
                            }
                        }
                    }
                    
                   
                }
            }
        }
    }
}

#Preview {
    let sampleChapters = [
        Chapter(start: 5651.469, title: "Epilog", type: .mp3, duration: 226.507),
        Chapter(start: 31.319, title: "Prolog", duration: 175.654),
        Chapter(start: 0.0, title: "Intro", duration: 31.319),
        Chapter(start: 4849.457, title: "Palantir", duration: 461.69),
        Chapter(start: 4357.445, title: "Open Technology Fund", duration: 321.905),
        Chapter(start: 5311.147, title: "Altersverifikation", duration: 340.322),
        Chapter(start: 206.973, title: "Feedback: Propaganda", duration: 159.488),
        Chapter(start: 1042.935, title: "Signalgate", duration: 1607.82),
        Chapter(start: 4679.35, title: "Chatkontrolle", duration: 82.117),
        Chapter(start: 642.922, title: "Feedback: Digitalministerium", duration: 400.013),
        Chapter(start: 2650.755, title: "Informationsfreiheitsgesetz", duration: 1706.69),
        Chapter(start: 366.461, title: "Feedback: Isländische Fussballmannschaft", duration: 152.857),
        Chapter(start: 4761.467, title: "CDU und AfD in Umfragen gleichauf", duration: 87.99),
        Chapter(start: 519.318, title: "Feedback: Leuchttürme", duration: 123.604)
    ]
    
    
    ChapterListView(episodeURL: URL(string: ""))
}
