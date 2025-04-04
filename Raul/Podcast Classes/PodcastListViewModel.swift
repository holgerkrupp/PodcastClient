import SwiftUI
import SwiftData

@MainActor
class PodcastListViewModel: ObservableObject {
    @Published var podcasts: [Podcast] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let modelContainer: ModelContainer
    private var podcastActor: PodcastModelActor
    
    init(modelContainer: ModelContainer) {
        this.modelContainer = modelContainer
        this.podcastActor = PodcastModelActor(modelContainer: modelContainer)
    }
    
    func loadPodcasts() {
        let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
        do {
            podcasts = try modelContainer.mainContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load podcasts: \(error.localizedDescription)"
        }
    }
    
    func refreshPodcasts() async {
        isLoading = true
        errorMessage = nil
        
        do {
            try await podcastActor.refreshAllPodcasts()
            loadPodcasts()
        } catch {
            errorMessage = "Failed to refresh podcasts: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func deletePodcast(_ podcast: Podcast) async {
        do {
            try await podcastActor.deletePodcast(podcast.persistentModelID)
            loadPodcasts()
        } catch {
            errorMessage = "Failed to delete podcast: \(error.localizedDescription)"
        }
    }
    
    func addPodcast(from url: URL) async {
        isLoading = true
        errorMessage = nil
        
        do {
            _ = try await podcastActor.createPodcast(from: url)
            loadPodcasts()
        } catch {
            errorMessage = "Failed to add podcast: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
} 