//
//  UnifiedTimelineView.swift
//  Raul
//
//  Created by Holger Krupp on 16.06.25.
//

import SwiftUI
import SwiftData

struct UnifiedTimelineView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Episode> { episode in
        episode.metaData?.isHistory == true
    }, sort: [SortDescriptor(\Episode.metaData!.lastPlayed, order: .forward)])
    private var historyEpisodes: [Episode]

    @Query(filter: #Predicate<PlaylistEntry> { entry in
        entry.playlist?.title == "de.holgerkrupp.podbay.queue"
    }, sort: [SortDescriptor(\PlaylistEntry.order)])
    private var playlistEntries: [PlaylistEntry]

    @State private var viewModel: TimelineViewModel? = nil

    var body: some View {
      
            Group{
                
                if let viewModel = viewModel {
                    TimelineListView(viewModel: viewModel)
                }else{
                    Text("Loading...")
                }
            }
            .onAppear {
                print("onAppear")
                if viewModel == nil {
                    print("viewModel nil")
                    viewModel = TimelineViewModel(
                        modelContext: modelContext,
                        historyEpisodes: historyEpisodes,
                        playlistEntries: playlistEntries
                    )
                } else {
                    print("viewModel ")
                    
                    viewModel?.updateData(
                        historyEpisodes: historyEpisodes,
                        playlistEntries: playlistEntries
                    )
                }
            }
        /*
            .onChange(of: historyEpisodes) {
                viewModel?.updateData(
                    historyEpisodes: historyEpisodes,
                    playlistEntries: playlistEntries
                )
            }
            .onChange(of: playlistEntries) { 
                viewModel?.updateData(
                    historyEpisodes: historyEpisodes,
                    playlistEntries: playlistEntries
                )
            }
        */
        }
    
}


struct TimelineListView: View {
    @ObservedObject var viewModel: TimelineViewModel
    @State private var scrollToID: UUID?

    var body: some View {
        NavigationView {
           
                ScrollViewReader { proxy in
                    
                    List {
                        ForEach(viewModel.timelineItems) { item in
                            
                           
                                TimelineItemRow(
                                    item: item,
                                    isNowPlaying: viewModel.nowPlayingID == item.id
                                )
                                .id(item.id)
                            
                            
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 2,
                                                 trailing: 0))
                            .moveDisabled(!item.isQueued)
                        }
                        .onMove(perform: viewModel.moveItems)
                        
                        
                    }
                   
                    .listStyle(.plain)
                    .onAppear {
                        scrollToID = viewModel.nowPlayingID
                    }
                    .onDisappear(){
                        scrollToID = nil
                    }
                    .onChange(of: scrollToID) {
                        guard let id = scrollToID else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation {
                                proxy.scrollTo(id, anchor: .top)
                            }
                            scrollToID = nil
                        }
                    }
                    .environment(
                        \.editMode,
                         .constant(viewModel.timelineItems.contains { $0.isQueued } ? .active : .inactive)
                    )
                    .animation(.default, value: viewModel.timelineItems)
                    .navigationTitle("Timeline")
                    
                }}
    }
}


struct TimelineItemRow: View {
    let item: TimelineItem
    let isNowPlaying: Bool

    var body: some View {
      
         
                
                if isNowPlaying {
                    PlayerView(fullSize: true)
                        .frame(width: UIScreen.main.bounds.width, height:  UIScreen.main.bounds.height * 0.5)
                     //   .padding()
                }else{
                    
                        EpisodeRowView(episode: item.episode)
                    
                }
            

        }
    
}

#Preview {
    UnifiedTimelineView()
}
