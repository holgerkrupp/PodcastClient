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
                    .swipeActions(edge: .trailing){
                        if episode.metaData?.finishedPlaying == true {
                            Button(role: .none) {
                                episode.metaData?.finishedPlaying = false
                                
                            } label: {
                                Label("Mark as not played", systemImage: "circle")
                            }
                        }else{
                            Button(role: .none) {
                                episode.metaData?.finishedPlaying = true
                                
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
            errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
}


struct EpisodeRowView: View {
    @Environment(\.modelContext) private var modelContext

    let episode: Episode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let imageULR = episode.imageURL{
                    ImageWithURL(imageULR)
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                    
                }
                VStack{
                    Text(episode.title)
                        .font(.headline)
                    
                    
                    Text(episode.podcast?.title ?? "-")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    
                    Text("Published: \(episode.publishDate?.formatted(.relative(presentation: .named)) ?? "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Button(action: {
                Player.shared.playEpisode(episode)
                
            }) {
                
                if episode.metaData?.finishedPlaying == true {
                    Image("custom.play.circle.badge.checkmark")
                }else{
                    Image(systemName: "play.circle")
                }
                
            }
            .buttonStyle(.plain)

      
            EpisodeControlView(episode: episode)
                .modelContainer(modelContext.container)
            
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationView {
        EpisodeListView()
    }
} 
