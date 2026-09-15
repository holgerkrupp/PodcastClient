import Foundation
import XCTest
@testable import UpNext

final class PodcastDiscoveryRegistryTests: XCTestCase {

    // MARK: - Provider registration

    func testShippedProvidersAreRegisteredForCatalogBroadcasters() {
        let registry = PodcastDiscoveryRegistry()

        for provider in PodcastDiscoveryRegistry.defaultProviders() {
            XCTAssertNotNil(
                registry.broadcaster(withID: provider.broadcaster.id),
                "\(provider.id) has no catalog entry"
            )
            XCTAssertEqual(provider.id, provider.broadcaster.id)
            XCTAssertNotNil(registry.provider(for: provider.broadcaster.id))
        }
    }

    func testPlannedBroadcastersAreNotOfferedAsBrowsable() {
        let registry = PodcastDiscoveryRegistry()
        let browsableIDs = Set(registry.browsableBroadcasters.map(\.id))

        for broadcaster in PublicBroadcasterCatalog.plannedBroadcasters {
            XCTAssertFalse(
                browsableIDs.contains(broadcaster.id),
                "\(broadcaster.id) has no provider but is offered as browsable"
            )
            XCTAssertFalse(registry.isBrowsable(broadcaster))
        }
    }

    func testDisabledProviderIsRemovedFromDiscovery() {
        let configuration = PodcastDiscoveryConfiguration(disabledProviderIDs: ["ardsounds"])
        let registry = PodcastDiscoveryRegistry(configuration: configuration)

        XCTAssertNil(registry.provider(for: "ardsounds"))
        XCTAssertFalse(registry.browsableBroadcasters.contains { $0.id == "ardsounds" })

        // Everything else keeps working: one integration can go away on its own.
        XCTAssertNotNil(registry.provider(for: "srf"))
        XCTAssertNotNil(registry.provider(for: "rnz"))
    }

    func testBroadcastersAreGroupedByRegionInOrder() {
        let registry = PodcastDiscoveryRegistry()
        let groups = registry.browsableBroadcastersByRegion

        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups.map(\.region.sortIndex), groups.map(\.region.sortIndex).sorted())

        let grouped = groups.flatMap(\.broadcasters).count
        XCTAssertEqual(grouped, registry.browsableBroadcasters.count)
    }

    // MARK: - Capabilities

    func testSearchableProvidersAllDeclareSearch() {
        let registry = PodcastDiscoveryRegistry()

        XCTAssertFalse(registry.searchableProviders.isEmpty)
        for provider in registry.searchableProviders {
            XCTAssertTrue(provider.capabilities.contains(.search))
        }
    }

    func testBrowseModesFollowCapabilities() {
        XCTAssertEqual(
            PodcastDiscoveryCapabilities([.categories, .allPodcasts, .search, .feedURL]).browseModes,
            [.categories, .allPodcasts, .search]
        )

        // A search-only provider advertises no browse controls it cannot serve.
        XCTAssertEqual(
            PodcastDiscoveryCapabilities([.search, .feedURL]).browseModes,
            [.search]
        )

        XCTAssertTrue(PodcastDiscoveryCapabilities([.feedURL]).browseModes.isEmpty)
    }

    func testARDBrowsesItsCatalogueButStillCannotOfferFeaturedShows() {
        let provider = ARDSoundsDiscoveryProvider(broadcaster: PublicBroadcasterCatalog.ardSounds)
        XCTAssertEqual(provider.capabilities.browseModes, [.categories, .allPodcasts, .search])
    }

    func testEveryProviderOnlyAdvertisesModesItCanServe() async {
        for provider in PodcastDiscoveryRegistry.defaultProviders() {
            let modes = provider.capabilities.browseModes
            XCTAssertFalse(modes.isEmpty, "\(provider.id) offers no way in")

            // A mode the provider cannot actually serve would render an empty
            // control; the protocol's default implementations make that throw.
            if modes.contains(.featured) == false {
                do {
                    _ = try await provider.featured(refresh: false)
                    XCTFail("\(provider.id) serves featured without advertising it")
                } catch {
                    XCTAssertEqual(error as? PodcastDiscoveryError, .unsupportedOperation)
                }
            }
        }
    }

    func testUnsupportedOperationsThrowRatherThanReturningEmptyResults() async {
        let provider = StubDiscoveryProvider(
            broadcaster: .testBroadcaster(id: "stub"),
            capabilities: [.search]
        )

        do {
            _ = try await provider.categories(refresh: false)
            XCTFail("Expected categories to be unsupported")
        } catch {
            XCTAssertEqual(error as? PodcastDiscoveryError, .unsupportedOperation)
        }
    }

    // MARK: - Broadcaster metadata

    func testBroadcasterMetadataIsComplete() {
        for broadcaster in PublicBroadcasterCatalog.all {
            XCTAssertFalse(broadcaster.id.isEmpty)
            XCTAssertFalse(broadcaster.name.isEmpty)
            XCTAssertEqual(broadcaster.countryCode.count, 2, "\(broadcaster.id) needs an ISO country code")
            XCTAssertNotNil(broadcaster.website, "\(broadcaster.id) has no website to fall back on")
            // The country is spelled out, never conveyed by the flag alone.
            XCTAssertFalse(broadcaster.countryName.isEmpty)
        }
    }

    func testBroadcasterIdentifiersAreUnique() {
        let ids = PublicBroadcasterCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testFlagIsDerivedFromCountryCode() {
        XCTAssertEqual(PublicBroadcasterCatalog.srf.flag, "🇨🇭")
        XCTAssertEqual(PublicBroadcasterCatalog.rnz.flag, "🇳🇿")
        XCTAssertEqual(PublicBroadcasterCatalog.ardSounds.flag, "🇩🇪")

        let malformed = PublicBroadcaster(
            id: "x",
            name: "X",
            countryCode: "XYZ",
            region: .europe,
            summary: LocalizedStringResource("Test broadcaster.")
        )
        XCTAssertNil(malformed.flag)
    }

    // MARK: - Configuration

    func testConfigurationReadsDisabledProvidersFromDefaults() {
        let defaults = UserDefaults(suiteName: "PodcastDiscoveryRegistryTests")!
        defaults.removePersistentDomain(forName: "PodcastDiscoveryRegistryTests")
        defaults.set(["RNZ"], forKey: PodcastDiscoveryConfiguration.disabledProvidersDefaultsKey)

        let configuration = PodcastDiscoveryConfiguration.resolved(
            bundle: .main,
            defaults: defaults,
            environment: [:]
        )

        XCTAssertFalse(configuration.isEnabled("rnz"))
        XCTAssertTrue(configuration.isEnabled("srf"))

        defaults.removePersistentDomain(forName: "PodcastDiscoveryRegistryTests")
    }

    func testNoProviderShipsWithAHardcodedAPIKey() {
        let configuration = PodcastDiscoveryConfiguration.resolved(environment: [:])

        for provider in PodcastDiscoveryRegistry.defaultProviders() {
            XCTAssertNil(configuration.apiKey(for: provider.id))
        }
    }
}
