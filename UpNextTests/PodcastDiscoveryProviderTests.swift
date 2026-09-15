import Foundation
import XCTest
@testable import UpNext

/// Provider behaviour against stubbed networking: decoding, catalogue building,
/// feed resolution and failure handling. No broadcaster is contacted.
final class PodcastDiscoveryProviderTests: XCTestCase {

    // MARK: - SRG SSR

    private let srgShowList = """
    {
      "next": null,
      "showList": [
        {
          "id": "aaa",
          "urn": "urn:srf:show:radio:aaa",
          "title": "100 Sekunden Wissen",
          "lead": "Das Hörlexikon.",
          "description": "Die hochdosierte Ration Wissen für den Tag.",
          "imageUrl": "https://example.org/a.jpg",
          "podcastImageUrl": "https://example.org/a-podcast.jpg",
          "podcastFeedSdUrl": "https://www.srf.ch/feed/podcast/sd/aaa.xml",
          "numberOfEpisodes": 5121,
          "topicList": [{ "id": "t1", "title": "Wissen" }]
        },
        {
          "id": "bbb",
          "title": "Einfach Politik",
          "lead": "Politik erklärt.",
          "podcastFeedSdUrl": "https://www.srf.ch/feed/podcast/sd/bbb.xml",
          "topicList": [
            { "id": "t1", "title": "Wissen" },
            { "id": "t2", "title": "Gesellschaft" }
          ]
        },
        {
          "id": "ccc",
          "title": "Not A Podcast",
          "lead": "A radio show that is not published as a podcast.",
          "topicList": [{ "id": "t1", "title": "Wissen" }]
        }
      ]
    }
    """

    private func srgProvider(_ transport: StubTransport) -> SRGSSRDiscoveryProvider {
        SRGSSRDiscoveryProvider(
            businessUnit: .srf,
            broadcaster: PublicBroadcasterCatalog.srf,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )
    }

    func testSRGCatalogueDecodesShowsAndDerivesCategories() async throws {
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/srf/showList", json: srgShowList)

        let provider = srgProvider(transport)
        let podcasts = try await provider.allPodcasts(refresh: false)

        // The show without any feed is left out rather than listed as a dead end.
        XCTAssertEqual(podcasts.map(\.title), ["100 Sekunden Wissen", "Einfach Politik"])

        let first = try XCTUnwrap(podcasts.first)
        XCTAssertEqual(first.feedURL?.absoluteString, "https://www.srf.ch/feed/podcast/sd/aaa.xml")
        XCTAssertEqual(first.artworkURL?.absoluteString, "https://example.org/a-podcast.jpg")
        XCTAssertEqual(first.summary, "Die hochdosierte Ration Wissen für den Tag.")
        XCTAssertEqual(first.language, "de")
        XCTAssertEqual(first.episodeCount, 5121)
        XCTAssertEqual(first.broadcasterID, "srf")

        // Topics become categories, ordered and counted.
        let categories = try await provider.categories(refresh: false)
        XCTAssertEqual(categories.map(\.title), ["Gesellschaft", "Wissen"])
        XCTAssertEqual(categories.first { $0.id == "t1" }?.podcastCount, 2)

        let wissen = try XCTUnwrap(categories.first { $0.id == "t1" })
        let inCategory = try await provider.podcasts(in: wissen, refresh: false)
        XCTAssertEqual(inCategory.count, 2)

        let gesellschaft = try XCTUnwrap(categories.first { $0.id == "t2" })
        let inGesellschaft = try await provider.podcasts(in: gesellschaft, refresh: false)
        XCTAssertEqual(inGesellschaft.map(\.title), ["Einfach Politik"])
    }

    func testSRGCatalogueIsCachedBetweenCalls() async throws {
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/srf/showList", json: srgShowList)

        let provider = srgProvider(transport)
        _ = try await provider.allPodcasts(refresh: false)
        _ = try await provider.categories(refresh: false)
        _ = try await provider.allPodcasts(refresh: false)

        XCTAssertEqual(transport.requestedURLs.count, 1, "Navigation must not refetch the catalogue")
    }

    func testSRGSearchResultWithoutAFeedIsResolvedThroughTheShowEndpoint() async throws {
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/srf/searchResultShowList", json: """
        { "searchResultShowList": [ { "id": "bbb", "title": "Einfach Politik", "lead": "Politik erklärt." } ] }
        """)
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/srf/show/radio/bbb", json: """
        { "id": "bbb", "title": "Einfach Politik", "podcastFeedSdUrl": "https://www.srf.ch/feed/podcast/sd/bbb.xml" }
        """)

        let provider = srgProvider(transport)
        let results = try await provider.search("politik")

        let show = try XCTUnwrap(results.first)
        XCTAssertNil(show.feedURL, "Search results carry no feed")

        let resolved = try await provider.resolveFeed(for: show)
        XCTAssertEqual(resolved.absoluteString, "https://www.srf.ch/feed/podcast/sd/bbb.xml")
    }

    func testSRGShowWithoutAFeedReportsFeedNotFound() async throws {
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/srf/show/radio/ccc", json: """
        { "id": "ccc", "title": "No feed here" }
        """)

        let provider = srgProvider(transport)
        let podcast = DiscoveredPodcast(
            id: "ccc",
            title: "No feed here",
            providerID: "srf",
            broadcasterID: "srf",
            providerReference: "ccc"
        )

        await assertThrows(.feedNotFound) { _ = try await provider.resolveFeed(for: podcast) }
    }

    func testSRGServerErrorSurfacesAsUnavailable() async {
        let transport = StubTransport()
        transport.stub(
            "https://il.srgssr.ch",
            response: .init(data: Data("{}".utf8), statusCode: 503, contentType: "application/json")
        )

        let provider = srgProvider(transport)
        await assertThrows(.unavailable) { _ = try await provider.allPodcasts(refresh: false) }
    }

    func testSRGHTMLErrorPageIsRejectedInsteadOfDecoded() async {
        let transport = StubTransport()
        transport.stub(
            "https://il.srgssr.ch",
            response: .init(data: Data("<html>error</html>".utf8), contentType: "text/html")
        )

        let provider = srgProvider(transport)
        await assertThrows(.invalidResponse) { _ = try await provider.allPodcasts(refresh: false) }
    }


    func testSRGShowPublishedOnlyAsAPageIsResolvedThroughThatPage() async throws {
        // RTS advertises its feeds on a show page instead of in the API.
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/rts/showList", json: """
        { "showList": [ {
            "id": "ddd",
            "title": "120 secondes",
            "lead": "Avec un invité.",
            "podcastSubscriptionUrl": "https://www.rts.ch/audio/podcast/120-secondes.html"
        } ] }
        """)
        transport.stub("https://www.rts.ch/audio/podcast/120-secondes.html", markup: """
        <html><head>
        <link rel="alternate" type="application/rss+xml" href="/la-1ere/programmes/120-secondes/podcast/?flux=rss/podcast">
        </head></html>
        """)

        let provider = SRGSSRDiscoveryProvider(
            businessUnit: .rts,
            broadcaster: PublicBroadcasterCatalog.rts,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        let podcasts = try await provider.allPodcasts(refresh: false)
        let show = try XCTUnwrap(podcasts.first)

        XCTAssertEqual(show.language, "fr")
        XCTAssertNil(show.feedURL)
        XCTAssertEqual(show.webpageURL?.absoluteString, "https://www.rts.ch/audio/podcast/120-secondes.html")

        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/rts/show/radio/ddd", json: """
        { "id": "ddd", "title": "120 secondes",
          "podcastSubscriptionUrl": "https://www.rts.ch/audio/podcast/120-secondes.html" }
        """)

        let feed = try await provider.resolveFeed(for: show)
        XCTAssertEqual(
            feed.absoluteString,
            "https://www.rts.ch/la-1ere/programmes/120-secondes/podcast/?flux=rss/podcast"
        )
    }

    func testSRGShowPageWithoutAFeedLinkReportsFeedNotFound() async throws {
        let transport = StubTransport()
        transport.stub("https://il.srgssr.ch/integrationlayer/2.0/rts/show/radio/eee", json: """
        { "id": "eee", "title": "Gone", "podcastSubscriptionUrl": "https://www.rts.ch/audio/podcast/gone.html" }
        """)
        transport.stub("https://www.rts.ch/audio/podcast/gone.html", markup: "<html><head></head></html>")

        let provider = SRGSSRDiscoveryProvider(
            businessUnit: .rts,
            broadcaster: PublicBroadcasterCatalog.rts,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        let podcast = DiscoveredPodcast(
            id: "eee",
            title: "Gone",
            providerID: "rts",
            broadcasterID: "rts",
            providerReference: "eee"
        )

        await assertThrows(.feedNotFound) { _ = try await provider.resolveFeed(for: podcast) }
    }

    // MARK: - ORF

    private let orfCatalog = """
    {
      "payload": {
        "oe1": [
          {
            "id": 1,
            "station": "oe1",
            "slug": "oe1-journale",
            "isOnline": true,
            "urls": { "feed": "https://podcast.orf.at/podcast/oe1/oe1_journale/oe1_journale.xml" },
            "title": "Ö1 Journale",
            "link": { "url": "https://sound.orf.at/podcast/oe1/oe1-journale" },
            "description": "Die Nachrichten.",
            "language": "de",
            "author": "ORF Ö1",
            "image": { "versions": { "standard": { "path": "https://podcast.orf.at/cover.jpg" } } },
            "episodeCount": 42
          },
          {
            "id": 2,
            "station": "oe1",
            "isOnline": false,
            "title": "Retired Show",
            "urls": { "feed": "https://podcast.orf.at/retired.xml" }
          }
        ],
        "fm4": [
          {
            "id": 3,
            "station": "fm4",
            "isOnline": true,
            "title": "FM4 Interview Podcast",
            "urls": { "feed": "https://podcast.orf.at/fm4.xml" }
          }
        ]
      }
    }
    """

    private func orfProvider(_ transport: StubTransport) -> ORFDiscoveryProvider {
        ORFDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.orf,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )
    }

    func testORFCatalogueDecodesAndSkipsOfflineShows() async throws {
        let transport = StubTransport()
        transport.stub("https://audioapi.orf.at", json: orfCatalog)

        let provider = orfProvider(transport)
        let podcasts = try await provider.allPodcasts(refresh: false)

        XCTAssertEqual(podcasts.map(\.title), ["FM4 Interview Podcast", "Ö1 Journale"])

        let journale = try XCTUnwrap(podcasts.first { $0.id == "1" })
        XCTAssertEqual(
            journale.feedURL?.absoluteString,
            "https://podcast.orf.at/podcast/oe1/oe1_journale/oe1_journale.xml"
        )
        XCTAssertEqual(journale.artworkURL?.absoluteString, "https://podcast.orf.at/cover.jpg")
        XCTAssertEqual(journale.author, "ORF Ö1")
        XCTAssertEqual(journale.language, "de")
        XCTAssertEqual(journale.episodeCount, 42)
    }

    func testORFStationsBecomeCategoriesWithDisplayNames() async throws {
        let transport = StubTransport()
        transport.stub("https://audioapi.orf.at", json: orfCatalog)

        let categories = try await orfProvider(transport).categories(refresh: false)

        XCTAssertEqual(categories.map(\.title), ["FM4", "Ö1"])
        XCTAssertEqual(categories.first { $0.id == "oe1" }?.podcastCount, 1)
        XCTAssertEqual(ORFStation.displayName(for: "unknown-station"), "UNKNOWN-STATION")
    }

    func testORFSearchesItsCachedCatalogue() async throws {
        let transport = StubTransport()
        transport.stub("https://audioapi.orf.at", json: orfCatalog)

        let provider = orfProvider(transport)
        let results = try await provider.search("journale")

        XCTAssertEqual(results.map(\.title), ["Ö1 Journale"])
        let blank = try await provider.search("   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testORFDirectFeedNeedsNoResolutionStep() async throws {
        let transport = StubTransport()
        transport.stub("https://audioapi.orf.at", json: orfCatalog)

        let provider = orfProvider(transport)
        let all = try await provider.allPodcasts(refresh: false)
        let podcast = try XCTUnwrap(all.first { $0.id == "1" })
        let requestsBefore = transport.requestedURLs.count

        let feed = try await provider.resolveFeed(for: podcast)

        XCTAssertEqual(feed, podcast.feedURL)
        XCTAssertEqual(transport.requestedURLs.count, requestsBefore, "A known feed must not be looked up again")
    }

    // MARK: - RNZ

    func testRNZResolvesAFeedFromTheShowPageWhenTheCatalogueHasNone() async throws {
        let transport = StubTransport()
        transport.stub("https://www.rnz.co.nz/podcast/mediawatch", markup: #"""
        <html><body><script>{"acast_url":"https://www.rnz.co.nz/podcasts/acast/mediawatch.rss"}</script></body></html>
        """#)

        let provider = RNZDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.rnz,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        let podcast = DiscoveredPodcast(
            id: "mediawatch",
            title: "Mediawatch",
            providerID: "rnz",
            broadcasterID: "rnz",
            providerReference: "mediawatch"
        )

        let feed = try await provider.resolveFeed(for: podcast)
        XCTAssertEqual(feed.absoluteString, "https://www.rnz.co.nz/podcasts/acast/mediawatch.rss")
    }

    func testRNZReportsFeedNotFoundWhenTheShowPageHasNone() async {
        let transport = StubTransport()
        transport.stub("https://www.rnz.co.nz/podcast/", markup: "<html><body>nothing</body></html>")

        let provider = RNZDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.rnz,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        let podcast = DiscoveredPodcast(
            id: "gone",
            title: "Gone",
            providerID: "rnz",
            broadcasterID: "rnz",
            providerReference: "gone"
        )

        await assertThrows(.feedNotFound) { _ = try await provider.resolveFeed(for: podcast) }
    }

    func testProviderWithoutAReferenceCannotResolveAFeed() async {
        let provider = RNZDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.rnz,
            client: StubTransport().client,
            cache: PodcastDiscoveryCache()
        )

        let podcast = DiscoveredPodcast(id: "x", title: "X", providerID: "rnz", broadcasterID: "rnz")
        await assertThrows(.feedNotFound) { _ = try await provider.resolveFeed(for: podcast) }
    }

    func testRNZEmptyDirectoryIsTreatedAsAParsingFailure() async {
        let transport = StubTransport()
        transport.stub("https://www.rnz.co.nz/podcasts", markup: "<html><body>redesigned</body></html>")

        let provider = RNZDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.rnz,
            client: transport.client,
            cache: PodcastDiscoveryCache()
        )

        await assertThrows(.parsingFailed) { _ = try await provider.allPodcasts(refresh: false) }
    }

    // MARK: - ARD

    func testARDSearchDecodesProgramSetsIntoGenericModels() async throws {
        let transport = StubTransport()
        transport.stub("https://api.ardaudiothek.de/search/programsets", json: """
        { "data": { "search": { "programSets": { "numberOfElements": 1, "nodes": [
          {
            "id": "95584586",
            "title": "Der KI-Podcast",
            "synopsis": "Über künstliche Intelligenz.",
            "numberOfElements": 120,
            "sharingUrl": "https://www.ardsounds.de/sendung/der-ki-podcast/urn:ard:show:1/",
            "image": { "url1X1": "https://img.example/1x1?w={width}" },
            "publicationService": { "title": "ARD", "organizationName": "BR" }
          }
        ] } } } }
        """)

        let provider = ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client
        )

        let results = try await provider.search("ki")
        let show = try XCTUnwrap(results.first)

        XCTAssertEqual(show.title, "Der KI-Podcast")
        XCTAssertEqual(show.author, "ARD")
        XCTAssertEqual(show.summary, "Über künstliche Intelligenz.")
        XCTAssertEqual(show.language, "de")
        XCTAssertEqual(show.episodeCount, 120)
        // The templated width placeholder has to be filled in.
        XCTAssertEqual(show.artworkURL?.absoluteString, "https://img.example/1x1?w=448")
        XCTAssertNil(show.feedURL, "ARD exposes no RSS of its own")
        XCTAssertEqual(show.webpageURL?.host(), "www.ardsounds.de")
    }

    func testARDFailureIsContainedAndReportedAsUnavailable() async {
        let transport = StubTransport()
        transport.stub(
            "https://api.ardaudiothek.de",
            response: .init(data: Data(), statusCode: 500, contentType: "application/json")
        )

        let provider = ARDSoundsDiscoveryProvider(
            broadcaster: PublicBroadcasterCatalog.ardSounds,
            client: transport.client
        )

        await assertThrows(.unavailable) { _ = try await provider.search("politik") }
    }

    // MARK: - Errors shown to people

    func testUserFacingErrorsRevealNoEndpointDetail() throws {
        for error in [
            PodcastDiscoveryError.unavailable,
            .invalidResponse,
            .parsingFailed,
            .feedNotFound,
            .configurationMissing,
            .unsupportedOperation
        ] {
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(description.isEmpty)
            for leak in ["http", "://", "json", "html", "api", "500", "parse"] {
                XCTAssertFalse(
                    description.lowercased().contains(leak),
                    "\(error) leaks \"\(leak)\" to the user: \(description)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: PodcastDiscoveryError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PodcastDiscoveryError, expected, file: file, line: line)
        }
    }
}
