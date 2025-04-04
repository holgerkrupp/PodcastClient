import SwiftUI
import Combine
import fyyd_swift

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [FyydPodcast] = []
    @Published var isLoading = false
    @Published var hotPodcasts: [FyydPodcast] = []
    @Published var languages: [String] = [] // Store languages
    @Published var selectedLanguage: String = "en" {
        didSet {
            Task {
                await fyydManager.setLanguage(selectedLanguage)
                await loadHotPodcasts()
            }
        }
    }
    
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
            await loadHotPodcasts()
            await loadLanguages()
        }
    }

    func performSearch() {
        guard !searchText.isEmpty else {
            results = []
            return
        }

        isLoading = true
        Task {
            let podcasts = await fyydManager.searchPodcasts(query: searchText) ?? []
            await MainActor.run {
                results = podcasts
                isLoading = false
            }
        }
    }
    
    func loadLanguages() async {
        if let fetchedLanguages = await fyydManager.getLanguages() {
            await MainActor.run {
                self.languages = fetchedLanguages
            }
        }
    }

    // Fetch hot podcasts
    private func loadHotPodcasts() async {
     
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts(lang: selectedLanguage)
        await MainActor.run {
            hotPodcasts = hotPodcastsList ?? []
            isLoading = false
        }
    }
}
