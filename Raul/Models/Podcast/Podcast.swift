//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

struct FundingInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    
    var url: URL
    var label: String
}

struct SocialInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    
    // Required
    var url: URL           // maps from "uri"
    var socialprotocol: String  // maps from "protocol"
    
    // Optional
    var accountId: String?
    var accountURL: URL?   // maps from "accountUrl"
    var priority: Int?

    private enum CodingKeys: String, CodingKey {
        case url = "uri"
        case socialprotocol = "protocol"
        case accountId
        case accountURL = "accountUrl"
        case priority
    }

    init(id: UUID = UUID(), url: URL, socialprotocol: String, accountId: String? = nil, accountURL: URL? = nil, priority: Int? = nil) {
        self.id = id
        self.url = url
        self.socialprotocol = socialprotocol
        self.accountId = accountId
        self.accountURL = accountURL
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required fields
        self.url = try container.decode(URL.self, forKey: .url)
        self.socialprotocol = try container.decode(String.self, forKey: .socialprotocol)
        // Optional fields
        self.accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        self.accountURL = try container.decodeIfPresent(URL.self, forKey: .accountURL)
        self.priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        // Generate a UUID if not present (not decoded from payload)
        self.id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(socialprotocol, forKey: .socialprotocol)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encodeIfPresent(accountURL, forKey: .accountURL)
        try container.encodeIfPresent(priority, forKey: .priority)
    }
}

struct PersonInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var role: String?
    var href: URL?
    var img: URL?
}

struct PodcastAlternativeFeed: Codable, Hashable, Identifiable, Sendable {
    var id: URL { url }

    var url: URL
    var title: String?
    var type: String?

    var displayTitle: String {
        if let title, title.isEmpty == false {
            return title
        }

        return url.absoluteString.removingPercentEncoding ?? url.absoluteString
    }
}

@Model
final class Podcast: Identifiable {
    var title: String = "Loading..."
    var desc: String?
    var author: String?
     var feed: URL?
    var link: URL?
    
    var language: String?
    
    var copyright: String?
    @Relationship(deleteRule: .cascade) var episodes: [Episode]? = []
    var lastBuildDate: Date?
    var imageURL: URL?
    @Relationship(deleteRule: .cascade) var metaData: PodcastMetaData?
    @Relationship(deleteRule: .cascade) var settings: PodcastSettings?
   
    var funding: [FundingInfo] = [] // See also: Episode.funding
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    var alternativeFeeds: [PodcastAlternativeFeed] = []
    var optionalTags: PodcastNamespaceOptionalTags?
    
    @Transient var message: String?
    
    
    // calculated properties that will be generated out of existing properties.
    
   var directoryURL: URL?  {
        URL.documentsDirectory
            .appending(path: "\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "default")", directoryHint: .isDirectory)
    }
    

    
    init(feed: URL) {
        self.feed = feed
        self.title = feed.absoluteString.removingPercentEncoding ?? "default"
        self.metaData = PodcastMetaData()
    }
    
    init(from feedData: PodcastFeed) {
            self.feed = feedData.url
            self.title = feedData.title ?? feedData.url?.absoluteString.removingPercentEncoding ?? "New Podcast"
            self.desc = feedData.description
            self.author = feedData.artist
            self.imageURL = feedData.artworkURL
            self.link = feedData.link
            self.copyright = feedData.copyright
            self.funding = feedData.funding
            self.social = feedData.social
            self.people = feedData.people
            self.alternativeFeeds = feedData.alternativeFeeds
            self.optionalTags = feedData.optionalTags
            self.metaData = PodcastMetaData()
            self.settings = PodcastSettings()
            // Episodes are populated later during the network update.
        }
    
    var isSubscribed: Bool {
        metaData?.isSubscribed != false
    }

    func matchesFeedURL(_ url: URL) -> Bool {
        if let feed, feed.podcastFeedComparisonKeys.intersection(url.podcastFeedComparisonKeys).isEmpty == false {
            return true
        }

        return alternativeFeeds.contains {
            $0.url.podcastFeedComparisonKeys.intersection(url.podcastFeedComparisonKeys).isEmpty == false
        }
    }

    func matchesWebURL(_ url: URL) -> Bool {
        guard let link else { return false }
        return link.matchesPodcastWebURL(url)
    }
}


@Model final class PodcastMetaData{
    static let abandonedFailureThreshold = 3
    static let abandonedFailureDuration: TimeInterval = 7 * 24 * 60 * 60
    static let cancelledMinimumRegularSilenceDuration: TimeInterval = 45 * 24 * 60 * 60
    static let cancelledMinimumIrregularSilenceDuration: TimeInterval = 90 * 24 * 60 * 60

    var lastRefresh:Date?
    
    // these properties are supposed to be used for background refresh checks
    var feedUpdated:Bool? // has the feed been updated and should refresh?
    var feedUpdateCheckDate:Date? // when has feedUpdated been set?
    var nextPredictedReleaseDate: Date?
    var nextPredictedRefreshStartDate: Date?
    var nextPredictedRefreshEndDate: Date?
    var releasePredictionUpdatedAt: Date?
    var consecutiveFeedFailureCount: Int = 0
    var firstConsecutiveFeedFailureDate: Date?
    var lastFeedFailureDate: Date?
    var lastFeedFailureStatusCode: Int?
    var lastFeedFailureMessage: String?
    var subscriptionDate: Date? = Date()
    
    
    @Transient var isUpdating: Bool = false
    @Transient var message: String?

    
    var isSubscribed: Bool = true
    
    @Relationship(inverse: \Podcast.metaData) var podcast: Podcast?
    init() {
    }

    var feedAbandonmentAssessment: PodcastFeedAbandonmentAssessment? {
        abandonmentAssessment(at: Date())
    }

    var isFeedLikelyAbandoned: Bool {
        isLikelyAbandoned(at: Date())
    }

    func isLikelyAbandoned(at now: Date) -> Bool {
        abandonmentAssessment(at: now) != nil
    }

    func abandonmentAssessment(at now: Date) -> PodcastFeedAbandonmentAssessment? {
        PodcastFeedAbandonmentAssessment.evaluate(
            metadata: self,
            podcast: podcast,
            now: now
        )
    }

    var feedFailureStatusDescription: String? {
        guard let lastFeedFailureStatusCode else { return nil }

        switch lastFeedFailureStatusCode {
        case 404:
            return "404 Not Found"
        case 410:
            return "410 Gone"
        case 451:
            return "451 Unavailable for Legal Reasons"
        case 500...599:
            return "\(lastFeedFailureStatusCode) Server Error"
        default:
            return "HTTP \(lastFeedFailureStatusCode)"
        }
    }
}

struct PodcastFeedAbandonmentAssessment: Equatable {
    enum Kind: Equatable {
        case unavailableFeed
        case likelyCancelled
    }

    let kind: Kind
    let title: String
    let detail: String
    let evidenceDate: Date?
    let predictedCadenceLabel: String?
    let missedReleaseCount: Int?

    static func evaluate(
        metadata: PodcastMetaData,
        podcast: Podcast?,
        now: Date = Date()
    ) -> PodcastFeedAbandonmentAssessment? {
        if hasSustainedTerminalFailure(metadata: metadata, now: now) {
            return PodcastFeedAbandonmentAssessment(
                kind: .unavailableFeed,
                title: "Podcast feed unavailable",
                detail: "The feed has been unreachable repeatedly for more than seven days.",
                evidenceDate: metadata.lastFeedFailureDate,
                predictedCadenceLabel: nil,
                missedReleaseCount: nil
            )
        }

        guard metadata.isSubscribed,
              let podcast,
              let pattern = PodcastReleasePredictor.releasePattern(
                for: podcast,
                before: now,
                allowRelationshipFallback: true
              )
        else {
            return nil
        }

        let interval = max(pattern.estimatedInterval, 24 * 60 * 60)
        let quietDuration = now.timeIntervalSince(pattern.latestReleaseDate)
        let requiredSilence = requiredSilenceDuration(
            for: pattern.cadence,
            estimatedInterval: interval
        )
        guard quietDuration >= requiredSilence else { return nil }

        let firstMissedReleaseDate = pattern.latestReleaseDate.addingTimeInterval(interval)
        guard let latestEvidenceDate = latestEvidenceDate(metadata: metadata),
              latestEvidenceDate >= firstMissedReleaseDate,
              now.timeIntervalSince(latestEvidenceDate) <= requiredEvidenceRecency(
                estimatedInterval: interval
              )
        else {
            return nil
        }

        let hasParsedAfterMissedRelease = metadata.lastRefresh.map { $0 >= firstMissedReleaseDate } ?? false
        let hasUnmodifiedCheckAfterMissedRelease = metadata.feedUpdated == false
            && (metadata.feedUpdateCheckDate.map { $0 >= firstMissedReleaseDate } ?? false)
        guard hasParsedAfterMissedRelease || hasUnmodifiedCheckAfterMissedRelease else {
            return nil
        }

        let missedReleaseCount = max(1, Int(quietDuration / interval))
        let cadenceLabel = pattern.cadence.label()
        return PodcastFeedAbandonmentAssessment(
            kind: .likelyCancelled,
            title: "Podcast may be cancelled",
            detail: "The feed still checks successfully, but no new episode has appeared after multiple expected releases.",
            evidenceDate: latestEvidenceDate,
            predictedCadenceLabel: cadenceLabel,
            missedReleaseCount: missedReleaseCount
        )
    }

    private static func hasSustainedTerminalFailure(
        metadata: PodcastMetaData,
        now: Date
    ) -> Bool {
        guard metadata.consecutiveFeedFailureCount >= PodcastMetaData.abandonedFailureThreshold,
              let firstFailureDate = metadata.firstConsecutiveFeedFailureDate,
              now.timeIntervalSince(firstFailureDate) >= PodcastMetaData.abandonedFailureDuration,
              let statusCode = metadata.lastFeedFailureStatusCode else {
            return false
        }

        return statusCode == 404
            || statusCode == 410
            || statusCode == 451
            || statusCode >= 500
    }

    private static func requiredSilenceDuration(
        for cadence: PodcastReleasePredictor.ReleaseCadence,
        estimatedInterval: TimeInterval
    ) -> TimeInterval {
        if cadence.isIrregular {
            return max(
                PodcastMetaData.cancelledMinimumIrregularSilenceDuration,
                min(180 * 24 * 60 * 60, estimatedInterval * 4)
            )
        }

        return max(
            PodcastMetaData.cancelledMinimumRegularSilenceDuration,
            min(180 * 24 * 60 * 60, estimatedInterval * 6)
        )
    }

    private static func requiredEvidenceRecency(estimatedInterval: TimeInterval) -> TimeInterval {
        max(14 * 24 * 60 * 60, min(60 * 24 * 60 * 60, estimatedInterval * 2))
    }

    private static func latestEvidenceDate(metadata: PodcastMetaData) -> Date? {
        [metadata.lastRefresh, metadata.feedUpdateCheckDate]
            .compactMap { $0 }
            .max()
    }
}
