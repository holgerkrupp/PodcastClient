//
//  RTPDirectoryParser.swift
//  Raul
//
//  Extracts RTP Play's podcast listing from its public directory page.
//
//  RTP does not publish an RSS URL on the show page, but it does link each show
//  to its Apple Podcasts entry — which is an exact pointer to the real feed. So
//  discovery reads the directory here and feed resolution is a separate step.
//
//  All RTP-specific markup knowledge lives in this file.
//

import Foundation

enum RTPDirectoryParser {
    static let directoryURL = URL(string: "https://www.rtp.pt/play/podcasts")
    private static let siteBaseURL = URL(string: "https://www.rtp.pt")

    /// One podcast card in the directory: `<article id="program-id-15730">` with
    /// a link, a cover and a title.
    static func parseDirectory(
        markup: String,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        var results: [DiscoveredPodcast] = []
        var seenIDs = Set<String>()

        for article in articleBlocks(in: markup) {
            guard let programID = DiscoveryMarkupScanner.firstCapture(
                of: "id=\"program-id-([0-9]+)\"",
                in: article
            ), seenIDs.insert(programID).inserted else { continue }

            guard let path = DiscoveryMarkupScanner.firstCapture(
                of: "href=\"(/play/p[0-9]+/[^\"]+)\"",
                in: article
            ) else { continue }

            let title = DiscoveryMarkupScanner.firstCapture(
                of: "<p class=\"episode-title\"[^>]*>(.*?)</p>",
                in: article
            ).map(DiscoveryMarkupScanner.plainText(from:))

            guard let title, title.isEmpty == false else { continue }

            let artwork = DiscoveryMarkupScanner
                .firstCapture(of: "<img[^>]+src=\"([^\"]+)\"", in: article)
                .map(DiscoveryMarkupScanner.decodingHTMLEntities)
                .flatMap { URL(string: $0, relativeTo: siteBaseURL)?.absoluteURL }

            let summary = DiscoveryMarkupScanner
                .firstCapture(of: "<meta name=\"description\" content=\"([^\"]*)\"", in: article)
                .map(DiscoveryMarkupScanner.decodingHTMLEntities)

            results.append(
                DiscoveredPodcast(
                    id: programID,
                    title: title,
                    author: "RTP",
                    summary: summary?.isEmpty == false ? summary : nil,
                    artworkURL: artwork,
                    feedURL: nil,
                    webpageURL: URL(string: path, relativeTo: siteBaseURL)?.absoluteURL,
                    language: "pt",
                    providerID: providerID,
                    broadcasterID: broadcasterID,
                    providerReference: path
                )
            )
        }

        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Splits the page into `<article …>` chunks so a missing field in one card
    /// cannot pick up a neighbouring card's value.
    static func articleBlocks(in markup: String) -> [String] {
        let separator = "<article"
        return markup
            .components(separatedBy: separator)
            .dropFirst()
            .map { separator + $0 }
    }

    /// The RSS feed advertised on a show page, if RTP ever exposes one directly.
    static func parseDirectFeedURL(showPageMarkup markup: String) -> URL? {
        for tag in DiscoveryMarkupScanner.tags(named: "link", in: markup) {
            let lowercased = tag.lowercased()
            guard lowercased.contains("alternate"),
                  lowercased.contains("rss+xml") || lowercased.contains("atom+xml"),
                  let href = DiscoveryMarkupScanner.attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: siteBaseURL)?.absoluteURL else {
                continue
            }
            return url
        }
        return nil
    }
}
