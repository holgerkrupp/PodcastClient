//
//  ListofEpisodesView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.01.24.
//

import SwiftUI
import SwiftData

struct ListofEpisodesView: View {
    @Environment(\.modelContext) var modelContext

    @State  var episodes: [Episode]
    
    var body: some View {
        ForEach(episodes, id:\.self) { episode in
            
            EpisodeMiniView(episode: episode)
                .modelContext(modelContext)
                .swipeActions(edge: .trailing){
                    Button(role: .none) {
                        
                        episode.removeFile()
                    } label: {
                        Label("Delete File", systemImage: "externaldrive.badge.xmark")
                    }
                }
                .swipeActions(edge: .leading){
                    Button(role: .none) {
                        episode.markAsPlayed()
                        
                    } label: {
                        Label("Mark as played", systemImage: "circle.fill")
                    }
                }
                .tint(.accent)
                .contextMenu {
                    Button {
                        episode.playNow()
                    } label: {
                        Label("Play now", systemImage: "play")
                    }
                    Button {
                        PlaylistManager.shared.playnext.add(episode: episode, to: .front)
                  
                        
                    } label: {
                        Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button {
                        PlaylistManager.shared.playnext.add(episode: episode, to: .end)
                       
                    } label: {
                        Label("Play last", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                }
            
            
            
        }
    }
}
