import SwiftUI
import SwiftData

@MainActor
class PodcastListViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchDate: Date?
    
    private let modelContainer: ModelContainer
    private var podcastActor: PodcastModelActor
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.podcastActor = PodcastModelActor(modelContainer: modelContainer)
       
    }
    
    func refreshPodcasts() async {
        isLoading = true
        errorMessage = nil
        
        do {
            try await podcastActor.refreshAllPodcasts()
        } catch {
            errorMessage = "Failed to refresh podcasts: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func deletePodcast(_ podcast: Podcast) async {
        do {
            try await podcastActor.deletePodcast(podcast.persistentModelID)
        } catch {
            errorMessage = "Failed to delete podcast: \(error.localizedDescription)"
        }
    }
    
    func addPodcast(from url: URL) async {
        isLoading = true
        errorMessage = nil
        
        do {
            _ = try await podcastActor.createPodcast(from: url)
        } catch {
            errorMessage = "Failed to add podcast: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func getlastFetchedDate() async -> Date? {
       lastFetchDate =  await SubscriptionManager(modelContainer: ModelContainerManager().container).getLastRefreshDate()
        return lastFetchDate
    }
}
