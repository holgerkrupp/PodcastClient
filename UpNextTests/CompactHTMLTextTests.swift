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

    func testCommonNamedAndNumericEntitiesAreDecoded() {
        XCTAssertEqual(
            "&nbsp;Alice&#39;s podcast &#x2014; today".plainTextFromHTML(),
            "Alice's podcast — today"
        )
    }

    func testMultipleBlockElementsAndLineBreaksBecomeSpacing() {
        XCTAssertEqual(
            "<div>First<br>second</div><ul><li>One</li><li>Two</li></ul>".plainTextFromHTML(),
            "First second One Two"
        )
    }

    func testMalformedMarkupDoesNotLeakTags() {
        XCTAssertEqual(
            "<p>Unclosed <strong>description".plainTextFromHTML(),
            "Unclosed description"
        )
        XCTAssertEqual("Before <div".plainTextFromHTML(), "Before")
    }

    func testUnknownEntitiesRemainVisible() {
        XCTAssertEqual(
            "A &unknown; entity and an ampersand & here".plainTextFromHTML(),
            "A &unknown; entity and an ampersand & here"
        )
    }

    func testEmptyAndLongDescriptionsAreSupported() {
        XCTAssertEqual("".plainTextFromHTML(), "")

        let description = String(repeating: "<p>Episode &amp; details</p>", count: 200)
        let expected = Array(repeating: "Episode & details", count: 200).joined(separator: " ")
        XCTAssertEqual(description.plainTextFromHTML(), expected)
    }
}
