import SwiftUI
import SwiftData

struct PodcastListView: View {
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @StateObject private var viewModel: PodcastListViewModel
    @Environment(\.modelContext) private var modelContext
    
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInEpisodes = true

    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    var filteredPodcasts: [Podcast] {
        if searchText.isEmpty { return podcasts }

        return podcasts.filter { podcast in
            let lowercased = searchText.lowercased()

            var matches = false
            if searchInTitle {
                matches = matches || podcast.title.localizedStandardContains(lowercased)
            }
            if searchInTitle, searchInEpisodes {
                matches = matches || podcast.episodes.contains(where: { $0.title.localizedStandardContains(lowercased) })
            }
            if searchInAuthor, let author = podcast.author {
                matches = matches || author.localizedStandardContains(lowercased)
            }
            if searchInDescription, let desc = podcast.desc {
                matches = matches || desc.localizedStandardContains(lowercased)
            }
            if searchInDescription, searchInEpisodes {
                matches = matches || podcast.episodes.contains(where: { $0.desc?.localizedStandardContains(lowercased) ?? false })
            }
            return matches
        }
    }

    var body: some View {
        if filteredPodcasts.isEmpty{
            if searchText.isEmpty {
                PodcastsEmptyView()
            }else{
                Text("No results found for \"\(searchText)\"")
            }
            
        } else {
            List {
      
                    NavigationLink(destination: AllEpisodesListView()) {
                        HStack {
                            Text("All Episodes")
                                .font(.headline)

                        }
                    }
      
                    
                    // The clickable header using NavigationLink
                    NavigationLink(destination: AllEpisodesListView().onlyPlayed()) {
                        HStack {
                            Text("Recently Played Episodes")
                                .font(.headline)

                        }
                    }
                
                
     
                  
                        ForEach(filteredPodcasts) { podcast in

                            
                            ZStack {
                               
                                PodcastRowView(podcast: podcast)
                                
                               NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                                    EmptyView()
                                }.opacity(0)
                            
                            }
                        
                           
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                             
                            
                            
                        }
                    
                        .onDelete { indexSet in
                            Task {
                                for index in indexSet {
                                    await viewModel.deletePodcast(filteredPodcasts[index])
                                }
                            }
                        }
                      //  .searchable(text: $searchText)
                
                    
                }
            .animation(.easeInOut, value: filteredPodcasts)

            .listStyle(.plain)
            .navigationTitle("Library")
        
            .toolbar {
              //  DefaultToolbarItem(kind: .search, placement: .automatic)
                
 
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await viewModel.refreshPodcasts() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                if let message = viewModel.errorMessage {
                    Text(message)
                }
            }
            }

       
            
        

        
        
    }
}



#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
} 
