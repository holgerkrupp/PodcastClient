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

    private actor RequestGate {
        private var hasReached = false
        private var continuation: CheckedContinuation<Void, Never>?

        func reach() {
            hasReached = true
            continuation?.resume()
            continuation = nil
        }

        func waitUntilReached() async {
            guard hasReached == false else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    private actor CancellationResult {
        private(set) var wasCancelled = false

        func markCancelled() {
            wasCancelled = true
        }
    }

    private actor PreparationProbe {
        private(set) var active = 0
        private(set) var maximum = 0

        func enter() {
            active += 1
            maximum = max(maximum, active)
        }

        func leave() { active -= 1 }
    }

    private struct DelayedPreparationTransport: PodcastHTTPTransport {
        let probe: PreparationProbe

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            await probe.enter()
            try await Task.sleep(for: .milliseconds(100))
            await probe.leave()
            let xml = """
            <rss><channel><title>Concurrent preparation</title>
              <item><guid>\(url.host ?? "feed")</guid><title>Episode</title>
                <enclosure url="https://media.example.invalid/episode.mp3" type="audio/mpeg" />
              </item>
            </channel></rss>
            """
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
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

    private struct QueryPagedFeedTransport: PodcastHTTPTransport {
        let requests: Requests

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(request.url)
            requests.append(url)
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
            let link = page == "1" ? "<atom:link rel=\"next\" href=\"?page=2\" />" : ""
            let xml = """
            <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
              <title>Query pages</title>\(link)
              <item><guid>query-\(page)</guid><title>Episode \(page)</title>
                <enclosure url="https://example.com/query-\(page).mp3" type="audio/mpeg" />
              </item>
            </channel></rss>
            """
            return (
                Data(xml.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml"])!
            )
        }
    }

    private struct CancellablePagedFeedTransport: PodcastHTTPTransport {
        let requests: Requests
        let pageTwoGate: RequestGate

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
            if page == 2 {
                await pageTwoGate.reach()
                try await Task.sleep(for: .seconds(30))
            }
            let nextLink = page == 1
                ? "<atom:link rel=\"next\" href=\"page2.xml\" />"
                : ""
            let xml = """
            <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
              <title>Fixture</title>\(nextLink)
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

        let preparedSeed = try PreparedPodcastFeedSeed(seed)
        let preparedResult = try await PodcastParser.prepareAllPages(
            from: feedURL,
            firstPage: preparedSeed,
            client: client
        )
        XCTAssertEqual(requests.snapshot(), [feedURL])
        let preparedImport = try preparedResult.importDictionary
        XCTAssertEqual(
            (preparedImport["episodes"] as? [[String: Any]])?.first?["guid"] as? String,
            "episode-1"
        )
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

    func testFourValueOnlyNetworkPreparationsOverlap() async throws {
        let probe = PreparationProbe()
        let client = PodcastHTTPClient(transport: DelayedPreparationTransport(probe: probe))
        let outcomes = try await withThrowingTaskGroup(
            of: PodcastRefreshNetworkPreparer.Outcome.self,
            returning: [PodcastRefreshNetworkPreparer.Outcome].self
        ) { group in
            for index in 0..<4 {
                group.addTask {
                    try await PodcastRefreshNetworkPreparer.preparePages(
                        from: URL(string: "https://feed\(index).example.invalid/rss")!,
                        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers(),
                        profile: nil,
                        firstPage: nil,
                        startingAt: nil,
                        client: client
                    )
                }
            }
            var results: [PodcastRefreshNetworkPreparer.Outcome] = []
            for try await outcome in group { results.append(outcome) }
            return results
        }

        XCTAssertEqual(outcomes.count, 4)
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 4)
        XCTAssertTrue(outcomes.allSatisfy { $0.isPartial == false })
    }

    func testQueryPaginationKeepsDistinctPageIdentityAndSourceQuery() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: QueryPagedFeedTransport(requests: requests))
        let firstPage = URL(string: "https://example.com/feed.xml?run=fixture")!

        let outcome = try await PodcastRefreshNetworkPreparer.preparePages(
            from: firstPage,
            knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers(),
            profile: nil,
            firstPage: nil,
            startingAt: nil,
            client: client
        )
        let result = try outcome.feed.importDictionary

        XCTAssertEqual(requests.snapshot().count, 2)
        XCTAssertFalse(outcome.isPartial)
        XCTAssertEqual(
            (result["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String },
            ["query-1", "query-2"]
        )
        XCTAssertNil(result["isPartial"])
        let next = try XCTUnwrap(requests.snapshot().last)
        XCTAssertEqual(URLComponents(url: next, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "run" })?.value, "fixture")
    }

    func testPreparedPagedSeedFetchesOnlyContinuationPages() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: PagedFeedTransport(requests: requests))
        let firstPage = URL(string: "https://example.com/page1.xml")!
        let validatedPage = try await PodcastParser.fetchPage(from: firstPage, client: client)
        let seed = try PreparedPodcastFeedSeed(
            PodcastFeedImportSeed(page: validatedPage, sourceURL: firstPage)
        )

        XCTAssertTrue(seed.shouldCommitBeforeContinuation)
        let prepared = try await PodcastParser.prepareAllPages(
            from: firstPage,
            firstPage: seed,
            client: client
        )
        let result = try prepared.importDictionary

        XCTAssertEqual(requests.snapshot(), [
            firstPage,
            URL(string: "https://example.com/page2.xml")!,
            URL(string: "https://example.com/page3.xml")!
        ])
        XCTAssertEqual(
            (result["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String },
            ["episode-1", "episode-2", "episode-3"]
        )
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

    func testNetworkPreparerReturnsTypedPartialOutcomeAfterLaterPageFailure() async throws {
        let requests = Requests()
        let client = PodcastHTTPClient(transport: PagedFeedTransport(requests: requests, failAtPage: 2))
        let firstPage = URL(string: "https://example.com/page1.xml")!

        let outcome = try await PodcastRefreshNetworkPreparer.preparePages(
            from: firstPage,
            knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers(),
            profile: nil,
            firstPage: nil,
            startingAt: nil,
            client: client
        )

        XCTAssertTrue(outcome.isPartial)
        let result = try outcome.feed.importDictionary
        XCTAssertEqual(result["resumeURL"] as? String, "https://example.com/page2.xml")
        XCTAssertEqual(
            (result["episodes"] as? [[String: Any]])?.compactMap { $0["guid"] as? String },
            ["episode-1"]
        )
    }

    func testCancellationDuringLaterPageFetchPropagatesInsteadOfBecomingSuccess() async throws {
        let requests = Requests()
        let pageTwoGate = RequestGate()
        let client = PodcastHTTPClient(
            transport: CancellablePagedFeedTransport(
                requests: requests,
                pageTwoGate: pageTwoGate
            )
        )
        let firstPage = URL(string: "https://example.com/page1.xml")!
        let cancellationResult = CancellationResult()
        let fetchTask = Task {
            do {
                _ = try await PodcastParser.fetchAllPages(from: firstPage, client: client)
            } catch is CancellationError {
                await cancellationResult.markCancelled()
            } catch {
                XCTFail("Unexpected paged fetch failure: \(error)")
            }
        }

        await pageTwoGate.waitUntilReached()
        fetchTask.cancel()
        await fetchTask.value
        let wasCancelled = await cancellationResult.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(requests.snapshot(), [
            firstPage,
            URL(string: "https://example.com/page2.xml")!
        ])
    }
}
