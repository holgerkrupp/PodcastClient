//
//  PodcastFeed.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation

@Observable
class PodcastFeed: Hashable, @unchecked Sendable {
    
    var title: String?
    var subtitle: String?
    var description: String?
    var source: Source?
    
    var url: URL?
    var existing: Bool = false
    
    var added: Bool = false
    var subscribing: Bool = false
    var status: URLstatus?
    
    var artist: String?
    var artworkURL: URL?
    var lastRelease: Date?
    var copyright: String?
    var link: URL?
    var funding: [FundingInfo] = []
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    var alternativeFeeds: [PodcastAlternativeFeed] = []
    var optionalTags: PodcastNamespaceOptionalTags?

    // Optional metadata restored from OPML custom attributes.
    var importedLastRefresh: Date?
    var importedLastEpisodeDate: Date?
    var importedLastEpisodeURL: URL?
    
    var needsRemotePreview: Bool {
        artist == nil || description == nil || artworkURL == nil || alternativeFeeds.isEmpty
    }

    var previewRefreshID: String {
        [
            title,
            subtitle,
            description,
            artist,
            artworkURL?.absoluteString,
            lastRelease?.timeIntervalSince1970.description,
            link?.absoluteString,
            alternativeFeeds.map(\.url.absoluteString).joined(separator: "|")
        ]
            .compactMap { $0 }
            .joined(separator: "||")
    }
    
    
    
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    enum Source {
        case iTunes

        var description: String {
            switch self {
            case .iTunes:
                return "iTunes"
            }
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        
    }

    init(
        url: URL? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        description: String? = nil,
        source: Source? = nil,
        artist: String? = nil,
        artworkURL: URL? = nil,
        lastRelease: Date? = nil,
        importedLastRefresh: Date? = nil,
        importedLastEpisodeDate: Date? = nil,
        importedLastEpisodeURL: URL? = nil,
        fetchMetadataIfNeeded: Bool = false
    ) {
        self.url = url
        self.title = title ?? url?.absoluteString
        self.subtitle = subtitle
        self.description = description
        self.source = source
        self.artist = artist
        self.artworkURL = artworkURL
        self.lastRelease = lastRelease
        self.importedLastRefresh = importedLastRefresh
        self.importedLastEpisodeDate = importedLastEpisodeDate
        self.importedLastEpisodeURL = importedLastEpisodeURL

        if fetchMetadataIfNeeded {
            fetchAndPopulateFeedIfNeeded()
        }
    }

    convenience init(url: URL) {
        self.init(url: url, fetchMetadataIfNeeded: false)
    }
    
    private func fetchAndPopulateFeedIfNeeded() {
        print("fetchAndPopulateFeedIfNeeded \(String(describing: url))")
        
        guard let url else { return }
        // If we already have most information, skip
        let needsFetch = (title?.isEmpty ?? true) || artist == nil || description == nil || artworkURL == nil || lastRelease == nil
        guard needsFetch else { print("no fetch needed")
            return }
     
        Task {
            do {
                let page = try await PodcastParser.fetchPage(from: url, maximumEpisodes: 1)
                await MainActor.run {
                    self.apply(parsedFeed: page.parsedFeed, fallbackURL: url)
                }
            } catch {
                print(error)
            }
        }
    }

    func apply(parsedFeed: [String: Any], fallbackURL: URL? = nil) {
        if let selfURLString = parsedFeed["selfURL"] as? String,
           let resolvedURL = URL(string: selfURLString, relativeTo: fallbackURL ?? url)?.absoluteURL {
            url = resolvedURL
        } else if url == nil {
            url = fallbackURL
        }

        let parsedTitle = parsedFeed["title"] as? String
        let parsedDescription = parsedFeed["description"] as? String
        let parsedAuthor = (parsedFeed["itunes:author"] as? String) ?? (parsedFeed["author"] as? String)
        let parsedCopyright = parsedFeed["copyright"] as? String

        if let artworkString = parsedFeed["coverImage"] as? String,
           let resolvedArtworkURL = URL(string: artworkString, relativeTo: fallbackURL ?? url)?.absoluteURL {
            artworkURL = resolvedArtworkURL
        } else if let imageDict = parsedFeed["image"] as? [String: Any],
                  let urlString = imageDict["url"] as? String,
                  let resolvedArtworkURL = URL(string: urlString, relativeTo: fallbackURL ?? url)?.absoluteURL {
            artworkURL = resolvedArtworkURL
        }

        if let lastBuildDateString = parsedFeed["lastBuildDate"] as? String,
           let date = Date.dateFromRFC1123(dateString: lastBuildDateString) {
            lastRelease = date
        }

        if let linkString = parsedFeed["link"] as? String,
           let resolvedLink = URL(string: linkString, relativeTo: fallbackURL ?? url)?.absoluteURL {
            link = resolvedLink
        }

        if let fundingArray = parsedFeed["funding"] as? [[String: String]] {
            funding = fundingArray.compactMap { dict in
                guard
                    let urlString = dict["url"],
                    let label = dict["label"],
                    let url = URL(string: urlString, relativeTo: fallbackURL ?? self.url)?.absoluteURL
                else { return nil }
                return FundingInfo(url: url, label: label)
            }
        } else if let fundingArray = parsedFeed["funding"] as? [FundingInfo] {
            funding = fundingArray
        }

        if let socialArray = parsedFeed["socialInteract"] as? [[String: Any]] {
            social = socialArray.compactMap { dict in
                guard
                    let proto = dict["protocol"] as? String,
                    let uriString = dict["uri"] as? String,
                    let uri = URL(string: uriString, relativeTo: fallbackURL ?? self.url)?.absoluteURL
                else { return nil }

                let accountId = dict["accountId"] as? String
                let accountUrlString = dict["accountUrl"] as? String
                let accountURL = accountUrlString.flatMap { URL(string: $0, relativeTo: fallbackURL ?? self.url)?.absoluteURL }
                let priority = dict["priority"] as? Int
                return SocialInfo(url: uri, socialprotocol: proto, accountId: accountId, accountURL: accountURL, priority: priority)
            }
        } else if let socialArray = parsedFeed["socialInteract"] as? [SocialInfo] {
            social = socialArray
        }

        if let peopleArray = parsedFeed["people"] as? [[String: Any]] {
            people = peopleArray.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let role = dict["role"] as? String
                let href = (dict["href"] as? String).flatMap { URL(string: $0, relativeTo: fallbackURL ?? self.url)?.absoluteURL }
                let img = (dict["img"] as? String).flatMap { URL(string: $0, relativeTo: fallbackURL ?? self.url)?.absoluteURL }
                return PersonInfo(name: name, role: role, href: href, img: img)
            }
        } else if let peopleArray = parsedFeed["people"] as? [PersonInfo] {
            people = peopleArray
        }

        if let parsedAlternativeFeeds = parsedFeed["alternativeFeeds"] as? [[String: String]] {
            var seen = Set<URL>()
            alternativeFeeds = parsedAlternativeFeeds.compactMap { dict in
                guard
                    let urlString = dict["url"],
                    let url = URL(string: urlString, relativeTo: fallbackURL ?? self.url)?.absoluteURL,
                    seen.insert(url).inserted
                else { return nil }

                return PodcastAlternativeFeed(
                    url: url,
                    title: dict["title"],
                    type: dict["type"]
                )
            }
        } else if let parsedAlternativeFeeds = parsedFeed["alternativeFeeds"] as? [PodcastAlternativeFeed] {
            alternativeFeeds = parsedAlternativeFeeds
        } else {
            alternativeFeeds = []
        }

        if let optionalTags = parsedFeed["optionalTags"] as? PodcastNamespaceOptionalTags,
           optionalTags.isEmpty == false {
            self.optionalTags = optionalTags
        } else {
            self.optionalTags = nil
        }

        title = parsedTitle ?? title
        description = parsedDescription ?? description
        artist = parsedAuthor ?? artist
        copyright = parsedCopyright ?? copyright
    }

    func applyPreview(from feed: PodcastFeed) {
        url = feed.url ?? url
        title = feed.title ?? title
        subtitle = feed.subtitle ?? subtitle
        description = feed.description ?? description
        source = feed.source ?? source
        artist = feed.artist ?? artist
        artworkURL = feed.artworkURL ?? artworkURL
        lastRelease = feed.lastRelease ?? lastRelease
        copyright = feed.copyright ?? copyright
        link = feed.link ?? link

        if feed.funding.isEmpty == false {
            funding = feed.funding
        }

        if feed.social.isEmpty == false {
            social = feed.social
        }

        if feed.people.isEmpty == false {
            people = feed.people
        }

        if feed.alternativeFeeds.isEmpty == false {
            alternativeFeeds = feed.alternativeFeeds
        }

        optionalTags = feed.optionalTags ?? optionalTags
    }

    func matchesExistingPodcast(_ podcast: Podcast) -> Bool {
        if let url, podcast.matchesFeedURL(url) {
            return true
        }

        if alternativeFeeds.contains(where: { podcast.matchesFeedURL($0.url) }) {
            return true
        }

        if let link, podcast.matchesWebURL(link) {
            return true
        }

        if let podcastLink = podcast.link, podcastLink.matchesPodcastWebURL(link) {
            return true
        }

        if let titleKey = title?.podcastTitleComparisonKey,
           titleKey == podcast.title.podcastTitleComparisonKey {
            return true
        }

        if let importedLastEpisodeURL,
           podcast.episodes?.contains(where: { $0.url == importedLastEpisodeURL }) == true {
            return true
        }

        return false
    }

}
