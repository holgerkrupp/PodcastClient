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

struct EpisodeRowView: View {
    @Environment(\.modelContext) private var modelContext
    let episode: Episode
    @State private var isExtended: Bool = false
    @State private var image: Image?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if let image = image {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 50, height: 50)
                .task {
                    await loadImage()
                }
                
                VStack(alignment: .leading) {
                    HStack {
                        Text(episode.podcast?.title ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text((episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                }
            }

            if isExtended {
                Button(action: {
                    Player.shared.playEpisode(episode)
                }) {
                    if episode.metaData?.finishedPlaying == true {
                        Image("custom.play.circle.badge.checkmark")
                    } else {
                        Image(systemName: "play.circle")
                    }
                }
                .buttonStyle(.plain)

                EpisodeControlView(episode: episode)
                    .modelContainer(modelContext.container)
            }
        }
        .padding(.vertical, 4)
        .onTapGesture {
            withAnimation {
                isExtended.toggle()
            }
        }
    }
    
    private func loadImage() async {
        if let imageURL = episode.imageURL ?? episode.podcast?.coverImageURL {
            if let uiImage = await ImageLoader.shared.loadImage(from: imageURL) {
                await MainActor.run {
                    self.image = Image(uiImage: uiImage)
                }
            }
        }
    }
}

// Add this class to handle image loading
actor ImageLoader {
    static let shared = ImageLoader()
    private var cache = NSCache<NSString, UIImage>()
    
    private init() {}
    
    func loadImage(from url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                cache.setObject(image, forKey: key)
                return image
            }
        } catch {
            print("Error loading image: \(error)")
        }
        return nil
    }
}

#Preview {
    NavigationView {
        EpisodeListView()
    }
} 
