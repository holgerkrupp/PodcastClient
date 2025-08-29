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
 
       lastFetchDate =  await SubscriptionManager(modelContainer: modelContainer).getLastRefreshDate()
        return lastFetchDate
    }
    
    

        @Published var completed: Int = 0
        @Published var total: Int = 0


    func refreshAllPodcasts() async {
        isLoading = true
        // fetch podcasts
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try? modelContainer.mainContext.fetch(descriptor)
        
        
        await MainActor.run { total = podcasts?.count ?? 0; completed = 0 }
        
        let semaphore = AsyncSemaphore(value: 5)
        if let ids = podcasts?.map(\.id){
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }
                        
                        do {
                            let worker = PodcastModelActor(modelContainer: self.modelContainer)
                            _ = try await worker.updatePodcast(id)
                            
                            // increment progress on the main actor
                            await MainActor.run {
                                self.completed += 1
                            }
                        } catch {
                            // optionally handle errors per feed
                            await MainActor.run {
                                self.completed += 1
                            }
                        }
                    }
                }
            }
        }
        isLoading = false
    }
    }
    

