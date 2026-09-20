import XCTest
@testable import UpNext

final class PodcastEpisodeShareImporterTests: XCTestCase {
    private let opaqueEpisodeURL = URL(
        string: "https://shows.acast.com/6610111dda0a08001611e540/episodes/6a9fe275d024784c99a29943"
    )!

    func testDiscoversAcastRSSAndCanonicalEpisodeLinks() throws {
        let html = """
        <html><head>
          <link type="application/rss+xml" rel="alternate"
                href="https://feeds.acast.com/public/shows/macht-und-millionen">
          <link rel="canonical"
                href="https://shows.acast.com/macht-und-millionen/episodes/insolvenz-autohaus-konig">
        </head></html>
        """
        let importer = PodcastEpisodeShareImporter()

        XCTAssertEqual(
            importer.discoverFeedURLs(in: html, baseURL: opaqueEpisodeURL),
            [URL(string: "https://feeds.acast.com/public/shows/macht-und-millionen")!]
        )
        XCTAssertEqual(
            importer.discoverCanonicalURL(in: html, baseURL: opaqueEpisodeURL),
            URL(string: "https://shows.acast.com/macht-und-millionen/episodes/insolvenz-autohaus-konig")!
        )
    }

    func testMatchesOpaqueAcastEpisodeURLToFeedGUID() throws {
        let draft = try XCTUnwrap(PodcastEpisodeDraft(episodeData: [
            "title": "Autohaus König",
            "guid": "6a9fe275d024784c99a29943",
            "link": "https://shows.acast.com/macht-und-millionen/episodes/insolvenz-autohaus-konig",
            "enclosure": [[
                "url": "https://sphinx.acast.com/p/open/s/show/e/6a9fe275d024784c99a29943/media.mp3",
                "type": "audio/mpeg"
            ]]
        ]))

        XCTAssertEqual(
            PodcastEpisodeShareImporter().matchingEpisode(
                in: [draft],
                sharedURLs: [opaqueEpisodeURL]
            ),
            draft
        )
    }

    func testDoesNotMatchGUIDAgainstUnrelatedParentPathComponents() throws {
        let draft = try XCTUnwrap(PodcastEpisodeDraft(episodeData: [
            "title": "Wrong episode",
            "guid": "episodes",
            "enclosure": [[
                "url": "https://example.com/wrong.mp3",
                "type": "audio/mpeg"
            ]]
        ]))

        XCTAssertNil(
            PodcastEpisodeShareImporter().matchingEpisode(
                in: [draft],
                sharedURLs: [opaqueEpisodeURL]
            )
        )
    }
}
