import Foundation
import XCTest
@testable import UpNext

/// Fixture-backed tests for the providers that read public directory pages.
/// Every field has to survive a real page, and a mangled page must degrade
/// rather than crash.
final class PodcastDiscoveryParsingTests: XCTestCase {

    // MARK: - RNZ

    func testRNZDirectoryExtractsTitleArtworkDescriptionAndFeed() throws {
        let markup = try DiscoveryFixture.markup("rnz-podcast-directory")

        let podcasts = RNZDirectoryParser.parseDirectory(
            markup: markup,
            providerID: "rnz",
            broadcasterID: "rnz"
        )

        XCTAssertEqual(podcasts.count, 2)

        let blackSheep = try XCTUnwrap(podcasts.first { $0.id == "black-sheep" })
        XCTAssertEqual(blackSheep.title, "Black Sheep")
        XCTAssertEqual(
            blackSheep.feedURL?.absoluteString,
            "https://www.rnz.co.nz/podcasts/acast/black-sheep.rss"
        )
        XCTAssertEqual(blackSheep.language, "en")
        XCTAssertEqual(blackSheep.webpageURL?.absoluteString, "https://www.rnz.co.nz/podcast/black-sheep")
        XCTAssertEqual(blackSheep.artworkURL?.host(), "media.rnztools.nz")
        let summary = try XCTUnwrap(blackSheep.summary)
        XCTAssertTrue(summary.contains("villainous"), summary)
        // "&" arrives as a & escape and has to be decoded.
        XCTAssertFalse(summary.contains("\\u"), summary)

        let enzology = try XCTUnwrap(podcasts.first { $0.id == "enzology" })
        XCTAssertEqual(enzology.title, "Enzology")
        XCTAssertEqual(
            enzology.feedURL?.absoluteString,
            "https://www.rnz.co.nz/podcasts/acast/enzology.rss"
        )
    }

    func testRNZDirectoryIsSortedAndFreeOfDuplicates() throws {
        let markup = try DiscoveryFixture.markup("rnz-podcast-directory")
        let podcasts = RNZDirectoryParser.parseDirectory(markup: markup, providerID: "rnz", broadcasterID: "rnz")

        XCTAssertEqual(podcasts.map(\.title), podcasts.map(\.title).sorted())
        XCTAssertEqual(Set(podcasts.map(\.id)).count, podcasts.count)
    }

    func testRNZFallsBackToFeedLinksWhenTheEmbeddedPayloadChanges() {
        // The embedded objects are gone; only the feed URLs remain.
        let markup = """
        <html><body>
        <a href="/podcast/the-detail">The Detail</a>
        <script>{"url":"https://www.rnz.co.nz/podcasts/acast/the-detail.rss"}</script>
        </body></html>
        """

        let podcasts = RNZDirectoryParser.parseDirectory(markup: markup, providerID: "rnz", broadcasterID: "rnz")

        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.id, "the-detail")
        XCTAssertEqual(podcasts.first?.title, "The Detail")
        XCTAssertEqual(
            podcasts.first?.feedURL?.absoluteString,
            "https://www.rnz.co.nz/podcasts/acast/the-detail.rss"
        )
    }

    func testRNZParsingOfMalformedMarkupYieldsNothingInsteadOfCrashing() throws {
        let markup = try DiscoveryFixture.markup("rnz-podcast-directory")

        for truncation in [0, 10, 512, 4249, 4260] {
            let truncated = String(markup.prefix(truncation))
            _ = RNZDirectoryParser.parseDirectory(markup: truncated, providerID: "rnz", broadcasterID: "rnz")
        }

        XCTAssertTrue(
            RNZDirectoryParser.parseDirectory(markup: "", providerID: "rnz", broadcasterID: "rnz").isEmpty
        )
        XCTAssertTrue(
            RNZDirectoryParser.parseDirectory(
                markup: "<html><body>not a directory</body></html>",
                providerID: "rnz",
                broadcasterID: "rnz"
            ).isEmpty
        )
    }

    func testRNZShowPageFeedExtraction() {
        let markup = #"""
        <html><head></head><body>
        <script>{"acast_url":"https:\/\/www.rnz.co.nz\/podcasts\/acast\/mediawatch.rss"}</script>
        </body></html>
        """#

        XCTAssertEqual(
            RNZDirectoryParser.parseFeedURL(showPageMarkup: markup)?.absoluteString,
            "https://www.rnz.co.nz/podcasts/acast/mediawatch.rss"
        )

        // The conventional advertisement works too.
        let linkMarkup = """
        <html><head>
        <link rel="alternate" type="application/rss+xml" href="/feeds/example.xml">
        </head></html>
        """
        XCTAssertEqual(
            RNZDirectoryParser.parseFeedURL(showPageMarkup: linkMarkup)?.absoluteString,
            "https://www.rnz.co.nz/feeds/example.xml"
        )

        XCTAssertNil(RNZDirectoryParser.parseFeedURL(showPageMarkup: "<html></html>"))
    }

    // MARK: - RTP

    func testRTPDirectoryExtractsTitleArtworkAndShowPage() throws {
        let markup = try DiscoveryFixture.markup("rtp-podcast-directory")

        let podcasts = RTPDirectoryParser.parseDirectory(
            markup: markup,
            providerID: "rtp",
            broadcasterID: "rtp"
        )

        XCTAssertFalse(podcasts.isEmpty)

        let show = try XCTUnwrap(podcasts.first { $0.id == "5442" })
        XCTAssertEqual(show.title, "Noticiários RTP África")
        XCTAssertEqual(show.webpageURL?.absoluteString, "https://www.rtp.pt/play/p5442/noticiarios-rdp-africa")
        XCTAssertEqual(show.artworkURL?.host(), "cdn-images.rtp.pt")
        XCTAssertEqual(show.language, "pt")
        // RTP publishes no RSS on the directory page; resolution is a second step.
        XCTAssertNil(show.feedURL)
    }

    func testRTPCardsDoNotBorrowFieldsFromNeighbours() throws {
        let markup = try DiscoveryFixture.markup("rtp-podcast-directory")
        let podcasts = RTPDirectoryParser.parseDirectory(markup: markup, providerID: "rtp", broadcasterID: "rtp")

        XCTAssertEqual(Set(podcasts.map(\.id)).count, podcasts.count)
        XCTAssertEqual(Set(podcasts.map { $0.webpageURL?.absoluteString }).count, podcasts.count)
        XCTAssertEqual(Set(podcasts.map(\.title)).count, podcasts.count)
    }

    func testRTPParsingOfMissingElementsSkipsTheCard() {
        // An article with no title is dropped rather than shown as an empty row.
        let markup = """
        <div><article id="program-id-99"><a href="/play/p99/x"></a></article></div>
        """

        XCTAssertTrue(
            RTPDirectoryParser.parseDirectory(markup: markup, providerID: "rtp", broadcasterID: "rtp").isEmpty
        )
        XCTAssertTrue(
            RTPDirectoryParser.parseDirectory(markup: "", providerID: "rtp", broadcasterID: "rtp").isEmpty
        )
    }

    func testApplePodcastsCollectionIDIsExtractedFromAShowPage() {
        let markup = """
        <a href="https://podcasts.apple.com/pt/podcast/duas-de-prosa-podcast/id1846686005">Apple</a>
        """

        XCTAssertEqual(ApplePodcastsFeedResolver.appleCollectionID(inMarkup: markup), "1846686005")
        XCTAssertNil(ApplePodcastsFeedResolver.appleCollectionID(inMarkup: "<a href=\"https://example.com\">x</a>"))
    }

    // MARK: - Scanner

    func testMarkupScannerHandlesEntitiesAndEscapes() {
        XCTAssertEqual(DiscoveryMarkupScanner.decodingHTMLEntities("A &amp; B &quot;C&quot;"), "A & B \"C\"")
        XCTAssertEqual(DiscoveryMarkupScanner.decodingHTMLEntities("caf&#233;"), "café")
        XCTAssertEqual(DiscoveryMarkupScanner.decodingJSONEscapes("A \\u0026 B"), "A & B")
        XCTAssertEqual(DiscoveryMarkupScanner.plainText(from: "<p>Hello   <b>world</b></p>"), "Hello world")
        XCTAssertEqual(
            DiscoveryMarkupScanner.metaContent(property: "og:title", in: "<meta property=\"og:title\" content=\"X\">"),
            "X"
        )
        XCTAssertNil(DiscoveryMarkupScanner.metaContent(property: "og:title", in: "<html></html>"))
    }

    func testPrecedingJSONLookupStaysInsideItsWindow() {
        let payload = #"{"name":"Far away"}"# + String(repeating: " ", count: 500) + #"{"anchor":"here"}"#
        let anchor = try! XCTUnwrap(payload.range(of: #""anchor""#)).lowerBound

        XCTAssertEqual(
            DiscoveryMarkupScanner.precedingJSONString(key: "name", before: anchor, in: payload, window: 8000),
            "Far away"
        )
        // A tight window must not reach back to the previous object's field.
        XCTAssertNil(
            DiscoveryMarkupScanner.precedingJSONString(key: "name", before: anchor, in: payload, window: 100)
        )
    }
}
