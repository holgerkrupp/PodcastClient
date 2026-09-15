//
//  CBCDirectoryParser.swift
//  Raul
//
//  Extracts CBC's podcast catalogue from its public podcast directory page.
//
//  The directory embeds one JSON object per show, each carrying the show's own
//  public RSS URL, so no feed has to be guessed or looked up elsewhere. The feed
//  is the anchor: the remaining fields are read from a bounded window around it,
//  which keeps a missing field from borrowing a neighbouring show's value.
//
//  All CBC-specific patterns live in this file.
//

import Foundation

enum CBCDirectoryParser {
    static let directoryURL = URL(string: "https://www.cbc.ca/listen/cbc-podcasts")

    static func parseDirectory(
        markup: String,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        var results: [DiscoveredPodcast] = []
        var seenFeeds = Set<String>()

        let needle = "\"rssUrl\":\""
        var searchRange = markup.startIndex..<markup.endIndex

        while let keyRange = markup.range(of: needle, range: searchRange) {
            searchRange = keyRange.upperBound..<markup.endIndex

            guard let closingQuote = markup[keyRange.upperBound...].firstIndex(of: "\"") else { continue }

            let feedString = DiscoveryMarkupScanner
                .decodingJSONEscapes(String(markup[keyRange.upperBound..<closingQuote]))

            guard feedString.isEmpty == false,
                  let feedURL = URL(string: feedString),
                  feedURL.scheme?.hasPrefix("http") == true,
                  seenFeeds.insert(feedString).inserted else {
                continue
            }

            let anchor = keyRange.lowerBound

            // Title and description precede the feed; artwork and category follow it.
            guard let title = DiscoveryMarkupScanner
                .precedingJSONString(key: "title", before: anchor, in: markup),
                  title.isEmpty == false else {
                continue
            }

            let summary = DiscoveryMarkupScanner
                .precedingJSONString(key: "description", before: anchor, in: markup)
                .map(DiscoveryMarkupScanner.plainText(from:))

            let artwork = DiscoveryMarkupScanner
                .followingJSONString(key: "thumbnail", after: anchor, in: markup, window: 2000)
                .flatMap(URL.init(string:))

            let category = DiscoveryMarkupScanner
                .followingJSONString(key: "itunesCategoryDescription", after: anchor, in: markup, window: 2000)

            let webpage = DiscoveryMarkupScanner
                .precedingJSONString(key: "webURL", before: anchor, in: markup, window: 2000)
                .flatMap(URL.init(string:))

            results.append(
                DiscoveredPodcast(
                    id: feedURL.deletingPathExtension().lastPathComponent,
                    title: title,
                    author: "CBC",
                    summary: summary?.isEmpty == false ? summary : nil,
                    artworkURL: artwork,
                    feedURL: feedURL,
                    webpageURL: webpage,
                    language: "en",
                    providerID: providerID,
                    broadcasterID: broadcasterID,
                    providerReference: category
                )
            )
        }

        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Categories come from each show's own iTunes category, carried through
    /// discovery in `providerReference`.
    static func categories(
        from podcasts: [DiscoveredPodcast],
        providerID: String
    ) -> [PodcastDiscoveryCategory] {
        var counts: [String: Int] = [:]

        for podcast in podcasts {
            guard let category = podcast.providerReference, category.isEmpty == false else { continue }
            counts[category, default: 0] += 1
        }

        return counts
            .map { title, count in
                PodcastDiscoveryCategory(
                    id: title,
                    title: title,
                    providerID: providerID,
                    artworkURL: nil,
                    podcastCount: count
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
