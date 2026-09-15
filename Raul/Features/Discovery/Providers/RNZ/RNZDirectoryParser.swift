//
//  RNZDirectoryParser.swift
//  Raul
//
//  Extracts RNZ's podcast catalogue from its public podcast directory page.
//
//  RNZ has no documented catalogue API. The directory page ships the whole
//  series list as an embedded payload, each series carrying its title, teaser,
//  cover and — most importantly — its public RSS URL, so the app never has to
//  guess a feed. Two independent passes run in order, and every field is
//  optional: a markup change degrades the result instead of breaking it.
//
//  All RNZ-specific patterns live in this file. Nothing above it knows that RNZ
//  is scraped at all.
//

import Foundation

enum RNZDirectoryParser {
    static let directoryURL = URL(string: "https://www.rnz.co.nz/podcasts")
    private static let showPagePrefix = "https://www.rnz.co.nz/podcast/"

    /// Parses the directory page into discovered podcasts, de-duplicated by slug.
    static func parseDirectory(
        markup: String,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        let payload = unescapedPayload(from: markup)

        let embedded = parseEmbeddedSeries(
            payload: payload,
            providerID: providerID,
            broadcasterID: broadcasterID
        )

        if embedded.isEmpty == false {
            return embedded
        }

        return parseFeedLinks(
            payload: payload,
            providerID: providerID,
            broadcasterID: broadcasterID
        )
    }

    /// The page embeds its data as escaped JSON inside script pushes. Undoing the
    /// one level of string escaping lets the key lookups below work on plain JSON.
    /// Escaped solidi are undone too, since JSON writers escape them freely and
    /// the URL patterns below are written in their ordinary form.
    static func unescapedPayload(from markup: String) -> String {
        markup
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: - Pass 1: embedded series objects

    /// Each series object ends with its feed URL, so the feed is the anchor and
    /// the remaining fields are read backwards from it within a bounded window.
    private static func parseEmbeddedSeries(
        payload: String,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        var results: [DiscoveredPodcast] = []
        var seenSlugs = Set<String>()

        let needle = "\"acast_url\":\""
        var searchRange = payload.startIndex..<payload.endIndex

        while let keyRange = payload.range(of: needle, range: searchRange) {
            searchRange = keyRange.upperBound..<payload.endIndex

            guard let closingQuote = payload[keyRange.upperBound...].firstIndex(of: "\"") else { continue }

            let feedString = String(payload[keyRange.upperBound..<closingQuote])
            guard let feedURL = URL(string: feedString), feedString.hasSuffix(".rss") else { continue }

            let anchor = keyRange.lowerBound

            let slug = DiscoveryMarkupScanner.precedingValue(
                afterNeedle: "\"slug\":{\"current\":\"",
                before: anchor,
                in: payload
            ) ?? feedURL.deletingPathExtension().lastPathComponent

            guard slug.isEmpty == false, seenSlugs.insert(slug).inserted else { continue }

            let title = DiscoveryMarkupScanner.precedingJSONString(key: "name", before: anchor, in: payload)
            guard let title, title.isEmpty == false else { continue }

            let summary = DiscoveryMarkupScanner.precedingJSONString(key: "teaser", before: anchor, in: payload)
            let language = DiscoveryMarkupScanner.precedingJSONString(key: "language", before: anchor, in: payload)
            let artwork = DiscoveryMarkupScanner.precedingJSONString(key: "imageUrl", before: anchor, in: payload)

            results.append(
                DiscoveredPodcast(
                    id: slug,
                    title: title,
                    author: "RNZ",
                    summary: summary?.isEmpty == false ? summary : nil,
                    artworkURL: artwork.flatMap(URL.init(string:)),
                    feedURL: feedURL,
                    webpageURL: URL(string: showPagePrefix + slug),
                    language: language,
                    providerID: providerID,
                    broadcasterID: broadcasterID,
                    providerReference: slug
                )
            )
        }

        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Pass 2: bare feed links

    /// Fallback for when the embedded payload changes shape: pair every feed URL
    /// with the slug it is named after. Titles then come from the slug, which is
    /// poorer but still usable, and the feed itself supplies the real metadata
    /// once the user opens the show.
    private static func parseFeedLinks(
        payload: String,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        var seenSlugs = Set<String>()

        let slugs = DiscoveryMarkupScanner
            .captures(of: "podcasts/acast/([a-z0-9\\-]+)\\.rss", in: payload)
            .compactMap(\.first)

        return slugs.compactMap { slug -> DiscoveredPodcast? in
            guard seenSlugs.insert(slug).inserted,
                  let feedURL = feedURL(forSlug: slug) else { return nil }

            return DiscoveredPodcast(
                id: slug,
                title: titleFromSlug(slug),
                author: "RNZ",
                artworkURL: nil,
                feedURL: feedURL,
                webpageURL: URL(string: showPagePrefix + slug),
                language: "en",
                providerID: providerID,
                broadcasterID: broadcasterID,
                providerReference: slug
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func titleFromSlug(_ slug: String) -> String {
        slug
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Feed resolution from a single show page

    static func feedURL(forSlug slug: String) -> URL? {
        guard slug.isEmpty == false else { return nil }
        return URL(string: "https://www.rnz.co.nz/podcasts/acast/\(slug).rss")
    }

    static func showPageURL(forSlug slug: String) -> URL? {
        guard slug.isEmpty == false else { return nil }
        return URL(string: showPagePrefix + slug)
    }

    /// Feed URL advertised on an individual show page.
    static func parseFeedURL(showPageMarkup markup: String) -> URL? {
        let payload = unescapedPayload(from: markup)

        if let url = DiscoveryMarkupScanner
            .urls(matching: "https://www\\.rnz\\.co\\.nz/podcasts/acast/[a-z0-9\\-]+\\.rss", in: payload)
            .first {
            return url
        }

        // Some pages advertise the feed the conventional way instead.
        for tag in DiscoveryMarkupScanner.tags(named: "link", in: markup) {
            let lowercased = tag.lowercased()
            guard lowercased.contains("alternate"),
                  lowercased.contains("rss+xml") || lowercased.contains("atom+xml"),
                  let href = DiscoveryMarkupScanner.attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: URL(string: "https://www.rnz.co.nz"))?.absoluteURL else {
                continue
            }
            return url
        }

        return nil
    }
}
