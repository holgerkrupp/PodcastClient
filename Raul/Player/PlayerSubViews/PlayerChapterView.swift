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

    var body: some View {
        if player.currentEpisode?.preferredChapters.count ?? 0 > 0{
           
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
                if let chapters = player.currentEpisode?.preferredChapters.sorted(by: { $0.start ?? 0 < $1.start ?? 0}){
                    VStack{
                        Button {
                            
                            presentingModal = true
                            
                            
                        } label: {
                            
                            Text(player.currentChapter?.title ?? "")
                                .foregroundStyle(Color.primary)
                                .minimumScaleFactor(0.5)
                            
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $presentingModal, content: {
                            ChapterListView(episodeURL: player.currentEpisode?.url)
                                .presentationDragIndicator(.visible)
                                .presentationBackground(.thinMaterial)
                        })
                        if let remaining = player.currentChapter?.remainingTime?.secondsToHoursMinutesSeconds{
                            Text(remaining)
                                .font(.caption)
                                .monospaced()
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
