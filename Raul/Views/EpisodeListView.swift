import SwiftUI
import SwiftData

struct EpisodeListView: View {
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
            predicate = nil
        }

        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        _episodes = Query(filter: predicate, sort: [sortDescriptor])
    }
    
    var body: some View {
        List {
            ForEach(episodes) { episode in
                EpisodeRowView(episode: episode)
            }
        }
        .navigationTitle(podcast?.title ?? "All Episodes")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
            errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
}

struct EpisodeRowView: View {
    let episode: Episode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title)
                .font(.headline)
            
           
            Text(episode.podcast?.title ?? "-")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            
            
            Text("Published: \(episode.publishDate.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button(action: {
                    UIApplication.shared.open(episode.url)
                
            }) {
                Label("Play Episode", systemImage: "play.circle.fill")
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationView {
        EpisodeListView()
    }
} 
