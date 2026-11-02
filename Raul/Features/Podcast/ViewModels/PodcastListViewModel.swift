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

    /// Takes the identifier rather than the model: the caller may be deleting a
    /// whole selection, and the rows it holds are gone from the list - and from
    /// the store - by the time the second delete starts.
    @discardableResult
    func deletePodcast(_ podcastID: PersistentIdentifier) async -> Bool {
        do {
            // A model actor created on the main thread does its work there, and
            // this view model is. Deleting a large podcast froze the app.
            let modelContainer = modelContainer
            try await Task.detached(priority: .userInitiated) {
                try await PodcastModelActor(modelContainer: modelContainer).deletePodcast(podcastID)
            }.value
            return true
        } catch {
            errorMessage = "Failed to delete podcast: \(error.localizedDescription)"
            return false
        }
    }
}
