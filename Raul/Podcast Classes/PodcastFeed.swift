//
//  PodcastFeed.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import fyyd_swift

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
    var optionalTags: PodcastNamespaceOptionalTags?

    // Optional metadata restored from OPML custom attributes.
    var importedLastRefresh: Date?
    var importedLastEpisodeDate: Date?
    var importedLastEpisodeURL: URL?
    
    
    
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    enum Source {
        case fyyd
        case iTunes
        
        var description: String {
            switch self {
            case .fyyd:
                return "fyyd"
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
    
    convenience init(fyydPodcast: FyydPodcast) {
        let url = fyydPodcast.xmlURL.flatMap { URL(string: $0) }
        self.init(
            url: url,
            title: fyydPodcast.title,
            subtitle: fyydPodcast.subtitle,
            description: fyydPodcast.description,
            source: .fyyd,
            artist: fyydPodcast.author,
            artworkURL: fyydPodcast.imgURL.flatMap { URL(string: $0) }
        )
        // Parse lastpub to Date if possible, fallback to nil
        let dateFormatter = ISO8601DateFormatter()
        self.lastRelease = dateFormatter.date(from: fyydPodcast.lastpub)
    }
    

}
