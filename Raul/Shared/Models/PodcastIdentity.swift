import CryptoKit
import Foundation

enum PodcastFeedIdentity {
    static func normalizedFeedURLString(_ url: URL) -> String {
        normalizedURLString(url)
    }

    static func normalizedResourceURLString(_ url: URL) -> String {
        normalizedURLString(url)
    }

    private static func normalizedURLString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.scheme = normalizedScheme
        components?.host = normalizedHost

        if (components?.scheme == "https" && components?.port == 443)
            || (components?.scheme == "http" && components?.port == 80) {
            components?.port = nil
        }

        guard let normalizedURL = components?.url else {
            return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalizedURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EpisodeStableIdentity: Hashable, Sendable {
    let feedURL: String
    let episodeID: String

    var key: String {
        StableIdentityKey.make(feedURL, episodeID)
    }

    static func make(
        feedURL: URL?,
        episodeGUID: String?,
        enclosureURL: URL?,
        episodeURL: URL?,
        linkURL: URL?,
        title: String? = nil,
        publishDate: Date? = nil
    ) -> EpisodeStableIdentity {
        let normalizedFeed = feedURL.map(PodcastFeedIdentity.normalizedFeedURLString)
            ?? "__missing_feed__"

        let primaryCandidate = Self.normalizedCandidate(
            episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        ).map { "guid:\($0)" }

        let fallbackCandidates = [
            enclosureURL.map {
                "enclosure:\(PodcastFeedIdentity.normalizedResourceURLString($0))"
            },
            episodeURL.map {
                "episode:\(PodcastFeedIdentity.normalizedResourceURLString($0))"
            },
            linkURL.map {
                "link:\(PodcastFeedIdentity.normalizedResourceURLString($0))"
            }
        ]
        .compactMap { $0 }

        let stableEpisodeID = primaryCandidate ?? fallbackCandidates.first ?? Self.hashFallback(
            feedURL: normalizedFeed,
            title: title,
            publishDate: publishDate
        )

        return EpisodeStableIdentity(feedURL: normalizedFeed, episodeID: stableEpisodeID)
    }

    private static func normalizedCandidate(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hashFallback(
        feedURL: String,
        title: String?,
        publishDate: Date?
    ) -> String {
        let normalizedTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            ?? ""
        let publicationTimestamp = publishDate.map {
            String(Int($0.timeIntervalSince1970.rounded()))
        } ?? ""
        let payload = StableIdentityKey.make(
            feedURL,
            normalizedTitle,
            publicationTimestamp
        )
        let digest = SHA256.hash(data: Data(payload.utf8))
        return "hash:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum StableIdentityKey {
    static func make(_ components: String...) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

extension Episode {
    var stableFeedURLString: String? {
        podcast?.feed.map(PodcastFeedIdentity.normalizedFeedURLString)
    }

    var stableEpisodeIdentity: EpisodeStableIdentity {
        EpisodeStableIdentity.make(
            feedURL: podcast?.feed,
            episodeGUID: guid,
            enclosureURL: url,
            episodeURL: url,
            linkURL: link,
            title: title,
            publishDate: publishDate
        )
    }

    var stableEpisodeIdentityKey: String {
        stableEpisodeIdentity.key
    }
}
