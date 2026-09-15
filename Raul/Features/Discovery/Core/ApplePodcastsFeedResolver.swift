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
    /// Storefront used for lookups, e.g. "pt" or "de".
    let storefront: String

    init(storefront: String) {
        self.storefront = storefront.lowercased()
    }

    func feedURL(forAppleCollectionID collectionID: String) async -> URL? {
        await ITunesSearchActor(country: storefront).feedURL(forCollectionID: collectionID)
    }

    /// Resolves a feed only when exactly one Apple result carries the same title.
    /// Generic titles ("Wissen", "News") deliberately fail to resolve.
    func feedURL(matchingTitle title: String, author: String? = nil) async -> URL? {
        let wanted = title.discoveryComparisonKey
        guard wanted.count >= 4 else { return nil }

        let results = await ITunesSearchActor(country: storefront).search(for: title) ?? []
        let exactMatches = results.filter { $0.title?.discoveryComparisonKey == wanted }

        guard exactMatches.isEmpty == false else { return nil }

        if exactMatches.count == 1 {
            return exactMatches.first?.url
        }

        // Several shows share the title: only an author match can break the tie.
        guard let author, author.isEmpty == false else { return nil }
        let wantedAuthor = author.discoveryComparisonKey

        let authorMatches = exactMatches.filter { candidate in
            guard let artist = candidate.artist?.discoveryComparisonKey, artist.isEmpty == false else { return false }
            return artist == wantedAuthor || artist.contains(wantedAuthor) || wantedAuthor.contains(artist)
        }

        return authorMatches.count == 1 ? authorMatches.first?.url : nil
    }

    /// Extracts an Apple Podcasts collection id from a broadcaster webpage.
    static func appleCollectionID(inMarkup markup: String) -> String? {
        DiscoveryMarkupScanner.firstCapture(
            of: "podcasts\\.apple\\.com/[^\"'<>\\s]*?/id([0-9]+)",
            in: markup
        )
    }
}
