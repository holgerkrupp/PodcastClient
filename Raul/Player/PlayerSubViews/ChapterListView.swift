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
        let categoryGroups = Dictionary(grouping: episode.chapters, by: { $0.title + (Duration.seconds($0.start ?? 0).formatted(.units(width: .narrow))) })
        return categoryGroups.values.flatMap { group in
            let highestCategory = group.max(by: { preferredOrder.firstIndex(of: $0.type) ?? 0 < preferredOrder.firstIndex(of: $1.type) ?? preferredOrder.count })?.type
            return group.filter { $0.type == highestCategory }
        }
    }
    
    private var sortedChapters: [Marker] {
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
                    Spacer()
                }
                .padding()
               
                ForEach(sortedChapters, id: \.id) { chapter in
                    ZStack{
                        GeometryReader { geometry in
                            // Background layer
                            
                            if chapter.id == player.currentChapter?.id {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.1))
                                    .frame(width: geometry.size.width * (player.chapterProgress ?? 0.0), height: geometry.size.height)
                            } else {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.1))
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
                
                if let chapterInfo = episode.chapters.first?.type.desc {
                    Spacer()
                    Text(chapterInfo)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding()
                }
            }
        }
    }
}

