//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//



import SwiftUI
import SwiftData

struct PlaylistView: View {
    @Query(filter: #Predicate<PlaylistEntry> { $0.playlist?.title == "de.holgerkrupp.podbay.queue" },
           sort: [SortDescriptor(\PlaylistEntry.order)] ) var playListEntries: [PlaylistEntry]
    @Environment(\.modelContext) private var modelContext
    @State private var showSettings: Bool = false

    var body: some View {
        if playListEntries.isEmpty {
            PlaylistEmptyView()
        }else{
        NavigationStack{
            
           
            
            List{

                if let episode = Player.shared.currentEpisode {
                    ZStack {
                         EpisodeRowView(episode: episode)
                            .id(episode.id)
                            .allowsHitTesting(false)
                       
                        Rectangle()
                            .fill(Color.background)
                            .opacity(0.6)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
                    .animation(.easeInOut, value: Player.shared.currentEpisode)
                    
                     /// Glass style overlay - looks cool but the non glass overlay is better
                    .overlay{
  

                     
                                Group {
                                    if Player.shared.isPlaying {
                                        Label("Now Playing", systemImage: "waveform")
                                            .symbolEffect(.bounce.up.byLayer, options: .repeat(.continuous))
                                            .foregroundStyle(Color.primary)
                                            .font(.title.bold())
                                    } else {
                                        Label("Now Playing", systemImage: "waveform.low")
                                            .foregroundStyle(Color.primary)
                                            .font(.title.bold())
                                    }
                                }
                                .frame(width: 300, height: 120)
                      
                                
                            
                     .background{
                         RoundedRectangle(cornerRadius:  20.0)
                             .fill(.background.opacity(0.3))
                     }
                  
                     
                     .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  20.0))
                     .frame(maxWidth: 300, maxHeight: 120, alignment: .center)
                    }
                    
                    
                }
             
                    ForEach(playListEntries, id: \.id) { entry in
                        if let episode = entry.episode {
                            
                            ZStack {
                               EpisodeRowView(episode: episode)
                                    .id(episode.id)
                                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                    EmptyView()
                                }.opacity(0)
                            }

                            .swipeActions(edge: .trailing){
                                
                                    Button(role: .none) {
                                        Task { @MainActor in
                                            await archiveEpisode(episode)
                                        }
                                    } label: {
                                        Label("Archive Episode", systemImage: "archivebox.fill")
                                    }
                                
                            }
                             
                           
                            
                            
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.init(top: 0,
                                                     leading: 0,
                                                     bottom: 0,
                                                     trailing: 0))
                                .ignoresSafeArea()
                        }
                           
                        
                    }
                    
                    

                    .onMove { indices, newOffset in
                        Task {
                            if let from = indices.first {
                                moveEntry(from: from, to: newOffset)
                            }
                        }
                    }
                }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                    }
                    
                }
               }
            .sheet(isPresented: $showSettings) {
                
                
                PodcastSettingsView(podcast: nil, modelContainer: modelContext.container)
                    .presentationBackground(.ultraThinMaterial)
                
            }
            .animation(.easeInOut, value: playListEntries)
           // .environment(\.editMode, $editMode)
            .listStyle(.plain)
            .navigationTitle("Up Next")
            }

            

        }

        
    }
    
    private func archiveEpisode(_ episode: Episode) async {
        // print("archiveEpisode from PlaylistView - \(episode.title)")
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        
            await episodeActor.archiveEpisode(episodeID: episode.id)
        
    }
    
    private func moveEntry(from sourceIndex: Int, to destinationIndex: Int) {

        print("moving entry from \(sourceIndex) to \(destinationIndex)")
            let sorted = playListEntries.sorted { $0.order < $1.order }

            guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }

            let movedEntry = sorted[sourceIndex]
            var reordered = sorted
            reordered.remove(at: sourceIndex)
            reordered.insert(movedEntry, at: destinationIndex)

            for (i, entry) in reordered.enumerated() {
                entry.order = i
            }
            
    }
}
