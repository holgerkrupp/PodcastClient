import SwiftUI
import SwiftData

struct BookmarkListView: View {
    @Environment(\.modelContext) private var modelContext
    
    var podcast: Podcast?
    var episode: Episode?
    
    @Query private var bookmarks: [Bookmark]

    init(podcast: Podcast? = nil, episode: Episode? = nil) {
        self.podcast = podcast
        self.episode = episode
        if let episode {
            let episodeID = episode.persistentModelID
           
            _bookmarks = Query(
                filter: #Predicate<Bookmark> { bookmark in
                    bookmark.bookmarkEpisode?.persistentModelID == episodeID
                })
             
            
        } else if let podcast {
            let podcastID = podcast.persistentModelID
            _bookmarks = Query(
                filter: #Predicate<Bookmark> { bookmark in
                    bookmark.bookmarkEpisode?.podcast?.persistentModelID == podcastID
                }
            )
        } else {
            _bookmarks = Query()
        }
    
    }
       
    
    
    private var navigationTitleText: String {
        if let episode = episode {
            return "Bookmarks for \(episode.title)"
        } else if let podcast = podcast {
            return "Bookmarks in \(podcast.title)"
        } else {
            return "All Bookmarks"
        }
    }
    
    var body: some View {
        /*
        if bookmarks.isEmpty {
            BookmarkEmptyView()
        }else{
         */
            List(bookmarks, id: \.id) { marker in
                VStack(alignment: .center) {
                    ZStack{
                        
                        
                        CoverImageView(episode: marker.bookmarkEpisode)
                            .scaledToFill()
                            .frame(height: 150)
                            .clipped()
                        
                        VStack{
                            HStack{
                                CoverImageView(episode: marker.bookmarkEpisode)
                                    .frame(width: 120, height: 120)
                                    .cornerRadius(8)
                                VStack(alignment: .leading) {
                                    Text(marker.bookmarkEpisode?.podcast?.title ?? marker.bookmarkEpisode?.title ?? "")
                                        .font(.headline)
                                    Text(marker.title)
                                        .font(.body)
                                    if let start = marker.start {
                                        Text("at \(Duration.seconds(start).formatted(.units(width: .abbreviated)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let episode = marker.bookmarkEpisode{
                                Button {
                                    Task{
                                        await Player.shared.playEpisode(episode.id, playDirectly: true, startingAt: marker.start)
                                    }
                                } label: {
                                    
                                    Label("Play", systemImage: "play.fill")
                                    
                                }
                                .buttonStyle(.glass)
                                
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding()
                        .background(
                            Rectangle()
                                .fill(.ultraThinMaterial)
                            
                        )
                    }}
               
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0,
                                     leading: 0,
                                     bottom: 0,
                                     trailing: 0))
                
                
                
                .swipeActions(edge: .trailing){
                    
                    Button(role: .none) {
                        Task { @MainActor in
                            await deleteMarker(marker)
                        }
                    } label: {
                        Label("Delete Bookmark", systemImage: "bookmark.slash.fill")
                    }
                    
                }
                
                
                
                
            }
            .listStyle(.plain)
            .navigationTitle(navigationTitleText)
        
        
        
    }
    
    private func deleteMarker(_ marker: Marker) async {
        // print("archiveEpisode from PlaylistView - \(episode.title)")
        guard let id = marker.uuid else { return }
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.deleteMarker(markerID: id)
        
    }
}
