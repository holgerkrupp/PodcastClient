import SwiftUI
import Combine
import FyydSearchManager

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [Podcast] = []
    @Published var isLoading = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch()
            }
            .store(in: &cancellables)
    }
    
    func performSearch() {
        guard !searchText.isEmpty else {
            results = []
            return
        }
        
        Task {
            isLoading = true
            do {
                let podcasts = await search(for: searchText) ?? []
                results = podcasts
            } catch {
                print("Search failed: \(error)")
            }
            isLoading = false
        }
    }
}
