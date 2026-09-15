//
//  DiscoveredPodcast.swift
//  Raul
//
//  Lightweight representation of a podcast that has been discovered but not
//  imported. Discovery never creates SwiftData objects: only when the user
//  subscribes is the resolved feed URL handed to the existing import pipeline.
//

import Foundation

struct DiscoveredPodcast: Identifiable, Sendable, Hashable {
    /// Provider-scoped identifier. Unique within a provider, not across providers.
    let id: String
    let title: String
    let author: String?
    let summary: String?
    let artworkURL: URL?
    /// The RSS feed, when the provider exposes it directly. Otherwise `nil`, and
    /// `PodcastDiscoveryProvider.resolveFeed(for:)` has to look it up.
    let feedURL: URL?
    /// Public webpage for the show, offered to the user when feed resolution fails.
    let webpageURL: URL?
    /// BCP-47 / ISO 639 language code as reported by the provider.
    let language: String?
    let providerID: String
    let broadcasterID: String
    /// Opaque, provider-private handle used during feed resolution (a slug, a URN, …).
    let providerReference: String?
    let episodeCount: Int?

    init(
        id: String,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        artworkURL: URL? = nil,
        feedURL: URL? = nil,
        webpageURL: URL? = nil,
        language: String? = nil,
        providerID: String,
        broadcasterID: String,
        providerReference: String? = nil,
        episodeCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.feedURL = feedURL
        self.webpageURL = webpageURL
        self.language = language
        self.providerID = providerID
        self.broadcasterID = broadcasterID
        self.providerReference = providerReference
        self.episodeCount = episodeCount
    }

    /// Identity used to merge the same show reported by several providers.
    /// Feeds win when known, because the same RSS URL really is the same podcast.
    var deduplicationKey: String {
        if let feedURL {
            return Self.normalizedFeedKey(feedURL)
        }
        return "title:" + title.discoveryComparisonKey
    }

    static func normalizedFeedKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.fragment = nil

        let host = (components?.host ?? url.host() ?? "").lowercased()
        var path = components?.path ?? url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let query = components?.query.map { "?" + $0 } ?? ""
        return "feed:" + host + path.lowercased() + query
    }
}

extension String {
    /// Diacritic- and punctuation-insensitive key used to compare show titles.
    var discoveryComparisonKey: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }
}

extension Collection where Element == DiscoveredPodcast {
    /// Local, accent-insensitive matching over an already fetched catalogue.
    /// Providers whose source has no search endpoint use this on their cached
    /// catalogue rather than issuing another request per keystroke.
    func matchingDiscoveryQuery(_ query: String) -> [DiscoveredPodcast] {
        let key = query.discoveryComparisonKey
        guard key.isEmpty == false else { return [] }

        return filter { podcast in
            if podcast.title.discoveryComparisonKey.contains(key) { return true }
            if let author = podcast.author, author.discoveryComparisonKey.contains(key) { return true }
            if let summary = podcast.summary, summary.discoveryComparisonKey.contains(key) { return true }
            return false
        }
    }
}
