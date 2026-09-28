import Foundation
import XCTest
@testable import UpNext

final class PodcastSearchInputTests: XCTestCase {
    func testNormalSearchTextIsNotAURL() {
        XCTAssertNil(PodcastSearchInputRecognizer.url(from: "Accidental Tech Podcast"))
    }

    func testHTTPURLIsRecognized() {
        XCTAssertEqual(
            PodcastSearchInputRecognizer.url(from: "http://example.com/feed.xml")?.absoluteString,
            "http://example.com/feed.xml"
        )
    }

    func testHTTPSURLIsRecognized() {
        XCTAssertEqual(
            PodcastSearchInputRecognizer.url(from: "https://example.com/feed.xml")?.absoluteString,
            "https://example.com/feed.xml"
        )
    }

    func testURLQueryItemsArePreservedExactly() {
        let input = "https://example.com/podcast/rss?token=personal-secret&user=alice"

        XCTAssertEqual(
            PodcastSearchInputRecognizer.url(from: input)?.absoluteString,
            input
        )
    }

    func testLeadingAndTrailingWhitespaceIsIgnoredForInterpretation() {
        let input = "\n  https://example.com/feed.xml?token=secret  \n"

        XCTAssertEqual(
            PodcastSearchInputRecognizer.url(from: input)?.absoluteString,
            "https://example.com/feed.xml?token=secret"
        )
    }

    func testMalformedURLIsNotRecognized() {
        XCTAssertNil(PodcastSearchInputRecognizer.url(from: "https://"))
        XCTAssertNil(PodcastSearchInputRecognizer.url(from: "https://example .com/feed.xml"))
    }

    func testOrdinaryTextContainingDotsRemainsSearchText() {
        XCTAssertNil(PodcastSearchInputRecognizer.url(from: "Season 2.0: the follow-up"))
    }

    func testChangingFromURLBackToNormalQueryChangesClassification() {
        XCTAssertNotNil(PodcastSearchInputRecognizer.url(from: "https://example.com/feed.xml"))
        XCTAssertNil(PodcastSearchInputRecognizer.url(from: "Accidental Tech Podcast"))
    }

    func testHTMLFeedDiscoveryKeepsSameOriginAccessQueryItems() throws {
        let pageURL = URL(string: "https://example.com/show?token=personal-secret")!
        let html = #"<link rel="alternate" type="application/rss+xml" href="/feeds/show.xml">"#
        let discovered = try XCTUnwrap(
            PodcastFeedResolver.extractFeedURL(fromHTML: html, baseURL: pageURL)
        )

        XCTAssertEqual(
            discovered.preservingFeedAccessComponents(from: pageURL).absoluteString,
            "https://example.com/feeds/show.xml?token=personal-secret"
        )
    }

    func testHTTPToHTTPSRedirectKeepsAccessQueryItems() {
        let source = URL(string: "http://example.com/feed.xml?token=personal-secret")!
        let destination = URL(string: "https://example.com/feed.xml")!

        XCTAssertEqual(
            destination.preservingFeedAccessComponents(from: source).absoluteString,
            "https://example.com/feed.xml?token=personal-secret"
        )
    }
}
