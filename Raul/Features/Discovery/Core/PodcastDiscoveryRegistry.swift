//
//  PodcastDiscoveryRegistry.swift
//  Raul
//
//  Pairs broadcasters with the providers that can browse them. This is the only
//  place that knows which concrete providers exist — the UI asks the registry
//  and never names a broadcaster.
//

import Foundation

struct PodcastDiscoveryRegistry: Sendable {
    static let shared = PodcastDiscoveryRegistry()

    /// Every broadcaster in the catalog, in catalog order.
    let broadcasters: [PublicBroadcaster]
    private let providersByBroadcasterID: [String: any PodcastDiscoveryProvider]

    init(
        broadcasters: [PublicBroadcaster] = PublicBroadcasterCatalog.all,
        providers: [any PodcastDiscoveryProvider]? = nil,
        configuration: PodcastDiscoveryConfiguration = .resolved()
    ) {
        self.broadcasters = broadcasters

        let resolvedProviders = providers ?? Self.defaultProviders()
        var byID: [String: any PodcastDiscoveryProvider] = [:]

        for provider in resolvedProviders where configuration.isEnabled(provider.id) {
            byID[provider.broadcaster.id] = provider
        }

        self.providersByBroadcasterID = byID
    }

    /// The providers shipped with the app, one per browsable broadcaster.
    /// Adding a broadcaster means adding a line here and a catalog entry.
    static func defaultProviders() -> [any PodcastDiscoveryProvider] {
        [
            SRGSSRDiscoveryProvider(businessUnit: .srf, broadcaster: PublicBroadcasterCatalog.srf),
            SRGSSRDiscoveryProvider(businessUnit: .rts, broadcaster: PublicBroadcasterCatalog.rts),
            ORFDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.orf),
            RNZDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.rnz),
            RTPDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.rtp),
            ARDSoundsDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.ardSounds),
            CBCDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.cbc),

            // Broadcasters with no directory of their own, found through the
            // Apple Podcasts catalogue instead. Their screens say so.
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.bbc,
                rule: ApplePublisherRules.bbc
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.npr,
                rule: ApplePublisherRules.npr
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.sverigesRadio,
                rule: ApplePublisherRules.sverigesRadio
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.rte,
                rule: ApplePublisherRules.rte
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.npo,
                rule: ApplePublisherRules.npo
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.abc,
                rule: ApplePublisherRules.abc
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.pbs,
                rule: ApplePublisherRules.pbs
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.vrt,
                rule: ApplePublisherRules.vrt
            ),
            ApplePublisherDiscoveryProvider(
                broadcaster: PublicBroadcasterCatalog.zdf,
                rule: ApplePublisherRules.zdf
            )
        ]
    }

    func provider(for broadcasterID: String) -> (any PodcastDiscoveryProvider)? {
        providersByBroadcasterID[broadcasterID]
    }

    func broadcaster(withID broadcasterID: String) -> PublicBroadcaster? {
        broadcasters.first { $0.id == broadcasterID }
    }

    func isBrowsable(_ broadcaster: PublicBroadcaster) -> Bool {
        providersByBroadcasterID[broadcaster.id] != nil
    }

    /// Broadcasters that can actually be browsed right now, in catalog order.
    var browsableBroadcasters: [PublicBroadcaster] {
        broadcasters.filter(isBrowsable)
    }

    /// Providers that take part in cross-provider search, in catalog order so
    /// ranking ties resolve deterministically.
    var searchableProviders: [any PodcastDiscoveryProvider] {
        broadcasters.compactMap { broadcaster in
            guard let provider = providersByBroadcasterID[broadcaster.id],
                  provider.capabilities.contains(.search) else { return nil }
            return provider
        }
    }

    /// Browsable broadcasters grouped into regions, for the sectioned list.
    var browsableBroadcastersByRegion: [(region: PublicBroadcasterRegion, broadcasters: [PublicBroadcaster])] {
        Dictionary(grouping: browsableBroadcasters, by: \.region)
            .map { (region: $0.key, broadcasters: $0.value) }
            .sorted { $0.region.sortIndex < $1.region.sortIndex }
    }

}
