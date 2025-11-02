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
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? modelContainer.mainContext.fetch(descriptor) else { return }
        let feeds = podcasts.map(\.feed)
        isLoading = true
        let modelContainer = self.modelContainer
        let total = feeds.count
        self.completed = 0
        self.total = total

        let maxConcurrent = 10  // limit parallel requests

        // Run the actual refresh off the MainActor
        Task.detached {
            var index = 0

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Kick off the first N tasks
                    for _ in 0..<min(maxConcurrent, total) {
                        
                        let feed = feeds[index]
                        if let feed{
                            group.addTask {
                                let worker = PodcastModelActor(modelContainer: modelContainer)
                                _ = try? await worker.updatePodcast(feed)
                            }
                            index += 1
                        }
                    }
                    // As each finishes, update progress + enqueue another
                    for try await _ in group {
                        await MainActor.run {
                            self.completed += 1
                        }

                        if index < total {
                            let feed = feeds[index]
                            if let feed{
                                group.addTask {
                                    let worker = PodcastModelActor(modelContainer: modelContainer)
                                    _ = try? await worker.updatePodcast(feed)
                                }
                                index += 1
                            }
                        }else{
                            await MainActor.run {
                                self.isLoading = false
                                
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        
    }
    
    
    }
    

