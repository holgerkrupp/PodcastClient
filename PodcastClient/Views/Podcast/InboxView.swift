//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct InboxView: View {
    @Environment(\.modelContext) var modelContext
    
    
   
    @Query(filter: #Predicate<Episode> {$0.finishedPlaying != true },
           sort: [SortDescriptor(\Episode.pubDate, order: .reverse)]
    
    ) var episodes: [Episode]
    

    
    var body: some View {

            NavigationStack {
                List{
                    
                    if episodes.filter({$0.playlists?.count ?? 0 < 1}).count == 0{
                        Text("Pull down to refresh")

                    }else{
                    
                        ForEach(episodes.filter({$0.playlists?.count ?? 0 < 1}), id:\.self) { episode in
                            EpisodeMiniView(episode: episode)
                                .modelContext(modelContext)
                                .swipeActions(edge: .trailing){
                                    Button(role: .destructive) {
                                        withAnimation{
                                            episode.markAsPlayed()
                                        }
                                    } label: {
                                        Label("Mark as Played", systemImage: "checkmark.circle.fill")
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        episode.playNow()
                                    } label: {
                                        Label("Play now", systemImage: "play")
                                    }
                                    Button {
                                        withAnimation{
                                            PlaylistManager.shared.playnext.add(episode: episode, to: .front)
                                        }
                                    } label: {
                                        Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    Button {
                                        withAnimation{
                                            PlaylistManager.shared.playnext.add(episode: episode, to: .end)
                                        }
                                    } label: {
                                        Label("Play last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                    }
                                }
                        }
                    }
                }
                .refreshable {
                    await SubscriptionManager.shared.refreshall()
                }
            }
    }
}

