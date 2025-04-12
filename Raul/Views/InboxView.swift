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
            predicate = nil
        }

        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        _episodes = Query(filter: predicate, sort: [sortDescriptor], animation: .default)
    }
    
    var body: some View {
        List {
            ForEach(episodes) { episode in
                EpisodeRowView(episode: episode)
                    .swipeActions(edge: .trailing){
                        if episode.metaData?.finishedPlaying == true {
                            Button(role: .none) {
                                Task { @MainActor in
                                    episode.metaData?.finishedPlaying = false
                                }
                            } label: {
                                Label("Mark as not played", systemImage: "circle")
                            }
                        } else {
                            Button(role: .none) {
                                Task { @MainActor in
                                    episode.metaData?.finishedPlaying = true
                                }
                            } label: {
                                Label("Mark as played", systemImage: "checkmark.circle")
                            }
                        }
                    }
                    .tint(.accent)
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
