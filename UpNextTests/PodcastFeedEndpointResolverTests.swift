import Foundation
import XCTest
@testable import UpNext

final class PodcastFeedEndpointResolverTests: XCTestCase {
    private final class RequestedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            values.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private struct HTMLThenFeedTransport: PodcastHTTPTransport {
        let requestedURLs: RequestedURLs

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requestedURLs.append(url)
            if url.path == "/show" {
                let html = "<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/show/feed.xml\"></head></html>"
                return (
                    Data(html.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
                )
            }
            let xml = "<rss><channel><title>Recovered show</title><item><guid>episode-1</guid><title>One</title></item></channel></rss>"
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    private struct SingleFeedTransport: PodcastHTTPTransport {
        let requestedURLs: RequestedURLs

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requestedURLs.append(url)
            let xml = "<rss><channel><title>Fixture</title><item><guid>episode-1</guid><title>One</title><enclosure url=\"https://example.com/one.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    private struct LongFeedTransport: PodcastHTTPTransport {
        let requestedURLs: RequestedURLs

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requestedURLs.append(url)
            let items = (1...561).reversed().map { number in
                "<item><guid>lnp-\(number)</guid><title>LNP\(number)</title>"
                    + "<enclosure url=\"https://example.com/lnp\(number).mp3\" type=\"audio/mpeg\" /></item>"
            }.joined()
            let xml = """
            <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
              <title>Logbuch:Netzpolitik</title>
              <atom:link rel="next" href="page2.xml" />
              \(items)
            </channel></rss>
            """
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    private struct StatusTransport: PodcastHTTPTransport {
        let statusCode: Int

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            let headers = statusCode == 429 ? ["Retry-After": "60"] : [:]
            return (
                Data(),
                HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
            )
        }
    }

    func testTransientFailureRetainsStoredEndpointForRetry() async throws {
        let storedURL = URL(string: "https://example.com/feed/mp3")!
        for statusCode in [401, 403, 429, 503] {
            let client = PodcastHTTPClient(transport: StatusTransport(statusCode: statusCode))
            do {
                _ = try await PodcastFeedResolver.resolveExistingEndpoint(from: storedURL, client: client)
                XCTFail("HTTP \(statusCode) must fail")
            } catch let error as PodcastFeedResolverError {
                guard case .httpStatus(let failedURL, let actualCode, let retryAfter) = error else {
                    return XCTFail("Unexpected resolver error: \(error)")
                }
                XCTAssertEqual(failedURL, storedURL)
                XCTAssertEqual(actualCode, statusCode)
                if statusCode == 429 { XCTAssertNotNil(retryAfter) }
                XCTAssertEqual(
                    PodcastEpisodeImportRetryQueue.disposition(for: error),
                    statusCode == 401 || statusCode == 403 ? .authentication : .retryable
                )
            }
        }
        XCTAssertEqual(PodcastEpisodeImportRetryQueue.disposition(for: URLError(.timedOut)), .retryable)
    }

    func testStoredFeedDoesNotFollowHTMLAdvertisedRSS() async throws {
        let requestedURLs = RequestedURLs()
        let client = PodcastHTTPClient(transport: HTMLThenFeedTransport(requestedURLs: requestedURLs))
        let storedURL = URL(string: "https://example.com/show")!

        do {
            _ = try await PodcastFeedResolver.resolveExistingEndpoint(
                from: storedURL,
                allowHTMLDiscovery: false,
                client: client
            )
            XCTFail("Stored feeds must not switch to an advertised website RSS feed")
        } catch PodcastFeedResolverError.notAPodcastFeed {
            XCTAssertEqual(requestedURLs.snapshot(), [storedURL])
        }
    }

    func testGeneralWebsiteRSSCannotReplacePodcastMP3Feed() async throws {
        let websiteFeedURL = URL(string: "https://example.com/feed")!
        let xml = """
        <rss><channel><title>Website posts</title>
          <item><guid>lnp-560</guid><title>A post</title>
            <link>https://example.com/posts/1</link></item>
        </channel></rss>
        """
        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(data: Data(xml.utf8), sourceURL: websiteFeedURL)
        )
        XCTAssertTrue(page.episodes.isEmpty)
        var known = KnownPodcastEpisodeIdentifiers()
        known.guids.insert("lnp-560")
        known.urls.insert("https://media.example.com/lnp560.mp3")

        let incrementalPage = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(data: Data(xml.utf8), sourceURL: websiteFeedURL),
            knownEpisodeIdentifiers: known
        )
        XCTAssertFalse(incrementalPage.didStopAtKnownEpisode)

        XCTAssertFalse(
            PodcastFeedEndpointIdentity.matchesExistingPodcast(
                page.parsedFeed,
                knownEpisodeIdentifiers: known
            )
        )
        XCTAssertTrue(
            PodcastFeedEndpointIdentity.matchesExistingPodcast(
                ["episodes": [[
                    "guid": "lnp-560",
                    "title": "Episode 560",
                    "enclosure": [["url": "https://media.example.com/lnp560.mp3", "type": "audio/mpeg"]]
                ]]],
                knownEpisodeIdentifiers: known
            )
        )
    }

    func testExistingEndpointResolvesAdvertisedFeedBeforeXMLParsing() async throws {
        let requestedURLs = RequestedURLs()
        let client = PodcastHTTPClient(transport: HTMLThenFeedTransport(requestedURLs: requestedURLs))
        let pageURL = URL(string: "https://example.com/show")!

        let feed = try await PodcastFeedResolver.resolveExistingEndpoint(from: pageURL, client: client)

        XCTAssertEqual(feed.url, URL(string: "https://example.com/show/feed.xml"))
        XCTAssertEqual(feed.title, "Recovered show")
        XCTAssertEqual(
            requestedURLs.snapshot(),
            [pageURL, URL(string: "https://example.com/show/feed.xml")!]
        )
    }

    func testFeedSelfLinkDoesNotReplaceFetchedEndpoint() async throws {
        let fetchedURL = URL(string: "https://example.com/original.xml")!
        let xml = """
        <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
          <title>Fixture</title>
          <atom:link rel="self" href="https://example.com/not-a-feed" />
        </channel></rss>
        """

        let document = PodcastFeedDocument(data: Data(xml.utf8), sourceURL: fetchedURL)
        let feed = try await PodcastParser.parsePage(from: document).feed

        XCTAssertEqual(feed.url, fetchedURL)
    }

    func testValidatedFirstPageIsReusedByInitialImport() async throws {
        let requestedURLs = RequestedURLs()
        let client = PodcastHTTPClient(transport: SingleFeedTransport(requestedURLs: requestedURLs))
        let feedURL = URL(string: "https://example.com/feed.xml")!

        let feed = try await PodcastFeedResolver.resolveExistingEndpoint(from: feedURL, client: client)
        let seed = try XCTUnwrap(feed.initialImportSeed)
        let imported = try await PodcastParser.fetchAllPages(
            from: feedURL,
            firstPage: seed,
            client: client
        )

        XCTAssertEqual(requestedURLs.snapshot(), [feedURL])
        XCTAssertEqual((imported["episodes"] as? [[String: Any]])?.count, 1)
    }

    func testAutomaticRefreshStopsParsingAtFirstKnownPlayableEpisode() async throws {
        let requestedURLs = RequestedURLs()
        let client = PodcastHTTPClient(transport: LongFeedTransport(requestedURLs: requestedURLs))
        let storedURL = URL(string: "https://example.com/feed/mp3")!
        var known = KnownPodcastEpisodeIdentifiers()
        known.guids = Set((1...560).map { "lnp-\($0)" })

        let feed = try await PodcastFeedResolver.resolveExistingEndpoint(
            from: storedURL,
            allowHTMLDiscovery: false,
            knownEpisodeIdentifiers: known,
            client: client
        )
        let seed = try XCTUnwrap(feed.initialImportSeed)
        XCTAssertTrue(seed.didStopAtKnownEpisode)
        XCTAssertFalse(seed.shouldCommitBeforeContinuation)
        XCTAssertEqual(seed.episodes.map(\.guid), ["lnp-561"])

        let imported = try await PodcastParser.fetchAllPages(
            from: storedURL,
            knownEpisodeIdentifiers: known,
            firstPage: seed,
            client: client
        )
        XCTAssertEqual(requestedURLs.snapshot(), [storedURL])
        XCTAssertEqual(
            (imported["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String },
            ["lnp-561"]
        )
        XCTAssertEqual(imported["didStopAtKnownEpisode"] as? Bool, true)
    }
}
