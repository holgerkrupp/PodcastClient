import Foundation
import XCTest
@testable import UpNext

final class PodcastParserPaginationTests: XCTestCase {
    func testValidatedRefreshSeedOnlyImportsEpisodesBeforeFirstKnownEpisode() {
        let feed: [String: Any] = [
            "title": "Logbuch:Netzpolitik",
            "episodes": [
                ["guid": "LNP561", "title": "LNP561"],
                ["guid": "LNP560", "title": "LNP560"],
                ["guid": "LNP559", "title": "LNP559"]
            ] as [[String: Any]]
        ]
        let known = KnownPodcastEpisodeIdentifiers(guids: ["LNP560", "LNP559"])

        let refreshFeed = known.stoppingAtFirstKnownEpisode(in: feed)

        XCTAssertEqual(refreshFeed["title"] as? String, "Logbuch:Netzpolitik")
        XCTAssertEqual(
            (refreshFeed["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String },
            ["LNP561"]
        )
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    private struct PagedFeedTransport: PodcastHTTPTransport {
        let requests: Requests
        var failAtPage: Int? = nil

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requests.append(url)
            let page = Int(url.lastPathComponent
                .replacingOccurrences(of: "page", with: "")
                .replacingOccurrences(of: ".xml", with: "")) ?? 1
            if failAtPage == page {
                throw URLError(.timedOut)
            }
            let nextLink = page < 3
                ? "<atom:link rel=\"next\" href=\"page\(page + 1).xml\" />"
                : ""
            let xml = """
            <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
              <title>Fixture</title>
              \(nextLink)
              <item><guid>episode-\(page)</guid><title>Episode \(page)</title>
                <enclosure url="https://example.com/episode-\(page).mp3" type="audio/mpeg" />
              </item>
            </channel></rss>
            """
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    private struct SinglePageFeedTransport: PodcastHTTPTransport {
        let requests: Requests

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requests.append(url)
            let xml = """
            <rss><channel><title>Single page</title>
              <item><guid>episode-1</guid><title>Episode 1</title>
                <enclosure url="https://example.com/episode-1.mp3" type="audio/mpeg" />
              </item>
            </channel></rss>
            """
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    func testValidatedCompleteSinglePageSeedIsReusedAndNotCommittedTwiceEarly() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: SinglePageFeedTransport(requests: requests))
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let validatedPage = try await PodcastParser.fetchPage(from: feedURL, client: client)
        let seed = PodcastFeedImportSeed(page: validatedPage, sourceURL: feedURL)

        XCTAssertFalse(seed.shouldCommitBeforeContinuation)

        let result = try await PodcastParser.fetchAllPages(
            from: feedURL,
            firstPage: seed,
            client: client
        )

        XCTAssertEqual(requests.snapshot(), [feedURL])
        XCTAssertEqual((result["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String }, ["episode-1"])
        XCTAssertNil(result["isPartial"])
    }

    func testPageLimitReturnsCheckpointInsteadOfFollowingMorePages() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: PagedFeedTransport(requests: requests))
        let firstPage = URL(string: "https://example.com/page1.xml")!

        let result = try await PodcastParser.fetchAllPages(
            from: firstPage,
            maximumPages: 2,
            client: client
        )

        XCTAssertEqual(requests.snapshot(), [
            firstPage,
            URL(string: "https://example.com/page2.xml")!
        ])
        XCTAssertEqual((result["episodes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(result["isPartial"] as? Bool, true)
        XCTAssertEqual(result["resumeURL"] as? String, "https://example.com/page3.xml")
    }

    func testNormalCompletionFetchesEachRFC5005PageOnce() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: PagedFeedTransport(requests: requests))
        let firstPage = URL(string: "https://example.com/page1.xml")!

        let result = try await PodcastParser.fetchAllPages(from: firstPage, client: client)

        XCTAssertEqual(requests.snapshot(), [
            firstPage,
            URL(string: "https://example.com/page2.xml")!,
            URL(string: "https://example.com/page3.xml")!
        ])
        XCTAssertEqual((result["episodes"] as? [[String: Any]])?.count, 3)
        XCTAssertNil(result["isPartial"])
    }

    func testLaterPageFailureKeepsEarlierEpisodesAndCheckpointsFailedPage() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: PagedFeedTransport(requests: requests, failAtPage: 2))
        let firstPage = URL(string: "https://example.com/page1.xml")!

        let result = try await PodcastParser.fetchAllPages(from: firstPage, client: client)

        XCTAssertEqual(requests.snapshot(), [
            firstPage,
            URL(string: "https://example.com/page2.xml")!
        ])
        XCTAssertEqual((result["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String }, ["episode-1"])
        XCTAssertEqual(result["isPartial"] as? Bool, true)
        XCTAssertEqual(result["resumeURL"] as? String, "https://example.com/page2.xml")
    }
}
