import Foundation
import Combine

@MainActor
final class PodcastRecentSearchStore: ObservableObject {
    static let shared = PodcastRecentSearchStore()
    static let maximumSearchCount = 10

    @Published private(set) var searches: [String]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "podcastRecentSearches"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.searches = defaults.stringArray(forKey: storageKey) ?? []
    }

    func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false,
              PodcastSearchInputRecognizer.url(from: query) == nil
        else { return }

        let normalizedQuery = Self.normalized(query)
        searches.removeAll { Self.normalized($0) == normalizedQuery }
        searches.insert(query, at: 0)
        searches = Array(searches.prefix(Self.maximumSearchCount))
        persist()
    }

    func remove(_ query: String) {
        let normalizedQuery = Self.normalized(query)
        searches.removeAll { Self.normalized($0) == normalizedQuery }
        persist()
    }

    func clear() {
        searches = []
        persist()
    }

    private func persist() {
        defaults.set(searches, forKey: storageKey)
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
