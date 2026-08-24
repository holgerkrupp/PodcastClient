import SwiftUI
import SwiftData

@MainActor
class PodcastListViewModel: ObservableObject {
    /// Refresh progress lives in `PodcastRefreshCoordinator` so the library and
    /// the inbox show the same run no matter which of them started it.
    @Published var errorMessage: String?

    private let modelContainer: ModelContainer
    private var podcastActor: PodcastModelActor

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.podcastActor = PodcastModelActor(modelContainer: modelContainer)
    }

    func deletePodcast(_ podcast: Podcast) async {
        do {
            try await podcastActor.deletePodcast(podcast.persistentModelID)
        } catch {
            errorMessage = "Failed to delete podcast: \(error.localizedDescription)"
        }
    }
}
