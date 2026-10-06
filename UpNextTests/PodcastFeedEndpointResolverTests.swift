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
}
