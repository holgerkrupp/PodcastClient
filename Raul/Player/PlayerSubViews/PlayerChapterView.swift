//
//  PlayerChapterView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI

struct PlayerChapterView: View {
    @State var player = Player.shared
    @State var presentingModal = false

    
    init(){
        // print("PlayerChapterView \(player.currentEpisode?.id.uuidString ?? "NO UUID")")
        // print("loading PlayerChapterView with \(String(describing: player.currentEpisode?.preferredChapters.count.description)) Chapters")
        // print("currentChapter: \(player.currentChapter?.title ?? "nil")")
        
        for chapter in player.currentEpisode?.preferredChapters ?? [] {
            // print("\(chapter.title): \(chapter.start?.description ?? <#default value#>) - \(String(describing: chapter.endTime?.description)) - \(chapter.type.rawValue)")
        }
    }
    
    var body: some View {
        if player.currentEpisode?.preferredChapters.count ?? 0 > 1{
           
            HStack{
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
                
                
                Spacer()
              
                
                ZStack{

                    Rectangle()
                        .fill(Color.accent.opacity(0.05))
                      //  .frame(width: geo.size.width * (fakeProgress ?? player.progress))
                        .scaleEffect(x: (player.currentChapter?.progress ?? 0.0), y: 1, anchor: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    
                    VStack{
                        Button {
                            
                            presentingModal = true
                            
                            
                        } label: {
                            
                            Text(player.currentChapter?.title ?? "unknown current Chapter")
                                .foregroundStyle(Color.primary)
                                .minimumScaleFactor(0.5)
                            
                        }
                        .buttonStyle(.plain)
                        
                        .sheet(isPresented: $presentingModal, content: {
                            if let episode = player.currentEpisode{
                                ChapterListView(episode: episode)
                                    .presentationDragIndicator(.visible)
                                    .presentationBackground(.thinMaterial)
                            }
                            
                        })
                         
                        if let remaining = player.currentChapter?.remainingTime {
                            Text(Duration.seconds(remaining).formatted(.units(width: .narrow)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                            
                }
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
                
                Spacer()
                    .frame(width: 50)
               
            }
            .frame(maxWidth: .infinity, maxHeight: 40)
         //   .background(.ultraThinMaterial)

        }
            
    }
    

}

#Preview {
    PlayerChapterView()
}
