import XCTest
@testable import UpNext

final class ShownoteNativeHTMLParserTests: XCTestCase {
    func testPreservesInlineFormattingLinksAndOrderedLists() throws {
        let html = """
        <h2>Episode notes</h2>
        <p><strong>Bold text</strong>, <em>emphasis</em>, and <a href="https://example.com/source?x=1&amp;y=2">the source</a>.</p>
        <ol><li>First step</li><li>Second step</li></ol>
        """

        let elements = ShownoteNativeHTMLParser.elements(in: html)
        let text = try XCTUnwrap(elements.compactMap { element -> AttributedString? in
            guard case .text(let value) = element.content else { return nil }
            return value
        }.first)
        let rendered = elements.compactMap { element -> String? in
            guard case .text(let value) = element.content else { return nil }
            return String(value.characters)
        }.joined()

        XCTAssertTrue(rendered.contains("Episode notes"))
        XCTAssertTrue(rendered.contains("Bold text"))
        XCTAssertTrue(rendered.contains("1. First step"))
        XCTAssertTrue(rendered.contains("2. Second step"))
        XCTAssertTrue(text.runs.contains { $0.link?.absoluteString == "https://example.com/source?x=1&y=2" })
        XCTAssertTrue(text.runs.contains { $0.underlineStyle != nil })
    }

    func testKeepsImageAltTextAndReadableMalformedMarkup() {
        let html = #"Before <img src="https://example.com/art.jpg" alt="Cover art"> after <strong>unfinished"#
        let elements = ShownoteNativeHTMLParser.elements(in: html)
        let image = elements.first { element in
            if case .image = element.content { return true }
            return false
        }
        let renderedText = elements.compactMap { element -> String? in
            guard case .text(let value) = element.content else { return nil }
            return String(value.characters)
        }.joined()

        XCTAssertNotNil(image)
        XCTAssertTrue(renderedText.contains("Before"))
        XCTAssertTrue(renderedText.contains("after"))
        XCTAssertTrue(renderedText.contains("unfinished"))
    }
}
