import SwiftUI
import SwiftData

@MainActor
class PodcastListViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var completed: Int = 0
    @Published var total: Int = 0
    
    
    @Published var errorMessage: String?
    @Published var lastFetchDate: Date?
    
    private let modelContainer: ModelContainer
    private var podcastActor: PodcastModelActor
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.podcastActor = PodcastModelActor(modelContainer: modelContainer)
       
    }
    
    func refreshPodcasts() async {
        await refreshAllPodcasts()
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
    
    




    func refreshAllPodcasts_old() async {
        isLoading = true
        // fetch podcasts
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try? modelContainer.mainContext.fetch(descriptor)
        
        
        await MainActor.run { total = podcasts?.count ?? 0; completed = 0 }
        
        let semaphore = AsyncSemaphore(value: 5)
        if let feeds = podcasts?.map(\.feed){
            await withTaskGroup(of: Void.self) { group in
                for feed in feeds {
                    if let feed{
                        group.addTask {
                            await semaphore.wait()
                            defer { Task { await semaphore.signal() } }
                            
                            do {
                                let worker = PodcastModelActor(modelContainer: self.modelContainer)
                                _ = try await worker.updatePodcast(feed)
                                
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
        }
        isLoading = false
    }
    
    func refreshAllPodcasts() async {
        guard isLoading == false else { return }
        isLoading = true
        errorMessage = nil
        completed = 0
        total = 0
        defer { isLoading = false }

        do {
            try await podcastActor.refreshAllPodcasts { completed, total in
                await MainActor.run {
                    self.completed = completed
                    self.total = total
                }
            }
            lastFetchDate = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    
    }
    
