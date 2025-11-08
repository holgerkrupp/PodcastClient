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

   @Bindable var episode: Episode



    private var preferredChapters: [Marker] {
        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]
        let chapters = episode.chapters ?? []

        // Pick a single type for the whole list based on availability and preference order
        let availableTypes = Set(chapters.map { $0.type })
        if let chosenType = preferredOrder.first(where: { availableTypes.contains($0) }) {
            return chapters.filter { $0.type == chosenType }
        } else {
            // Fallback: no known preferred types found, return all chapters as-is
            return chapters
        }
    }
    
    @State private var sortedChapters: [Marker] = []
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Chapters")
                        .font(.title)
                    Spacer()
                }
                .padding()
               
                ForEach(sortedChapters, id: \.id) { chapter in
                    ZStack{
                     
                        if chapter.id == player.currentChapter?.id {
                                Rectangle()
                                    .fill(Color.accent.opacity(0.1))
                                    .scaleEffect(x: (player.chapterProgress  ?? 0.0), y: 1, anchor: .leading)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .animation(.easeInOut, value: player.chapterProgress)
                            } else {
                                Rectangle()
                                    .fill(Color.accent.opacity(0.1))
                                    .scaleEffect(x: (chapter.progress ?? 0.0), y: 1, anchor: .leading)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                
                if let chapterInfo = episode.chapters?.first?.type.desc {
                    Spacer()
                    Text(chapterInfo)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding()
                }
            }
        }
        .onAppear() {
            loadChapters()
        }
    }
    
    private func loadChapters() {
        print("Loading chapters for episode \(episode.id)")

        sortedChapters =
        preferredChapters.sorted(by: { first, second in
                first.start ?? 0.0 < second.start ?? 0
            })
    }
}

