import Foundation
import XCTest
@testable import UpNext

/// Cross-provider search: results combine, failures stay contained, duplicates
/// collapse and direct hits rank first.
final class PodcastDiscoverySearchTests: XCTestCase {

    private func registry(_ providers: [any PodcastDiscoveryProvider]) -> PodcastDiscoveryRegistry {
        PodcastDiscoveryRegistry(
            broadcasters: providers.map(\.broadcaster),
            providers: providers
        )
    }

    func testResultsFromSeveralProvidersAreCombined() async {
        let swiss = PublicBroadcaster.testBroadcaster(id: "srf", countryCode: "CH")
        let kiwi = PublicBroadcaster.testBroadcaster(id: "rnz", countryCode: "NZ", region: .asiaPacific)

        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: swiss,
                searchResults: [.testPodcast(id: "1", title: "Einfach Politik", broadcasterID: "srf")]
            ),
            StubDiscoveryProvider(
                broadcaster: kiwi,
                searchResults: [.testPodcast(id: "2", title: "The Detail", broadcasterID: "rnz")]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("politik")

        XCTAssertEqual(Set(results.map(\.title)), ["Einfach Politik", "The Detail"])
        XCTAssertEqual(Set(results.map(\.broadcasterID)), ["srf", "rnz"])
    }

    func testOneFailingProviderDoesNotFailTheSearch() async {
        let healthy = PublicBroadcaster.testBroadcaster(id: "rnz")
        let broken = PublicBroadcaster.testBroadcaster(id: "ardsounds")

        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(broadcaster: broken, searchError: PodcastDiscoveryError.unavailable),
            StubDiscoveryProvider(
                broadcaster: healthy,
                searchResults: [.testPodcast(id: "1", title: "The Detail", broadcasterID: "rnz")]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("detail")

        XCTAssertEqual(results.map(\.title), ["The Detail"])
    }

    func testAllProvidersFailingYieldsNoResultsRatherThanAnError() async {
        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "a"),
                searchError: PodcastDiscoveryError.parsingFailed
            ),
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "b"),
                searchError: URLError(.timedOut)
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("anything")
        XCTAssertTrue(results.isEmpty)
    }

    func testProvidersAreSearchedConcurrently() async {
        // Four providers that each take 400 ms: sequentially that is 1.6 s.
        let providers: [any PodcastDiscoveryProvider] = (0..<4).map { index in
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "p\(index)"),
                searchResults: [.testPodcast(id: "\(index)", title: "Show \(index)", broadcasterID: "p\(index)")],
                searchDelay: .milliseconds(400)
            )
        }

        let started = ContinuousClock.now
        let results = await PodcastDiscoveryService(registry: registry(providers)).search("show")
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(results.count, 4)
        XCTAssertLessThan(elapsed, .milliseconds(1200))
    }

    func testDuplicateFeedsAreCollapsedAcrossProviders() async {
        let feed = URL(string: "https://example.org/feed.xml")!
        // Same feed, spelled differently by two sources.
        let alternate = URL(string: "http://Example.org/feed.xml/")!

        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "a"),
                searchResults: [.testPodcast(id: "1", title: "Shared Show", broadcasterID: "a", feedURL: feed)]
            ),
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "b"),
                searchResults: [.testPodcast(id: "2", title: "Shared Show", broadcasterID: "b", feedURL: alternate)]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("shared")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.broadcasterID, "a", "The first provider in catalog order wins")
    }

    func testDifferentFeedsWithTheSameTitleAreKept() async {
        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "a"),
                searchResults: [
                    .testPodcast(
                        id: "1",
                        title: "Wissen",
                        broadcasterID: "a",
                        feedURL: URL(string: "https://a.example/feed.xml")
                    )
                ]
            ),
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "b"),
                searchResults: [
                    .testPodcast(
                        id: "2",
                        title: "Wissen",
                        broadcasterID: "b",
                        feedURL: URL(string: "https://b.example/feed.xml")
                    )
                ]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("wissen")
        XCTAssertEqual(results.count, 2)
    }

    func testExactTitleMatchesRankAboveLooserOnes() async {
        let broadcaster = PublicBroadcaster.testBroadcaster(id: "a")

        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: broadcaster,
                searchResults: [
                    .testPodcast(id: "3", title: "Talking about Politik", broadcasterID: "a"),
                    .testPodcast(id: "2", title: "Politik-Debatte", broadcasterID: "a"),
                    .testPodcast(id: "1", title: "Politik", broadcasterID: "a")
                ]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("Politik")

        XCTAssertEqual(results.map(\.title), ["Politik", "Politik-Debatte", "Talking about Politik"])
    }

    func testSearchingForABroadcasterNameSurfacesItsShows() async {
        let rnz = PublicBroadcaster.testBroadcaster(id: "rnz", name: "RNZ", countryCode: "NZ")
        let other = PublicBroadcaster.testBroadcaster(id: "srf", name: "SRF")

        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: other,
                searchResults: [.testPodcast(id: "1", title: "Unrelated Show", broadcasterID: "srf")]
            ),
            StubDiscoveryProvider(
                broadcaster: rnz,
                searchResults: [.testPodcast(id: "2", title: "Mediawatch", broadcasterID: "rnz")]
            )
        ]

        let results = await PodcastDiscoveryService(registry: registry(providers)).search("RNZ")

        XCTAssertEqual(results.first?.broadcasterID, "rnz")
    }

    func testBlankQueryDoesNotReachProviders() async {
        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "a"),
                searchResults: [.testPodcast(id: "1", title: "Show", broadcasterID: "a")]
            )
        ]

        let service = PodcastDiscoveryService(registry: registry(providers))
        let empty = await service.search("")
        let blank = await service.search("   ")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(blank.isEmpty)
    }

    func testProvidersWithoutSearchAreNotQueried() async {
        let providers: [any PodcastDiscoveryProvider] = [
            StubDiscoveryProvider(
                broadcaster: .testBroadcaster(id: "browse-only"),
                capabilities: [.allPodcasts, .feedURL],
                searchResults: [.testPodcast(id: "1", title: "Hidden", broadcasterID: "browse-only")]
            )
        ]

        let searchRegistry = registry(providers)
        XCTAssertTrue(searchRegistry.searchableProviders.isEmpty)
        let results = await PodcastDiscoveryService(registry: searchRegistry).search("hidden")
        XCTAssertTrue(results.isEmpty)
    }

    func testFeedNormalizationIgnoresSchemeCaseAndTrailingSlash() {
        let key = DiscoveredPodcast.normalizedFeedKey(URL(string: "https://example.org/Feed.xml")!)

        XCTAssertEqual(key, DiscoveredPodcast.normalizedFeedKey(URL(string: "http://EXAMPLE.org/Feed.xml/")!))
        XCTAssertNotEqual(key, DiscoveredPodcast.normalizedFeedKey(URL(string: "https://example.org/other.xml")!))
    }
}
