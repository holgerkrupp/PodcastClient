import Foundation

struct PodcastEpisodeDraft: Identifiable, Hashable, @unchecked Sendable {
    let rawEpisodeData: [String: Any]

    let id: String
    let guid: String?
    let title: String
    let subtitle: String?
    let desc: String?
    let content: String?
    let publishDate: Date?
    let episodeURL: URL
    let link: URL?
    let imageURL: URL?
    let author: String?
    let duration: TimeInterval?
    let number: String?
    let type: EpisodeType?
    let deeplinks: [URL]

    init?(episodeData: [String: Any]) {
        guard let title = episodeData["itunes:title"] as? String ?? episodeData["title"] as? String,
              let enclosure = (episodeData["enclosure"] as? [[String: Any]])?.first,
              let enclosureURLString = enclosure["url"] as? String,
              let episodeURL = URL(string: enclosureURLString) else {
            return nil
        }

        let guid = (episodeData["guid"] as? String)
            ?? (episodeData["podcast:guid"] as? String)

        self.rawEpisodeData = episodeData
        self.id = guid ?? enclosureURLString
        self.guid = guid
        self.title = title
        self.subtitle = episodeData["itunes:subtitle"] as? String
        self.desc = episodeData["description"] as? String
        self.content = episodeData["content"] as? String
        self.publishDate = (episodeData["pubDate"] as? String).flatMap(Date.dateFromRFC1123)
        self.episodeURL = episodeURL
        self.link = URL(string: episodeData["link"] as? String ?? "")
        self.imageURL = URL(string: episodeData["itunes:image"] as? String ?? "")
        self.author = episodeData["itunes:author"] as? String
        self.duration = (episodeData["itunes:duration"] as? String)?.durationAsSeconds
        self.number = episodeData["itunes:episode"] as? String
        self.type = EpisodeType(rawValue: episodeData["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        self.deeplinks = (episodeData["deepLinks"] as? [String] ?? []).compactMap(URL.init(string:))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PodcastEpisodeDraft, rhs: PodcastEpisodeDraft) -> Bool {
        lhs.id == rhs.id
    }
}

struct PodcastFeedPage: @unchecked Sendable {
    let parsedFeed: [String: Any]
    let feed: PodcastFeed
    let episodes: [PodcastEpisodeDraft]
    let nextPageURL: URL?
    let isPartial: Bool
}
