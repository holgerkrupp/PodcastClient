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
        let html = "not a url https:// and ftp://example.com/file"
        XCTAssertTrue(ShownoteLinkExtractor.extract(from: html).isEmpty)
    }

    func testPlainEmailAddressesBecomeMailtoLinksWithoutEnrichment() {
        let html = "Questions? team@example.com or support@example.org."
        let document = ShownoteDocument(html: html)

        XCTAssertEqual(document.candidates.count, 2)
        XCTAssertTrue(document.candidates.allSatisfy { $0.occurrenceKind == .email })
        XCTAssertTrue(document.candidates.allSatisfy { $0.originalURL.scheme == "mailto" })
        XCTAssertTrue(document.linkifiedHTML.contains("mailto:team@example.com"))
        XCTAssertTrue(document.linkifiedHTML.contains("mailto:support@example.org"))
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

    func testInvalidFeedShapedResponseStaysAWebPreview() async throws {
        let url = URL(string: "https://example.com/techcrunch")!
        let html = "<html><head><meta property=\"og:title\" content=\"TechCrunch\"><meta property=\"og:description\" content=\"News\"><meta property=\"og:url\" content=\"https://techcrunch.com/article\"></head></html>"
        let loader = FixtureShownoteLoader(resources: [url: .html(html, url: url)])
        let service = ShownoteEnrichmentService(loader: loader)
        let candidate = try XCTUnwrap(ShownoteLinkExtractor.extract(from: url.absoluteString).first)

        let result = await service.resolve(candidate)

        XCTAssertEqual(result.classification, .web)
        XCTAssertNil(result.podcastFeed)
        XCTAssertEqual(result.preview?.title, "TechCrunch")
        XCTAssertEqual(result.preview?.description, "News")
        XCTAssertEqual(result.finalURL?.absoluteString, "https://techcrunch.com/article")
    }

    func testMastodonProfileGetsItsOwnClassificationAndHandle() async throws {
        let profileURL = URL(string: "https://social.example/@alice")!
        let html = """
        <html><head>
        <meta name="application-name" content="Mastodon">
        <meta property="og:title" content="Alice Example">
        <meta property="og:description" content="A profile">
        <meta property="og:image" content="/avatars/alice.png">
        <link rel="alternate" type="application/activity+json" href="/users/alice">
        </head></html>
        """
        let loader = FixtureShownoteLoader(resources: [profileURL: .html(html, url: profileURL)])
        let service = ShownoteEnrichmentService(loader: loader)
        let candidate = try XCTUnwrap(ShownoteLinkExtractor.extract(from: profileURL.absoluteString).first)

        let result = await service.resolve(candidate)

        XCTAssertEqual(result.classification, .mastodon)
        XCTAssertNil(result.podcastFeed)
        XCTAssertEqual(result.preview?.handle, "@alice@social.example")
        XCTAssertEqual(result.preview?.imageURL?.absoluteString, "https://social.example/avatars/alice.png")
        XCTAssertEqual(result.finalURL?.absoluteString, profileURL.absoluteString)
    }

    func testContentBlocksDoNotLeaveEmptyListItemsAroundEnrichedLinks() throws {
        let html = "<ul><li>Read this first</li><li><a href=\"https://example.com/nextcloud\">Nextcloud</a></li><li>Read this last</li></ul>"
        let document = ShownoteDocument(html: html)

        let fragments = document.blocks.compactMap { block -> String? in
            guard case .html(_, let value) = block else { return nil }
            return value
        }

        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertFalse(fragments.contains { $0.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertFalse(fragments.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "<ul><li>" })
        XCTAssertFalse(fragments.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "</li></ul>" })
    }

    func testInlineLinksStayInsideTheirOriginalParagraph() {
        let html = "<p>Read <a href=\"https://example.com/article\">the article</a> for context.</p>"
        let document = ShownoteDocument(html: html)

        XCTAssertEqual(document.candidates.count, 1)
        XCTAssertEqual(document.candidates[0].presentation, .inline)
        XCTAssertEqual(document.blocks.count, 1)
        guard case .html(_, let value) = document.blocks[0] else {
            return XCTFail("An inline link must remain in the HTML block")
        }
        XCTAssertTrue(value.contains("<p>Read <a href=\"https://example.com/article\">the article</a> for context.</p>"))
    }

    func testFS312FixturesKeepStandaloneCardsOutOfInlineAndNestedListMarkup() {
        let html = """
        <p>See <a href="https://example.com/context">the context</a> for source.</p>
        <ul>
          <li><a href="https://nextcloud.com">Nextcloud</a></li>
          <li>Read the <a href="https://techcrunch.com/article">TechCrunch article</a> next.</li>
          <li>Resources<ul><li><a href="https://example.com/nested">Nested resource</a></li></ul></li>
        </ul>
        <ol><li><a href="https://github.com/example/project">GitHub project</a></li><li>Keep this item</li></ol>
        """
        let document = ShownoteDocument(html: html)

        XCTAssertEqual(document.candidates.count, 5)
        XCTAssertEqual(document.candidates.filter { $0.presentation == .standalone }.count, 3)
        XCTAssertEqual(document.candidates.filter { $0.presentation == .inline }.count, 2)
        XCTAssertEqual(document.blocks.filter {
            if case .link = $0 { return true }
            return false
        }.count, 3)

        let fragments = document.blocks.compactMap { block -> String? in
            guard case .html(_, let value) = block else { return nil }
            return value
        }
        XCTAssertFalse(fragments.contains {
            $0.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        })
        XCTAssertTrue(fragments.joined().contains("TechCrunch article"))
        XCTAssertTrue(fragments.joined().contains("the context"))
    }

    func testMalformedHTMLFallsBackWithoutEmptyListMarkers() {
        let html = "<ul><li><a href=\"https://example.com/broken\">Broken item</a><li>Following item"
        let document = ShownoteDocument(html: html)

        XCTAssertEqual(document.candidates.count, 1)
        XCTAssertTrue(document.blocks.allSatisfy {
            guard case .html(_, let value) = $0 else { return true }
            return value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        })
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

    func testCachedLookupNeverStartsNetworkWork() async throws {
        let url = URL(string: "https://example.com/cached-feed.xml")!
        let loader = FixtureShownoteLoader(resources: [url: .rss(title: "Cached Show", url: url)])
        let service = ShownoteEnrichmentService(loader: loader)
        let candidate = try XCTUnwrap(ShownoteLinkExtractor.extract(from: url.absoluteString).first)

        let initiallyCached = await service.cachedResults(for: [candidate])
        let initialRequestCount = await loader.count(for: url)
        XCTAssertTrue(initiallyCached.isEmpty)
        XCTAssertEqual(initialRequestCount, 0)

        _ = await service.resolve(candidate)
        let cached = await service.cachedResults(for: [candidate])
        let requestCount = await loader.count(for: url)

        XCTAssertEqual(cached.count, 1)
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
