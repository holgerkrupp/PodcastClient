import Foundation
import XCTest
@testable import UpNext

final class OPMLImportSanitizerTests: XCTestCase {
    func testSanitizesUnescapedAttributeCharactersFromAppleShortcutOPML() {
        let malformedOPML = """
        <?xml version="1.0"?>
        <opml version="1.0">
          <body>
            <outline type="rss" text="Arnes Geheimschrank - Podcastideen & mehr" title="Arnes Geheimschrank - Podcastideen & mehr" xmlUrl="https://example.com/feed?one=1&two=2"/>
            <outline type="rss" text="Communicator - Der "Star Trek"-Podcast" title="Communicator - Der "Star Trek"-Podcast" xmlUrl="https://example.com/star-trek"/>
          </body>
        </opml>
        """

        XCTAssertFalse(XMLParser(data: Data(malformedOPML.utf8)).parse())

        let sanitized = OPMLImportSanitizer.sanitize(malformedOPML)
        let parser = CountingXMLParser(data: Data(sanitized.utf8))

        XCTAssertTrue(parser.parse())
        XCTAssertEqual(parser.outlineCount, 2)
    }

    func testPreservesExistingXMLAndNumericEntities() {
        let validOPML = """
        <?xml version="1.0"?>
        <opml version="1.0">
          <body>
            <outline type="rss" text="A &amp; B &#38; C &quot;D&quot;" xmlUrl="https://example.com/feed?a=1&amp;b=2"/>
          </body>
        </opml>
        """

        XCTAssertEqual(OPMLImportSanitizer.sanitize(validOPML), validOPML)
    }
}

private final class CountingXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private(set) var outlineCount = 0

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool {
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "outline" {
            outlineCount += 1
        }
    }
}
