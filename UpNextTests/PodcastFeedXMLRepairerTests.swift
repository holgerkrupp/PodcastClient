import Foundation
import XCTest
@testable import UpNext

final class PodcastFeedXMLRepairerTests: XCTestCase {
    func testRepairsBareAmpersandsWithoutChangingExistingEntities() throws {
        let malformed = """
        <rss><channel>
          <title>Mac & iPhone &#38; &amp; Friends</title>
          <description>A & B</description>
          <atom:link href="https://example.com/feed?a=1&b=2&amp;c=3"/>
        </channel></rss>
        """

        let repair = try XCTUnwrap(PodcastFeedXMLRepairer.repairIfNeeded(from: Data(malformed.utf8)))
        let repaired = try XCTUnwrap(String(data: repair.data, encoding: .utf8))

        XCTAssertEqual(repair.bareAmpersands, 3)
        XCTAssertTrue(repaired.contains("Mac &amp; iPhone &#38; &amp; Friends"))
        XCTAssertTrue(repaired.contains("A &amp; B"))
        XCTAssertTrue(repaired.contains("a=1&amp;b=2&amp;c=3"))
        XCTAssertTrue(XMLParser(data: repair.data).parse())
    }

    func testRepairsDefinitelyTextLessThanAndLeavesCDATAAndCommentsOpaque() throws {
        let malformed = """
        <rss><channel>
          <title>Battery < 10% & charging</title>
          <description><![CDATA[Keep A & B < C exactly as written]]></description>
          <!-- Keep C & D < E exactly as written -->
        </channel></rss>
        """

        let repair = try XCTUnwrap(PodcastFeedXMLRepairer.repairIfNeeded(from: Data(malformed.utf8)))
        let repaired = try XCTUnwrap(String(data: repair.data, encoding: .utf8))

        XCTAssertEqual(repair.escapedLessThan, 1)
        XCTAssertTrue(repaired.contains("Battery &lt; 10% &amp; charging"))
        XCTAssertTrue(repaired.contains("<![CDATA[Keep A & B < C exactly as written]]>"))
        XCTAssertTrue(repaired.contains("<!-- Keep C & D < E exactly as written -->"))
        XCTAssertTrue(XMLParser(data: repair.data).parse())
    }

    func testRepairsUnambiguousQuotesInsideAttributeValues() throws {
        let malformed = """
        <rss><channel><item>
          <enclosure title="A "quoted" episode" url="https://example.com/audio.mp3"/>
        </item></channel></rss>
        """

        let repair = try XCTUnwrap(PodcastFeedXMLRepairer.repairIfNeeded(from: Data(malformed.utf8)))
        let repaired = try XCTUnwrap(String(data: repair.data, encoding: .utf8))

        XCTAssertEqual(repair.attributeQuotes, 2)
        XCTAssertTrue(repaired.contains("title=\"A &quot;quoted&quot; episode\""))
        XCTAssertTrue(XMLParser(data: repair.data).parse())
    }

    func testValidUTF8FeedDoesNotCreateRepairedCopy() {
        let valid = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel>
          <title>Café ☕ &amp; Tea</title>
          <atom:link href="https://example.com/feed?a=1&amp;b=2"/>
          <description><![CDATA[HTML A & B < C]]></description>
        </channel></rss>
        """

        XCTAssertNil(PodcastFeedXMLRepairer.repairedDataIfNeeded(from: Data(valid.utf8)))
    }

    func testNonUTF8DeclarationDoesNotUseUTF8Fallback() {
        let XMLWithNonUTF8Declaration = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <rss><channel><title>A & B</title></channel></rss>
        """

        XCTAssertNil(
            PodcastFeedXMLRepairer.repairedDataIfNeeded(from: Data(XMLWithNonUTF8Declaration.utf8))
        )
    }

    func testMalformedATPStyleFeedRecoversWithNewestEpisode() async throws {
        let malformed = """
        <rss version="2.0"><channel>
          <title>ATP & Friends</title>
          <item>
            <title>Hot Dog on an Actuator</title>
            <guid>atp-711</guid>
            <enclosure url="https://example.com/711.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """
        let originalData = Data(malformed.utf8)
        let strictParser = XMLParser(data: originalData)
        XCTAssertFalse(strictParser.parse())
        XCTAssertEqual((strictParser.parserError as NSError?)?.code, 68)

        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: originalData,
                sourceURL: URL(string: "https://example.com/atp.xml")!
            )
        )

        XCTAssertEqual(page.episodes.count, 1)
        XCTAssertEqual(page.episodes.first?.title, "Hot Dog on an Actuator")
    }

    func testRepairRetryPreservesEpisodeLimitAndKnownEpisodeStops() async throws {
        let malformed = """
        <rss version="2.0"><channel>
          <title>Show & More</title>
          <item><title>Newest</title><guid>newest</guid><enclosure url="https://example.com/new.mp3"/></item>
          <item><title>Known</title><guid>known</guid><enclosure url="https://example.com/known.mp3"/></item>
        </channel></rss>
        """
        let document = PodcastFeedDocument(
            data: Data(malformed.utf8),
            sourceURL: URL(string: "https://example.com/feed.xml")!
        )

        let limitedPage = try await PodcastParser.parsePage(from: document, maximumEpisodes: 1)
        XCTAssertEqual(limitedPage.episodes.count, 1)
        XCTAssertTrue(limitedPage.isPartial)

        let knownPage = try await PodcastParser.parsePage(
            from: document,
            knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers(guids: ["known"])
        )
        XCTAssertEqual(knownPage.episodes.count, 1)
        XCTAssertTrue(knownPage.didStopAtKnownEpisode)
    }

    func testStructuralFailuresStillReturnTheOriginalParseError() async {
        let malformed = """
        <rss><channel><title>Show & More</title><item><title>Unclosed</title></channel></rss>
        """
        let data = Data(malformed.utf8)
        let strictParser = XMLParser(data: data)
        let strictDelegate = PodcastParser()
        strictParser.shouldProcessNamespaces = true
        strictParser.delegate = strictDelegate
        XCTAssertFalse(strictParser.parse())
        let strictLine = strictParser.lineNumber
        let strictColumn = strictParser.columnNumber

        do {
            _ = try await PodcastParser.parsePage(
                from: PodcastFeedDocument(
                    data: data,
                    sourceURL: URL(string: "https://example.com/feed.xml")!
                )
            )
            XCTFail("Structural XML errors must not be repaired")
        } catch let error as PodcastParserError {
            guard case let .xmlParserError(_, line, column) = error else {
                return XCTFail("Unexpected parser error: \(error)")
            }
            XCTAssertEqual(line, strictLine)
            XCTAssertEqual(column, strictColumn)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
