import CryptoKit
import Foundation

enum PodcastFeedIdentity {
    static func normalizedFeedURLString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil

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
        "\(feedURL)|\(episodeID)"
    }

    static func make(
        feedURL: URL?,
        episodeGUID: String?,
        enclosureURL: URL?,
        episodeURL: URL?,
        linkURL: URL?
    ) -> EpisodeStableIdentity {
        let normalizedFeed = feedURL.map(PodcastFeedIdentity.normalizedFeedURLString)
            ?? "__missing_feed__"

        let primaryCandidate = Self.normalizedCandidate(
            episodeGUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let fallbackCandidates = [
            enclosureURL?.absoluteString,
            episodeURL?.absoluteString,
            linkURL?.absoluteString
        ]
        .compactMap(Self.normalizedCandidate)

        let stableEpisodeID = primaryCandidate ?? fallbackCandidates.first ?? Self.hashFallback(
            feedURL: normalizedFeed,
            candidates: fallbackCandidates
        )

        return EpisodeStableIdentity(feedURL: normalizedFeed, episodeID: stableEpisodeID)
    }

    private static func normalizedCandidate(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hashFallback(feedURL: String, candidates: [String]) -> String {
        let payload = ([feedURL] + candidates).joined(separator: "||")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
            linkURL: link
        )
    }

    var stableEpisodeIdentityKey: String {
        stableEpisodeIdentity.key
    }
}
