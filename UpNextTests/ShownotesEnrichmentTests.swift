import Foundation
import XCTest
@testable import UpNext

final class ShownotesEnrichmentTests: XCTestCase {
    func testExtractsPlainURLsWithoutDoubleLinkifyingPublisherAnchors() throws {
        let html = """
        <p>Mehr Infos: https://example.com/show?id=42&amp;from=notes.</p>
        <p><a href="https://example.com/linked">https://example.com/linked</a></p>
        """

        let document = ShownoteDocument(html: html)

        XCTAssertEqual(document.candidates.count, 2)
        XCTAssertEqual(document.candidates[0].occurrenceKind, .plainText)
        XCTAssertEqual(document.candidates[1].occurrenceKind, .publisherAnchor)
        XCTAssertEqual(document.candidates[0].normalizedURL.absoluteString, "https://example.com/show?id=42&from=notes")
        XCTAssertEqual(document.candidates[1].publisherAnchorText, "https://example.com/linked")
        XCTAssertEqual(document.linkifiedHTML.components(separatedBy: "<a ").count - 1, 2)
        XCTAssertFalse(document.linkifiedHTML.contains("<a href=\"https://example.com/linked\"><a"))
    }

    func testTrimsSentencePunctuationButPreservesQueryAndUnicodeContext() {
        let html = "Empfehlung für Café: https://example.org/podcast?q=100%25&lang=de)."
        let candidates = ShownoteLinkExtractor.extract(from: html)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].displayText, "https://example.org/podcast?q=100%25&lang=de")
        XCTAssertTrue(candidates[0].sourceRange.location > 0)
    }

    func testExtractsDuplicateOccurrencesAndNormalizesOnlySafeComponents() throws {
        let html = "https://EXAMPLE.com/feed#one and https://example.com/feed#two"
        let candidates = ShownoteLinkExtractor.extract(from: html)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].normalizedURL, candidates[1].normalizedURL)
        XCTAssertEqual(candidates[0].normalizedURL.absoluteString, "https://example.com/feed")
        XCTAssertNotEqual(candidates[0].id, candidates[1].id)
    }

    func testMalformedAndNonHTTPURLsAreIgnored() {
        let html = "not a url https:// and mailto:test@example.com"
        XCTAssertTrue(ShownoteLinkExtractor.extract(from: html).isEmpty)
    }

    func testDirectFeedIsRecognizedAndRepeatedResolutionUsesCache() async throws {
        let url = URL(string: "https://example.com/feed.xml")!
        let loader = FixtureShownoteLoader(resources: [url: .rss(title: "Fixture Show", url: url)])
        let service = ShownoteEnrichmentService(loader: loader, maximumCandidatesPerEpisode: 24)
        let candidate = try XCTUnwrap(ShownoteLinkExtractor.extract(from: url.absoluteString).first)

        let first = await service.resolve(candidate)
        let second = await service.resolve(candidate)

        XCTAssertEqual(first.classification, .podcast)
        XCTAssertEqual(first.podcastFeed?.title, "Fixture Show")
        XCTAssertEqual(second.classification, .podcast)
        let requestCount = await loader.count(for: url)
        XCTAssertEqual(requestCount, 1)
    }

    func testHTMLFeedDiscoveryRecognizesOnlyValidatedPodcastFeeds() async throws {
        let pageURL = URL(string: "https://example.com/recommendation")!
        let feedURL = URL(string: "https://example.com/podcast.xml")!
        let html = "<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/podcast.xml\"></head></html>"
        let loader = FixtureShownoteLoader(resources: [
            pageURL: .html(html, url: pageURL),
            feedURL: .rss(title: "Discovered Show", url: feedURL)
        ])
        let service = ShownoteEnrichmentService(loader: loader)
        let candidate = try XCTUnwrap(ShownoteLinkExtractor.extract(from: pageURL.absoluteString).first)

        let result = await service.resolve(candidate)

        XCTAssertEqual(result.classification, .podcast)
        XCTAssertEqual(result.podcastFeed?.title, "Discovered Show")
        let pageRequestCount = await loader.count(for: pageURL)
        let feedRequestCount = await loader.count(for: feedURL)
        XCTAssertEqual(pageRequestCount, 1)
        XCTAssertEqual(feedRequestCount, 1)
    }

    func testManyCandidatesAreBoundedAndNegativeResultsAreCached() async throws {
        let urls = (0..<8).map { URL(string: "https://example.com/page\($0)")! }
        let resources = Dictionary(uniqueKeysWithValues: urls.map { ($0, FixtureShownoteResource.html("<html>not a podcast</html>", url: $0)) })
        let loader = FixtureShownoteLoader(resources: resources)
        let service = ShownoteEnrichmentService(loader: loader, maximumCandidatesPerEpisode: 3)
        let candidates = try urls.map { url in
            try XCTUnwrap(ShownoteLinkExtractor.extract(from: url.absoluteString).first)
        }

        let results = await service.enrich(candidates)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.classification == .web })

        _ = await service.resolve(candidates[0])
        let requestCount = await loader.count(for: urls[0])
        XCTAssertEqual(requestCount, 1)
    }
}

private struct FixtureShownoteResource: Sendable {
    let data: Data
    let url: URL
    let mimeType: String

    static func rss(title: String, url: URL) -> Self {
        let xml = "<rss version=\"2.0\"><channel><title>\(title)</title><link>\(url.absoluteString)</link><description>Fixture</description></channel></rss>"
        return Self(data: Data(xml.utf8), url: url, mimeType: "application/rss+xml")
    }

    static func html(_ html: String, url: URL) -> Self {
        Self(data: Data(html.utf8), url: url, mimeType: "text/html")
    }
}

private actor FixtureShownoteLoader: ShownoteResourceLoader {
    let resources: [URL: FixtureShownoteResource]
    private var counts: [URL: Int] = [:]

    init(resources: [URL: FixtureShownoteResource]) {
        self.resources = resources
    }

    func load(_ url: URL) async throws -> ShownoteHTTPResource {
        counts[url, default: 0] += 1
        guard let resource = resources[url] else {
            throw ShownoteResolutionError.unsupportedResource
        }
        return ShownoteHTTPResource(
            data: resource.data,
            responseURL: resource.url,
            statusCode: 200,
            mimeType: resource.mimeType
        )
    }

    func count(for url: URL) -> Int {
        counts[url, default: 0]
    }
}
