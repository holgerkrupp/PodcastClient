import Foundation

/// Holds one decoded RSS page and reveals stable, de-duplicated batches while
/// keeping RFC 5005 navigation separate from XML parsing.
struct PodcastFeedEpisodePager {
    private let batchSize: Int
    private var currentPageEpisodes: [PodcastEpisodeDraft] = []
    private var nextOffset = 0
    private var seenEpisodeIDs = Set<String>()
    private var visitedPageKeys = Set<String>()
    private(set) var nextPageURL: URL?

    init(batchSize: Int = 20) {
        self.batchSize = max(1, batchSize)
    }

    var hasUndeliveredEpisodes: Bool {
        nextOffset < currentPageEpisodes.count
    }

    var hasMoreEpisodes: Bool {
        hasUndeliveredEpisodes || nextPageURL != nil
    }

    func hasVisited(_ url: URL) -> Bool {
        visitedPageKeys.contains(Self.pageKey(for: url))
    }

    mutating func appendPage(
        _ episodes: [PodcastEpisodeDraft],
        requestedURL: URL,
        nextPageURL: URL?
    ) -> [PodcastEpisodeDraft] {
        let key = Self.pageKey(for: requestedURL)
        guard visitedPageKeys.insert(key).inserted else {
            self.nextPageURL = nil
            return []
        }

        var pageIDs = seenEpisodeIDs
        currentPageEpisodes = episodes.filter { pageIDs.insert($0.id).inserted }
        seenEpisodeIDs = pageIDs
        nextOffset = 0
        self.nextPageURL = nextPageURL.flatMap { visitedPageKeys.contains(Self.pageKey(for: $0)) ? nil : $0 }
        return nextBatch()
    }

    mutating func nextBatch() -> [PodcastEpisodeDraft] {
        guard hasUndeliveredEpisodes else { return [] }
        let end = min(nextOffset + batchSize, currentPageEpisodes.count)
        defer { nextOffset = end }
        return Array(currentPageEpisodes[nextOffset..<end])
    }

    mutating func reset() {
        currentPageEpisodes = []
        nextOffset = 0
        seenEpisodeIDs.removeAll(keepingCapacity: true)
        visitedPageKeys.removeAll(keepingCapacity: true)
        nextPageURL = nil
    }

    private static func pageKey(for url: URL) -> String {
        url.podcastPageTraversalKey
    }
}
