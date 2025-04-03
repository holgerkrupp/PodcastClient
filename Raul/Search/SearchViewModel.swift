import SwiftUI
import Combine
import fyyd_swift

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [Podcast] = []
    @Published var isLoading = false
    @Published var hotPodcasts: [Podcast] = []
    
    private var cancellables = Set<AnyCancellable>()
    private let fyydManager = FyydSearchManager()

    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch()
            }
            .store(in: &cancellables)
        
        Task {
            print("init")
            await loadHotPodcasts() // Load hot podcasts on initialization
        }
    }

    func performSearch() {
        guard !searchText.isEmpty else {
            results = []
            return
        }

        isLoading = true
        Task {
            let podcasts = await fyydManager.search(for: searchText) ?? []
            await MainActor.run {
                results = podcasts
                isLoading = false
            }
        }
    }

    // Fetch hot podcasts
    private func loadHotPodcasts() async {
        print("loadHotPodcasts")
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts()
        await MainActor.run {
            hotPodcasts = hotPodcastsList ?? []
            isLoading = false
        }
    }
}
