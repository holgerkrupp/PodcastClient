import SwiftUI
import SwiftData

struct InboxView: View {
 
    @Query private var episodes: [Episode]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    
    init() {
       
        let predicate: Predicate<Episode>?
        
            predicate = #Predicate<Episode> { $0.metaData?.isInbox == true}
        

        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        _episodes = Query(filter: predicate, sort: [sortDescriptor], animation: .default)
    }
    
    var body: some View {
        if episodes.isEmpty{
            InboxEmptyView()
        }else{
            NavigationStack{
                List {
                    
                    
                    ForEach(episodes) { episode in
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
                                                 bottom: 2,
                                                 trailing: 0))
                    }
                }
                .listStyle(.plain)
            
            .navigationTitle("Inbox")
            .refreshable {
                Task{
                    await refreshEpisodes()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task {
                            await refreshEpisodes()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                

            }
            }
            
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
    
    private func archiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.archiveEpisode(episodeID: episode.id)
    }
    private func unarchiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.unarchiveEpisode(episodeID: episode.id)
    }
    
    private func refreshEpisodes() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let actor = PodcastModelActor(modelContainer: modelContext.container)
          
                try await actor.refreshAllPodcasts()
            
        } catch {
            await MainActor.run {
                errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
