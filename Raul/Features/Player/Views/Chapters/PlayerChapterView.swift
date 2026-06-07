//
//  PlayerChapterView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI

struct PlayerChapterView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State var player = Player.shared
    @State var presentingModal = false

    
    init(){
        // print("PlayerChapterView \(player.currentEpisode?.id.uuidString ?? "NO UUID")")
        // print("loading PlayerChapterView with \(String(describing: player.currentEpisode?.preferredChapters.count.description)) Chapters")
        // print("currentChapter: \(player.currentChapter?.title ?? "nil")")
    }
    
    var body: some View {
        if player.currentEpisode?.preferredChapters.count ?? 0 > 1{
          //  GlassEffectContainer(spacing: 20){
                HStack(spacing: 0.0) {
                    Spacer()
                        .frame(width: 50)
                    Button {
                        Task{
                            await player.skipToChapterStart()
                        }
                    } label: {
                        SkipBackView()
                            .aspectRatio(contentMode: .fit)
                            .tint(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous chapter")
                    .accessibilityHint("Skips to the start of the previous chapter")
                    .accessibilityInputLabels([Text("Previous chapter"), Text("Back chapter")])
                    
                    
                    Spacer()
                    
                    
                    ZStack{
                        
                        Rectangle()
                            .fill(Color.accent.opacity(0.05))
                        //  .frame(width: geo.size.width * (fakeProgress ?? player.progress))
                            .scaleEffect(x: (player.currentChapter?.progress ?? 0.0), y: 1, anchor: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                if differentiateWithoutColor {
                                    Rectangle()
                                        .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
                                }
                            }
                        
                        
                        
                            Button {
                                
                                presentingModal = true
                                
                                
                            } label: {
                                VStack{
                                    Text(player.currentChapter?.displayTitle ?? "unknown current Chapter")
                                        .foregroundStyle(Color.primary)
                                        .minimumScaleFactor(0.5)
                                    if let remaining = player.currentChapter?.remainingTime {
                                        Text(Duration.seconds(remaining).formatted(.units(width: .narrow)))
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open chapter list")
                            .accessibilityHint("Shows all chapter markers")
                            .accessibilityInputLabels([Text("Open chapters"), Text("Chapter list")])
                            
                            .sheet(isPresented: $presentingModal, content: {
                                if let episode = player.currentEpisode{
                                    ChapterListView(episode: episode)
                                        .presentationDragIndicator(.visible)
                                        .presentationBackground(.thinMaterial)
                                }
                                
                            })
                            

                            
                        
                    }
                    
                    
                    Spacer()
                    
                    
                    
                   
                    Button {
                        Task{
                            await player.skipToNextChapter()
                        }
                    } label: {
                        SkipNextView(progress: player.chapterProgress ?? 0.0)
                            .aspectRatio(contentMode: .fit)
                            .tint(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next chapter")
                    .accessibilityHint("Skips to the next chapter")
                    .accessibilityInputLabels([Text("Next chapter"), Text("Forward chapter")])
                    
                    Spacer()
                        .frame(width: 50)
                    
                }.frame(maxWidth: .infinity, maxHeight: 40)
          //  }
            
         //   .background(.ultraThinMaterial)

        }
            
    }
    

}

extension Episode {
    static var preview: Episode {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Preview Podcast"

        let episode = Episode(
            title: "Building a Better Podcast App",
            url: URL(string: "https://example.com/audio/episode.mp3")!,
            podcast: podcast,
            duration: 3600,
            author: "Preview Host"
        )

        let chapters = [
            Marker(start: 0, title: "Cold Open", type: .mp3, duration: 180),
            Marker(start: 180, title: "Designing the Player", type: .mp3, duration: 720),
            Marker(start: 900, title: "Chapter Data and Shownotes", type: .mp3, duration: 960),
            // ... other chapters
        ]
        
        chapters.forEach { chapter in
            chapter.episode = episode
            
        }
        chapters[2].progress = 0.42
        episode.chapters = chapters
        
        return episode
    }
}

#Preview {
    struct PreviewWrapper: View {
        init() {
            // Because this is in init(), it is GUARANTEED to run
            // completely before PlayerChapterView is ever created.
            let episode = Episode.preview // Assuming you made this extension!
            
            Player.shared.currentEpisode = episode
            Player.shared.playPosition = 1300
            Player.shared.chapters = episode.chapters
            Player.shared.currentChapter = episode.chapters?[1]
            Player.shared.nextChapter = episode.chapters?[2]
            Player.shared.chapterProgress = episode.chapters?[1].progress
        }

        var body: some View {
            PlayerChapterView()
        }
    }

    return PreviewWrapper()
}
