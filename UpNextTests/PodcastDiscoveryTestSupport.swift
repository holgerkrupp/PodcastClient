import Foundation
import XCTest
@testable import UpNext

/// Loads a stored fixture, preferring the test bundle and falling back to the
/// source tree so the fixtures work however the target is built.
enum DiscoveryFixture {
    static func markup(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        if let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "html"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }

        let sourceURL = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name + ".html")

        guard let contents = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("Missing fixture \(name).html", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }

        return contents
    }

    private final class BundleToken {}
}

/// A transport that answers from a fixed table of responses and records what it
/// was asked for, so provider tests never touch a broadcaster's servers.
final class StubTransport: @unchecked Sendable {
    struct Response {
        var data: Data
        var statusCode: Int = 200
        var contentType: String? = "application/json"
        var error: Error?
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private(set) var requestedURLs: [URL] = []

    func stub(_ urlPrefix: String, response: Response) {
        lock.withLock { responses[urlPrefix] = response }
    }

    func stub(_ urlPrefix: String, json: String) {
        stub(urlPrefix, response: Response(data: Data(json.utf8), contentType: "application/json"))
    }

    func stub(_ urlPrefix: String, markup: String) {
        stub(urlPrefix, response: Response(data: Data(markup.utf8), contentType: "text/html"))
    }

    var client: PodcastDiscoveryHTTPClient {
        PodcastDiscoveryHTTPClient(transport: { [self] request in
            guard let url = request.url else { throw URLError(.badURL) }

            let match = lock.withLock { () -> Response? in
                requestedURLs.append(url)
                return responses
                    .filter { url.absoluteString.hasPrefix($0.key) }
                    .max(by: { $0.key.count < $1.key.count })?
                    .value
            }

            guard let match else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }

            if let error = match.error { throw error }

            var headers: [String: String] = [:]
            if let contentType = match.contentType { headers["Content-Type"] = contentType }

            let response = HTTPURLResponse(
                url: url,
                statusCode: match.statusCode,
                httpVersion: nil,
                headerFields: headers
            )!

            return (match.data, response)
        })
    }
}

/// A provider whose behaviour each test dictates outright.
struct StubDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    let capabilities: PodcastDiscoveryCapabilities
    let searchResults: [DiscoveredPodcast]
    let searchError: (any Error)?
    /// Seconds of simulated latency, to prove searches really do run concurrently.
    let searchDelay: Duration

    var id: String { broadcaster.id }

    init(
        broadcaster: PublicBroadcaster,
        capabilities: PodcastDiscoveryCapabilities = [.search, .feedURL],
        searchResults: [DiscoveredPodcast] = [],
        searchError: (any Error)? = nil,
        searchDelay: Duration = .zero
    ) {
        self.broadcaster = broadcaster
        self.capabilities = capabilities
        self.searchResults = searchResults
        self.searchError = searchError
        self.searchDelay = searchDelay
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        if searchDelay > .zero {
            try? await Task.sleep(for: searchDelay)
        }
        if let searchError { throw searchError }
        return searchResults
    }
}

extension PublicBroadcaster {
    static func testBroadcaster(
        id: String,
        name: String? = nil,
        countryCode: String = "CH",
        region: PublicBroadcasterRegion = .europe
    ) -> PublicBroadcaster {
        PublicBroadcaster(
            id: id,
            name: name ?? id.uppercased(),
            countryCode: countryCode,
            region: region,
            summary: LocalizedStringResource("Test broadcaster.")
        )
    }
}

extension DiscoveredPodcast {
    static func testPodcast(
        id: String,
        title: String,
        broadcasterID: String,
        feedURL: URL? = nil,
        author: String? = nil
    ) -> DiscoveredPodcast {
        DiscoveredPodcast(
            id: id,
            title: title,
            author: author,
            feedURL: feedURL,
            providerID: broadcasterID,
            broadcasterID: broadcasterID
        )
    }
}
