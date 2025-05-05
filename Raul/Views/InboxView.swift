import SwiftUI
import SwiftData

struct InboxView: View {
    let podcast: Podcast?
    @Query private var episodes: [Episode]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    
    init(podcast: Podcast? = nil) {
        self.podcast = podcast
        let predicate: Predicate<Episode>?
        if let id = podcast?.persistentModelID {
            predicate = #Predicate<Episode> { $0.podcast?.persistentModelID == id }
        } else {
            predicate = #Predicate<Episode> { $0.metaData?.isInbox == true}
        }

        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        _episodes = Query(filter: predicate, sort: [sortDescriptor], animation: .default)
    }
    
    var body: some View {
        List {
            if let podcast {
                Section() {
                    PodcastDetailView(podcast: podcast)
                }
            }
            
            
            
            ForEach(episodes) { episode in
                EpisodeRowView(episode: episode)
                    .swipeActions(edge: .trailing){
                        if episode.metaData?.isArchived == true {
                            Button(role: .none) {
                                Task { @MainActor in
                                    await unarchiveEpisode(episode)
                                }
                            } label: {
                                Label("Unarchive Episode", systemImage: "archivebox")
                            }
                        } else {
                            Button(role: .none) {
                                Task { @MainActor in
                                    await archiveEpisode(episode)
                                }
                            } label: {
                                Label("Archive Episode", systemImage: "archivebox.fill")
                            }
                        }
                    }
                    .tint(.accent)
            }
        }
        .navigationTitle(podcast?.title ?? "All Episodes")
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

            if let podcast {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task {
                            try? await  PodcastModelActor(modelContainer: modelContext.container).archiveEpisodes(of: podcast.persistentModelID)
                        }
                    }) {
                        Image(systemName: "archivebox")
                    }
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
            if let podcast = podcast {
                try await actor.updatePodcast(podcast.persistentModelID)
            } else {
                try await actor.refreshAllPodcasts()
            }
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
