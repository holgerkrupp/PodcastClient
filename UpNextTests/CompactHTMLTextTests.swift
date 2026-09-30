import XCTest
@testable import UpNext

final class CompactHTMLTextTests: XCTestCase {
    func testNestedMarkupEntitiesAndParagraphsBecomeReadableText() {
        let description = "<p><strong>PC2.0 Episode #272</strong> &amp; more</p><p>Use &quot;plain text&quot;.</p>"

        XCTAssertEqual(
            description.plainTextFromHTML(),
            "PC2.0 Episode #272 & more Use \"plain text\"."
        )
    }

    func testPlainTextDescriptionRemainsUnchanged() {
        let description = "A plain description  with intentional spacing."

        XCTAssertEqual(description.plainTextFromHTML(), description)
    }

    func testInlineOnlyMarkupIsDecoded() {
        XCTAssertEqual(
            "<strong>Important</strong> &amp; useful".plainTextFromHTML(),
            "Important & useful"
        )
    }

    func testRawHTMLCanStillBeUsedByRichTextCallers() {
        let description = "<p><strong>Keep this markup</strong></p>"
        let feed = PodcastFeed(description: description)

        XCTAssertEqual(feed.description, description)
        XCTAssertEqual(description.plainTextFromHTML(), "Keep this markup")
    }
}
