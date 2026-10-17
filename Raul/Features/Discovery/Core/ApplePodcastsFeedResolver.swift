//
//  ApplePodcastsFeedResolver.swift
//  Raul
//
//  A fallback feed resolver for broadcasters that publish their shows on Apple
//  Podcasts but do not expose the RSS URL themselves. It reuses the app's
//  existing Apple Podcasts client rather than adding a second iTunes path.
//
//  Two modes, in decreasing confidence:
//   * by Apple collection id, scraped from the broadcaster's own show page —
//     exact, because the broadcaster made the link itself;
//   * by title, which only resolves on an exact normalized title match, so an
//     ambiguous title resolves to nothing instead of the wrong podcast.
//

import Foundation

struct ApplePodcastsFeedResolver: Sendable {
    struct Candidate: Sendable {
        let feedURL: URL
        let title: String?
        let publisher: String?
    }

    /// Storefront used for lookups, e.g. "pt" or "de".
    let storefront: String
    private let searchCandidates: @Sendable (String) async -> [Candidate]
    private let collectionLookup: @Sendable (String) async -> URL?

    init(
        storefront: String,
        searchCandidates: (@Sendable (String) async -> [Candidate])? = nil,
        collectionLookup: (@Sendable (String) async -> URL?)? = nil
    ) {
        self.storefront = storefront.lowercased()
        self.searchCandidates = searchCandidates ?? { term in
            let results = await ITunesSearchActor(country: storefront).search(for: term) ?? []
            return results.compactMap { feed in
                guard let feedURL = feed.url else { return nil }
                return Candidate(feedURL: feedURL, title: feed.title, publisher: feed.artist)
            }
        }
        self.collectionLookup = collectionLookup ?? { id in
            await ITunesSearchActor(country: storefront).feedURL(forCollectionID: id)
        }
    }

    func feedURL(forAppleCollectionID collectionID: String) async -> URL? {
        await collectionLookup(collectionID)
    }

    /// Resolves only an unambiguous Apple result published by the expected
    /// broadcaster and whose title preserves the complete programme title.
    /// A suffix such as "- Deutschlandfunk Nova" is allowed; dropping a
    /// meaningful title component (for example "-Speicher") is not.
    func feedURL(matchingTitle title: String, author: String? = nil) async -> URL? {
        let wanted = Self.normalized(title)
        guard wanted.count >= 4 else { return nil }

        var queries = [title]
        if let author, author.isEmpty == false {
            queries.append("\(title) \(author)")
        }
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for query in queries {
            for candidate in await searchCandidates(query) {
                guard Self.publisherMatches(candidate.publisher, expected: author),
                      Self.title(candidate.title, preserves: title) else { continue }
                let key = candidate.feedURL.absoluteString
                if seen.insert(key).inserted { candidates.append(candidate) }
            }
            if candidates.count > 1 { return nil }
            if candidates.count == 1 { return candidates[0].feedURL }
        }
        return nil
    }

    static func title(_ candidateTitle: String?, preserves requestedTitle: String) -> Bool {
        guard let candidateTitle else { return false }
        let candidate = titleWords(candidateTitle)
        let requested = titleWords(requestedTitle)
        guard requested.joined().count >= 4, candidate.count >= requested.count else { return false }
        return Array(candidate.prefix(requested.count)) == requested
    }

    static func publisherMatches(_ candidatePublisher: String?, expected: String?) -> Bool {
        guard let expected, let candidatePublisher else {
            return false
        }
        let expectedWords = titleWords(expected)
        let publisherWords = titleWords(candidatePublisher)
        guard expectedWords.joined().count >= 4, publisherWords.joined().count >= 4 else { return false }
        return publisherWords == expectedWords
            || (publisherWords.count > expectedWords.count
                && Array(publisherWords.prefix(expectedWords.count)) == expectedWords)
            || (expectedWords.count > publisherWords.count
                && Array(expectedWords.prefix(publisherWords.count)) == publisherWords)
    }

    private static func normalized(_ value: String) -> String {
        value.discoveryComparisonKey
    }

    private static func titleWords(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
    }

    /// Extracts an Apple Podcasts collection id from a broadcaster webpage.
    static func appleCollectionID(inMarkup markup: String) -> String? {
        DiscoveryMarkupScanner.firstCapture(
            of: "podcasts\\.apple\\.com/[^\"'<>\\s]*?/id([0-9]+)",
            in: markup
        )
    }
}
