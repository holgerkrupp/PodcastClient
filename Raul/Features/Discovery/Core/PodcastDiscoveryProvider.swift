//
//  PodcastDiscoveryProvider.swift
//  Raul
//
//  The contract every public-broadcaster integration implements. Providers are
//  the only place that knows about a broadcaster's API or webpage structure;
//  everything above this line works with `DiscoveredPodcast` values.
//

import Foundation

/// What a provider can actually do. The UI renders browse modes from this and
/// never assumes that categories, search or direct feeds exist.
struct PodcastDiscoveryCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// An editorially curated selection.
    static let featured = PodcastDiscoveryCapabilities(rawValue: 1 << 0)
    /// Browsable groupings within the broadcaster.
    static let categories = PodcastDiscoveryCapabilities(rawValue: 1 << 1)
    /// A complete A–Z catalogue.
    static let allPodcasts = PodcastDiscoveryCapabilities(rawValue: 1 << 2)
    /// A selection of the broadcaster's shows drawn from someone else's
    /// catalogue — complete only as far as that catalogue goes.
    static let publisherCatalog = PodcastDiscoveryCapabilities(rawValue: 1 << 5)
    /// Free-text search inside this broadcaster (also enables cross-provider search).
    static let search = PodcastDiscoveryCapabilities(rawValue: 1 << 3)
    /// The provider can produce an ordinary RSS URL for its shows.
    static let feedURL = PodcastDiscoveryCapabilities(rawValue: 1 << 4)
}

/// The browse modes the broadcaster screen can offer, in display order.
enum PodcastDiscoveryBrowseMode: String, Sendable, Hashable, Identifiable, CaseIterable {
    case featured
    case categories
    case allPodcasts
    case publisherCatalog
    case search

    var id: String { rawValue }

    var capability: PodcastDiscoveryCapabilities {
        switch self {
        case .featured: return .featured
        case .categories: return .categories
        case .allPodcasts: return .allPodcasts
        case .publisherCatalog: return .publisherCatalog
        case .search: return .search
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .featured: return LocalizedStringResource("Featured")
        case .categories: return LocalizedStringResource("Categories")
        case .allPodcasts: return LocalizedStringResource("All Podcasts")
        case .publisherCatalog: return LocalizedStringResource("Podcasts")
        case .search: return LocalizedStringResource("Search")
        }
    }

    var symbolName: String {
        switch self {
        case .featured: return "sparkles"
        case .categories: return "square.grid.2x2"
        case .allPodcasts: return "list.bullet"
        case .publisherCatalog: return "list.bullet"
        case .search: return "magnifyingglass"
        }
    }
}

extension PodcastDiscoveryCapabilities {
    /// Browse modes derived from the capability set, in display order.
    var browseModes: [PodcastDiscoveryBrowseMode] {
        PodcastDiscoveryBrowseMode.allCases.filter { contains($0.capability) }
    }
}

protocol PodcastDiscoveryProvider: Sendable {
    /// Matches the identifier of the broadcaster this provider serves.
    var id: String { get }
    var broadcaster: PublicBroadcaster { get }
    var capabilities: PodcastDiscoveryCapabilities { get }
    /// Shown under the results when the data does not come from the broadcaster
    /// itself, so the source is never implied to be something it is not.
    var attribution: LocalizedStringResource? { get }

    func featured(refresh: Bool) async throws -> [DiscoveredPodcast]
    func categories(refresh: Bool) async throws -> [PodcastDiscoveryCategory]
    func podcasts(in category: PodcastDiscoveryCategory, refresh: Bool) async throws -> [DiscoveredPodcast]
    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast]
    func search(_ query: String) async throws -> [DiscoveredPodcast]

    /// Resolves an ordinary RSS feed for the show, so the existing import
    /// pipeline can take over. Throws `.feedNotFound` when there is none.
    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL
}

// Unsupported operations are the norm, not the exception: a provider only
// implements the modes its source actually offers.
extension PodcastDiscoveryProvider {
    var name: String { broadcaster.name }

    var attribution: LocalizedStringResource? { nil }

    func featured(refresh: Bool) async throws -> [DiscoveredPodcast] {
        throw PodcastDiscoveryError.unsupportedOperation
    }

    func categories(refresh: Bool) async throws -> [PodcastDiscoveryCategory] {
        throw PodcastDiscoveryError.unsupportedOperation
    }

    func podcasts(in category: PodcastDiscoveryCategory, refresh: Bool) async throws -> [DiscoveredPodcast] {
        throw PodcastDiscoveryError.unsupportedOperation
    }

    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast] {
        throw PodcastDiscoveryError.unsupportedOperation
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        throw PodcastDiscoveryError.unsupportedOperation
    }

    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
        if let feedURL = podcast.feedURL {
            return feedURL
        }
        throw PodcastDiscoveryError.feedNotFound
    }
}
