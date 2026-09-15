//
//  SRGSSRModels.swift
//  Raul
//
//  Response shapes of the SRG SSR Integration Layer. These types stay private to
//  the provider: everything leaving `SRGSSRDiscoveryProvider` is a
//  `DiscoveredPodcast`.
//

import Foundation

/// One of SRG SSR's business units. Each is a separate broadcaster in the catalog.
enum SRGSSRBusinessUnit: String, Sendable, CaseIterable {
    case srf
    case rts

    var broadcasterID: String { rawValue }

    var displayName: String {
        switch self {
        case .srf: return "SRF"
        case .rts: return "RTS"
        }
    }

    /// Language of the unit's programming, used to fill in `DiscoveredPodcast.language`.
    var languageCode: String {
        switch self {
        case .srf: return "de"
        case .rts: return "fr"
        }
    }

    var website: URL? {
        switch self {
        case .srf: return URL(string: "https://www.srf.ch/audio")
        case .rts: return URL(string: "https://www.rts.ch/audio-podcast/")
        }
    }
}

struct SRGSSRShowListResponse: Decodable, Sendable {
    let showList: [SRGSSRShow]?
    let next: URL?
}

struct SRGSSRSearchResponse: Decodable, Sendable {
    let searchResultShowList: [SRGSSRShow]?
    let next: URL?
}

struct SRGSSRTopic: Decodable, Sendable {
    let id: String
    let title: String
    let imageUrl: URL?
}

struct SRGSSRShow: Decodable, Sendable {
    let id: String
    let urn: String?
    let title: String
    let lead: String?
    let description: String?
    let imageUrl: URL?
    let podcastImageUrl: URL?
    /// The plain RSS feed. `podcastFeedSdUrl` is the standard-definition audio
    /// feed the Play apps link to; `podcastHdUrl` appears on some shows only.
    let podcastFeedSdUrl: URL?
    let podcastHdUrl: URL?
    /// A show page that advertises the RSS feed. SRF publishes feeds directly;
    /// RTS publishes this instead, so its feeds need one more hop.
    let podcastSubscriptionUrl: URL?
    let numberOfEpisodes: Int?
    let topicList: [SRGSSRTopic]?
    let vendor: String?

    var feedURL: URL? { podcastFeedSdUrl ?? podcastHdUrl }

    /// Whether this show is published as a podcast at all. Shows that are not
    /// are left out of discovery: they could never be subscribed to.
    var isSubscribable: Bool { feedURL != nil || podcastSubscriptionUrl != nil }

    var artworkURL: URL? { podcastImageUrl ?? imageUrl }

    var summary: String? {
        if let description, description.isEmpty == false { return description }
        if let lead, lead.isEmpty == false { return lead }
        return nil
    }
}
