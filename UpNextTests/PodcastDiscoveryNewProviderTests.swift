import Foundation
import XCTest
@testable import UpNext

/// Providers added after the first iteration: CBC's directory, ARD's catalogue
/// browsing, and the Apple-catalogue-backed broadcasters.
final class PodcastDiscoveryNewProviderTests: XCTestCase {

    private struct PodcastFeedFixtureTransport: PodcastHTTPTransport {
        let responses: [String: (Data, String)]

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            guard let (data, contentType) = responses[url.absoluteString] else {
                throw PodcastHTTPError.invalidResponse(url)
            }
            return (
                data,
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": contentType]
                )!
            )
        }
    }

    private final class RetryAttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private struct RetryDiscoveryProvider: PodcastDiscoveryProvider {
        let broadcaster: PublicBroadcaster
        let attempts: RetryAttemptCounter
        let feedURL: URL

        var id: String { broadcaster.id }
        var capabilities: PodcastDiscoveryCapabilities { [.feedURL] }

        func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
            guard attempts.next() > 1 else { throw PodcastDiscoveryError.unavailable }
            return feedURL
        }
    }

    // MARK: - CBC

    func testCBCDirectoryExtractsTitleArtworkDescriptionCategoryAndFeed() throws {
        let markup = try DiscoveryFixture.markup("cbc-podcast-directory")

        let podcasts = CBCDirectoryParser.parseDirectory(
            markup: markup,
            providerID: "cbc",
            broadcasterID: "cbc"
        )

        XCTAssertEqual(podcasts.count, 2)

        // The identifier comes from the feed, which is stable, while the title
        // tracks whatever season CBC is currently running under that feed.
        let uncover = try XCTUnwrap(podcasts.first { $0.id == "uncover" })
        XCTAssertEqual(uncover.title, "The Mile Zero Murders from Uncover")
        XCTAssertEqual(
            uncover.feedURL?.absoluteString,
            "https://www.cbc.ca/podcasting/includes/uncover.xml"
        )
        XCTAssertEqual(uncover.artworkURL?.host(), "www.cbc.ca")
        XCTAssertEqual(uncover.providerReference, "True Crime")
        XCTAssertEqual(uncover.webpageURL?.absoluteString, "https://www.cbc.ca/listen/cbc-podcasts/187-uncover")

        let summary = try XCTUnwrap(uncover.summary)
        XCTAssertFalse(summary.isEmpty)
        // The page escapes its HTML as \x3c…; neither the escapes nor the tags
        // may survive into the row subtitle.
        XCTAssertFalse(summary.contains("\\x3c"), summary)
        XCTAssertFalse(summary.contains("<p>"), summary)
    }

    func testCBCCategoriesComeFromEachShowsOwnCategory() throws {
        let markup = try DiscoveryFixture.markup("cbc-podcast-directory")
        let podcasts = CBCDirectoryParser.parseDirectory(markup: markup, providerID: "cbc", broadcasterID: "cbc")

        let categories = CBCDirectoryParser.categories(from: podcasts, providerID: "cbc")

        XCTAssertFalse(categories.isEmpty)
        XCTAssertTrue(categories.contains { $0.id == "True Crime" })
        XCTAssertEqual(categories.map(\.title), categories.map(\.title).sorted())
        for category in categories {
            XCTAssertEqual(category.providerID, "cbc")
            XCTAssertEqual(
                category.podcastCount,
                podcasts.filter { $0.providerReference == category.id }.count
            )
        }
    }

    func testCBCParsingOfMalformedMarkupYieldsNothingInsteadOfCrashing() throws {
        let markup = try DiscoveryFixture.markup("cbc-podcast-directory")

        for truncation in [0, 32, 900, 5000] {
            _ = CBCDirectoryParser.parseDirectory(
                markup: String(markup.prefix(truncation)),
                providerID: "cbc",
                broadcasterID: "cbc"
            )
        }

        XCTAssertTrue(
            CBCDirectoryParser.parseDirectory(markup: "", providerID: "cbc", broadcasterID: "cbc").isEmpty
        )
        // A feed entry with no title is dropped rather than shown blank.
        XCTAssertTrue(
            CBCDirectoryParser.parseDirectory(
                markup: "{\"rssUrl\":\"https://www.cbc.ca/podcasting/includes/x.xml\"}",
                providerID: "cbc",
                broadcasterID: "cbc"
            ).isEmpty
        )
    }

    func testCBCSurfacesDirectFeedsSoNoResolutionIsNeeded() async throws {
        let markup = try DiscoveryFixture.markup("cbc-podcast-directory")
        let transport = StubTransport()
        transport.stub("https://www.cbc.ca/listen/cbc-podcasts", markup: markup)

        let provider = CBCDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.cbc,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        let podcasts = try await provider.allPodcasts(refresh: false)
        let first = try XCTUnwrap(podcasts.first)
        let requestsBefore = transport.requestedURLs.count

        let feed = try await provider.resolveFeed(for: first)

        XCTAssertEqual(feed, first.feedURL)
        XCTAssertEqual(transport.requestedURLs.count, requestsBefore)
    }

    // MARK: - ARD catalogue browsing

    private let ardOrganizations = """
    { "data": { "organizations": { "nodes": [
      { "id": "1", "name": "BR", "publicationServices": { "nodes": [
          { "id": "10", "title": "Bayern 2", "programSets": { "nodes": [
              { "id": "100", "title": "Zündfunk", "numberOfElements": 12,
                "image": { "url1X1": "https://img.example/a?w={width}" } },
              { "id": "101", "title": "Radiowissen", "numberOfElements": 30 }
          ] } }
      ] } },
      { "id": "2", "name": "WDR", "publicationServices": { "nodes": [
          { "id": "20", "title": "WDR 5", "programSets": { "nodes": [
              { "id": "200", "title": "Alles in Butter" },
              { "id": "100", "title": "Zündfunk" }
          ] } }
      ] } },
      { "id": "3", "name": "Empty", "publicationServices": { "nodes": [] } }
    ] } } }
    """

    private func ardProvider(_ transport: StubTransport) -> ARDSoundsDiscoveryProvider {
        ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )
    }

    func testARDNowOffersCategoriesAndAFullCatalogue() async throws {
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/organizations", json: ardOrganizations)

        let provider = ardProvider(transport)

        XCTAssertEqual(provider.capabilities.browseModes, [.categories, .allPodcasts, .search])

        let podcasts = try await provider.allPodcasts(refresh: false)
        // Sorted, and the show carried by two stations appears once.
        XCTAssertEqual(podcasts.map(\.title), ["Alles in Butter", "Radiowissen", "Zündfunk"])

        let zuendfunk = try XCTUnwrap(podcasts.first { $0.id == "100" })
        XCTAssertEqual(zuendfunk.author, "Bayern 2", "The station is the most useful author")
        XCTAssertEqual(zuendfunk.artworkURL?.absoluteString, "https://img.example/a?w=448")
        XCTAssertEqual(zuendfunk.episodeCount, 12)
        XCTAssertNil(zuendfunk.feedURL, "ARD exposes no RSS of its own")
    }

    func testARDCategoriesAreOrganizationsAndSkipEmptyOnes() async throws {
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/organizations", json: ardOrganizations)

        let categories = try await ardProvider(transport).categories(refresh: false)

        XCTAssertEqual(categories.map(\.title), ["BR", "WDR"])
        XCTAssertEqual(categories.first { $0.id == "1" }?.podcastCount, 2)
        XCTAssertEqual(categories.first { $0.id == "2" }?.podcastCount, 1)
    }

    func testARDCategoryContentsAndCaching() async throws {
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/organizations", json: ardOrganizations)

        let provider = ardProvider(transport)
        let categories = try await provider.categories(refresh: false)
        let br = try XCTUnwrap(categories.first { $0.id == "1" })

        let inBR = try await provider.podcasts(in: br, refresh: false)
        XCTAssertEqual(inBR.map(\.title), ["Radiowissen", "Zündfunk"])

        _ = try await provider.allPodcasts(refresh: false)
        XCTAssertEqual(transport.requestedURLs.count, 1, "Browsing must not refetch the catalogue")
    }

    func testARDCatalogueFailureStaysContained() async {
        let transport = StubTransport()
        transport.stub(
            "https://api.ardaudiothek.de",
            response: .init(data: Data("{}".utf8), statusCode: 502, contentType: "application/json")
        )

        do {
            _ = try await ardProvider(transport).allPodcasts(refresh: false)
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? PodcastDiscoveryError, .unavailable)
        }
    }

    func testAchtsamResolvesOfficialDeutschlandfunkNovaFeedWithTitleVariation() async throws {
        // Recorded from ARD's live search API: the catalogue title is simply
        // "Achtsam" and identifies Deutschlandfunk Nova as the publisher.
        let searchFixture = """
        { "data": { "search": { "programSets": { "nodes": [
          { "id": "79305508", "title": "Achtsam", "numberOfElements": 169,
            "synopsis": "So kommen wir achtsamer und stressfreier durchs Leben.",
            "sharingUrl": "https://www.ardsounds.de/sendung/achtsam/urn:ard:show:7a9143c8d615db00/",
            "publicationService": { "title": "Deutschlandfunk Nova", "organizationName": "Deutschlandradio",
              "homepageUrl": "https://www.deutschlandfunknova.de/" } }
        ] } } } }
        """
        let detailFixture = """
        { "data": { "programSet": { "id": "79305508", "title": "Achtsam",
          "numberOfElements": 169, "sharingUrl": "https://www.ardsounds.de/sendung/achtsam/urn:ard:show:7a9143c8d615db00/",
          "feedUrl": null } } }
        """
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/search/programsets", json: searchFixture)
        transport.stub("https://api.ardaudiothek.de/graphql", json: detailFixture)
        transport.stub("https://www.ardsounds.de/sendung/achtsam/", markup: "<html><head></head></html>")

        let officialFeed = URL(string: "https://www.deutschlandfunknova.de/podcast/achtsam-mit-main-huong-und-diane")!
        let apple = ApplePodcastsFeedResolver(
            storefront: "de",
            searchCandidates: { _ in
                [
                    .init(
                        feedURL: officialFeed,
                        title: "Achtsam - Deutschlandfunk Nova",
                        publisher: "Deutschlandfunk Nova"
                    )
                ]
            }
        )
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel><title>Achtsam</title><itunes:author>Deutschlandfunk Nova</itunes:author>
            <item><guid>achtsam-2026-10-14</guid><title>Aphantasie: Ohne innere Bilder leben</title></item>
          </channel>
        </rss>
        """
        let feedClient = PodcastHTTPClient(transport: PodcastFeedFixtureTransport(responses: [
            officialFeed.absoluteString: (Data(rss.utf8), "application/rss+xml")
        ]))
        let provider = ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client,
            cache: PodcastDiscoveryCache(),
            appleResolver: apple,
            feedClient: feedClient
        )

        let results = try await provider.search("Achtsam")
        let show = try XCTUnwrap(results.first)
        let resolved = try await provider.resolveFeed(for: show)

        XCTAssertEqual(resolved, officialFeed)
        XCTAssertTrue(transport.requestedURLs.contains { $0.path == "/graphql" })
        XCTAssertFalse(transport.requestedURLs.contains { $0.host == "ardsounds.tisba.de" })
    }

    func testAchtsamUsesOptionalARDGraphQLFeedMetadataBeforeAppleSearch() async throws {
        let officialFeed = URL(string: "https://www.deutschlandfunknova.de/podcast/achtsam-mit-main-huong-und-diane")!
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/graphql", json: """
        { "data": { "programSet": { "id": "79305508", "title": "Achtsam",
          "numberOfElements": 169,
          "sharingUrl": "https://www.ardsounds.de/sendung/achtsam/urn:ard:show:7a9143c8d615db00/",
          "feedUrl": "\(officialFeed.absoluteString)" } } }
        """)
        let apple = ApplePodcastsFeedResolver(storefront: "de", searchCandidates: { _ in [] })
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel><title>Achtsam - Deutschlandfunk Nova</title><itunes:author>Deutschlandfunk Nova</itunes:author>
            <item><guid>achtsam-2026-10-14</guid><title>Aphantasie: Ohne innere Bilder leben</title></item>
          </channel>
        </rss>
        """
        let feedClient = PodcastHTTPClient(transport: PodcastFeedFixtureTransport(responses: [
            officialFeed.absoluteString: (Data(rss.utf8), "application/rss+xml")
        ]))
        let provider = ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client,
            cache: PodcastDiscoveryCache(),
            appleResolver: apple,
            feedClient: feedClient
        )
        let show = DiscoveredPodcast(
            id: "79305508",
            title: "Achtsam",
            author: "Deutschlandfunk Nova",
            webpageURL: URL(string: "https://www.ardsounds.de/sendung/achtsam/urn:ard:show:7a9143c8d615db00/"),
            providerID: "ardsounds",
            broadcasterID: "ardsounds",
            providerReference: "urn:ard:show:7a9143c8d615db00"
        )

        let resolved = try await provider.resolveFeed(for: show)

        XCTAssertEqual(resolved, officialFeed)
        XCTAssertEqual(transport.requestedURLs.map(\.path), ["/graphql"])
    }

    func testARDResolvesPublisherWebsiteRSSWithExistingHTMLDiscovery() async throws {
        let publisherHome = URL(string: "https://www.deutschlandfunknova.de/")!
        let officialFeed = URL(string: "https://www.deutschlandfunknova.de/podcast/achtsam-mit-main-huong-und-diane")!
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/graphql", json: """
        { "data": { "programSet": { "id": "79305508", "title": "Achtsam", "feedUrl": null } } }
        """)
        transport.stub("https://www.deutschlandfunknova.de/", markup: """
        <html><head><link rel="alternate" type="application/rss+xml" href="/podcast/achtsam-mit-main-huong-und-diane"></head></html>
        """)
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel><title>Achtsam - Deutschlandfunk Nova</title><itunes:author>Deutschlandfunk Nova</itunes:author>
            <item><guid>achtsam-2026-10-14</guid><title>Aphantasie: Ohne innere Bilder leben</title></item>
          </channel>
        </rss>
        """
        let feedClient = PodcastHTTPClient(transport: PodcastFeedFixtureTransport(responses: [
            officialFeed.absoluteString: (Data(rss.utf8), "application/rss+xml")
        ]))
        let apple = ApplePodcastsFeedResolver(storefront: "de", searchCandidates: { _ in [] })
        let provider = ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client,
            cache: PodcastDiscoveryCache(),
            appleResolver: apple,
            feedClient: feedClient
        )
        let show = DiscoveredPodcast(
            id: "79305508",
            title: "Achtsam",
            author: "Deutschlandfunk Nova",
            webpageURL: URL(string: "https://www.ardsounds.de/sendung/achtsam/urn:ard:show:7a9143c8d615db00/"),
            publisherWebsiteURL: publisherHome,
            providerID: "ardsounds",
            broadcasterID: "ardsounds",
            providerReference: "urn:ard:show:7a9143c8d615db00"
        )

        let resolved = try await provider.resolveFeed(for: show)

        XCTAssertEqual(resolved, officialFeed)
        XCTAssertEqual(transport.requestedURLs.map(\.host), ["api.ardaudiothek.de", "www.deutschlandfunknova.de"])
    }

    func testARDHostedRSSFallbackRequiresAValidShowURN() {
        let base = DiscoveredPodcast(
            id: "31649612",
            title: "ARD Hörspiel-Speicher",
            webpageURL: URL(string: "https://www.ardsounds.de/sendung/ard-hoerspiel-speicher/urn:ard:show:282098536a9f177e/"),
            providerID: "ardsounds",
            broadcasterID: "ardsounds"
        )
        XCTAssertEqual(
            ARDSoundsDiscoveryProvider.generatedRSSURL(for: base)?.absoluteString,
            "https://ardsounds.tisba.de/show/urn:ard:show:282098536a9f177e"
        )

        let episodeURL = URL(string: "https://www.ardsounds.de/episode/urn:ard:episode:282098536a9f177e/")
        XCTAssertNil(ARDSoundsDiscoveryProvider.generatedRSSURL(for: DiscoveredPodcast(
            id: base.id,
            title: base.title,
            webpageURL: episodeURL,
            providerID: base.providerID,
            broadcasterID: base.broadcasterID
        )))
    }

    func testHostedARDGeneratorRSSShapeUsesTheOrdinaryFeedParser() async throws {
        let endpoint = URL(string: "https://ardsounds.tisba.de/show/urn:ard:show:282098536a9f177e")!
        let rss = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel><title>ARD Hörspiel-Speicher</title>
            <item><guid>urn:ard:episode:91693773c7471595</guid>
              <title>Hyperbolische Körper</title>
              <enclosure url="https://download.example/episode.mp3" type="audio/mp3" length="" />
            </item>
          </channel>
        </rss>
        """
        let client = PodcastHTTPClient(
            resolver: PodcastAccessResolver(credentialStore: InMemoryPodcastCredentialStore()),
            transport: PodcastFeedFixtureTransport(responses: [
                endpoint.absoluteString: (Data(rss.utf8), "application/rss+xml")
            ])
        )

        let parsed = try await PodcastFeedResolver.resolveExistingEndpoint(from: endpoint, client: client)

        XCTAssertEqual(parsed.title, "ARD Hörspiel-Speicher")
        XCTAssertEqual(parsed.initialImportSeed?.episodes.first?.id, "urn:ard:episode:91693773c7471595")
        XCTAssertEqual(parsed.initialImportSeed?.episodes.first?.episodeURL.absoluteString, "https://download.example/episode.mp3")
    }

    func testAppleARDResolutionRequiresPublisherAndCompleteTitle() {
        XCTAssertTrue(ApplePodcastsFeedResolver.title("Achtsam - Deutschlandfunk Nova", preserves: "Achtsam"))
        XCTAssertFalse(ApplePodcastsFeedResolver.title("ARD Hörspiel", preserves: "ARD Hörspiel-Speicher"))
        XCTAssertTrue(ApplePodcastsFeedResolver.publisherMatches("Deutschlandfunk Nova", expected: "Deutschlandfunk Nova"))
        XCTAssertFalse(ApplePodcastsFeedResolver.publisherMatches("ARD", expected: "Deutschlandfunk Nova"))
    }

    func testARDFeedCandidatesRejectPrivateAndNonHTTPDestinations() {
        XCTAssertNotNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://feeds.example.org/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("file:///etc/passwd"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://localhost/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://127.0.0.1/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://10.0.0.8/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://192.0.2.10/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://[::1]/show.xml"))
        XCTAssertNil(ARDSoundsDiscoveryProvider.publicHTTPURL("https://feeds.example.org/show.xml?token=private"))
    }

    func testDiscoveryHTTPClientRejectsOversizedMetadataResponses() async {
        let url = URL(string: "https://feeds.example.org/large")!
        let client = PodcastDiscoveryHTTPClient(maximumResponseBytes: 8, transport: { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (Data(repeating: 65, count: 9), response)
        })

        do {
            _ = try await client.markup(from: url)
            XCTFail("Oversized discovery metadata must be rejected")
        } catch {
            XCTAssertEqual(error as? PodcastDiscoveryError, .invalidResponse)
        }
    }

    @MainActor
    func testUnavailableARDFeedLookupCanBeRetriedSuccessfully() async {
        let broadcaster = PublicBroadcaster.testBroadcaster(id: "ardsounds", name: "ARD Sounds")
        let feedURL = URL(string: "https://example.org/show.xml")!
        let provider = RetryDiscoveryProvider(
            broadcaster: broadcaster,
            attempts: RetryAttemptCounter(),
            feedURL: feedURL
        )
        let registry = PodcastDiscoveryRegistry(broadcasters: [broadcaster], providers: [provider])
        let podcast = DiscoveredPodcast(
            id: "show-id",
            title: "Test programme",
            author: "Test broadcaster",
            providerID: "ardsounds",
            broadcasterID: "ardsounds"
        )
        let resolution = DiscoveredPodcastFeedResolution(podcast: podcast, registry: registry)

        await resolution.resolveFeedIfNeeded()
        XCTAssertEqual(resolution.state, .unavailable(.unavailable))

        await resolution.retryFeedLookup()
        XCTAssertEqual(resolution.state, .resolved(feedURL))
    }

    // MARK: - Apple-catalogue-backed broadcasters

    func testPublisherRuleMatchesExactNamesAndDistinctivePrefixes() {
        XCTAssertTrue(ApplePublisherRules.bbc.matches(publisher: "BBC Radio 4"))
        XCTAssertTrue(ApplePublisherRules.bbc.matches(publisher: "BBC World Service"))
        XCTAssertFalse(ApplePublisherRules.bbc.matches(publisher: "Goalhanger"))

        XCTAssertTrue(ApplePublisherRules.npr.matches(publisher: "NPR"))
        XCTAssertFalse(ApplePublisherRules.npr.matches(publisher: "NPR Member Station"))

        // Diacritics must not decide the match.
        XCTAssertTrue(ApplePublisherRules.rte.matches(publisher: "RTÉ Documentary on One"))
        XCTAssertTrue(ApplePublisherRules.rte.matches(publisher: "RTE Radio 1"))

        XCTAssertFalse(ApplePublisherRules.abc.matches(publisher: nil))
        XCTAssertFalse(ApplePublisherRules.abc.matches(publisher: ""))
    }

    func testZDFClaimsItsOwnImprintsButNotTheJointVentureWithARD() {
        XCTAssertTrue(ApplePublisherRules.zdf.matches(publisher: "ZDF"))
        XCTAssertTrue(ApplePublisherRules.zdf.matches(publisher: "ZDF - Terra X"))
        XCTAssertTrue(ApplePublisherRules.zdf.matches(publisher: "ZDFde"))
        XCTAssertTrue(ApplePublisherRules.zdf.matches(publisher: "ZDF auslandsjournal"))

        // funk is an ARD/ZDF joint venture and already appears in ARD's own
        // catalogue; claiming it here would list it twice.
        XCTAssertFalse(ApplePublisherRules.zdf.matches(publisher: "funk - von ARD und ZDF"))
        XCTAssertFalse(ApplePublisherRules.zdf.matches(publisher: "funk – von ARD und ZDF"))
    }

    func testGermanyOffersBothARDAndZDF() {
        let registry = PodcastDiscoveryRegistry()
        let german = registry.browsableBroadcasters.filter { $0.countryCode == "DE" }

        XCTAssertEqual(Set(german.map(\.id)), ["ardsounds", "zdf"])
    }

    func testPublisherRulesRejectSimilarlyNamedForeignBroadcasters() {
        // "ABC News" is an American publisher; the Australian ABC must not claim it.
        XCTAssertFalse(ApplePublisherRules.abc.matches(publisher: "ABC News"))
        XCTAssertTrue(ApplePublisherRules.abc.matches(publisher: "ABC Australia"))

        // Regional and foreign PBS namesakes are different organizations.
        XCTAssertFalse(ApplePublisherRules.pbs.matches(publisher: "Thai PBS Podcast"))
        XCTAssertFalse(ApplePublisherRules.pbs.matches(publisher: "Iowa PBS"))
        XCTAssertTrue(ApplePublisherRules.pbs.matches(publisher: "PBS News"))
    }

    func testApplePublisherMappingFiltersDeduplicatesAndSorts() {
        let rule = ApplePublisherRule(
            storefront: "gb",
            queries: ["BBC"],
            publisherPrefixes: ["BBC"]
        )

        func feed(_ title: String, _ artist: String, _ url: String) -> PodcastFeed {
            let feed = PodcastFeed(url: URL(string: url)!, title: title, fetchMetadataIfNeeded: false)
            feed.artist = artist
            return feed
        }

        let podcasts = ApplePublisherDiscoveryProvider.podcasts(
            from: [
                feed("Zeitgeist", "BBC Radio 4", "https://example.org/z.xml"),
                feed("Analysis", "BBC Radio 4", "https://example.org/a.xml"),
                // Same feed reached through a second query.
                feed("Analysis", "BBC Radio 4", "http://Example.org/a.xml/"),
                // Not this broadcaster.
                feed("Something Else", "Acme Media", "https://example.org/s.xml")
            ],
            rule: rule,
            providerID: "bbc",
            broadcasterID: "bbc"
        )

        XCTAssertEqual(podcasts.map(\.title), ["Analysis", "Zeitgeist"])
        XCTAssertTrue(podcasts.allSatisfy { $0.feedURL != nil }, "Every result must be subscribable")
        XCTAssertTrue(podcasts.allSatisfy { $0.broadcasterID == "bbc" })
    }

    func testAppleBackedProvidersDiscloseTheirSource() {
        let registry = PodcastDiscoveryRegistry()

        for broadcasterID in ["bbc", "npr", "sverigesradio", "rte", "npo", "abc", "pbs", "vrt", "zdf"] {
            let provider = registry.provider(for: broadcasterID)
            XCTAssertNotNil(provider, "\(broadcasterID) should be browsable")
            XCTAssertNotNil(
                provider?.attribution,
                "\(broadcasterID) draws on someone else's catalogue and must say so"
            )
            XCTAssertEqual(provider?.capabilities.browseModes, [.publisherCatalog, .search])
        }

        // Providers reading a broadcaster's own source make no such claim.
        XCTAssertNil(registry.provider(for: "orf")?.attribution)
        XCTAssertNil(registry.provider(for: "cbc")?.attribution)
    }

    func testEveryBrowsableBroadcasterCanProduceFeeds() {
        let registry = PodcastDiscoveryRegistry()

        XCTAssertFalse(registry.browsableBroadcasters.isEmpty)
        for broadcaster in registry.browsableBroadcasters {
            let provider = try? XCTUnwrap(registry.provider(for: broadcaster.id))
            XCTAssertEqual(
                provider?.capabilities.contains(.feedURL),
                true,
                "\(broadcaster.id) would list shows that cannot be subscribed to"
            )
        }
    }
}
