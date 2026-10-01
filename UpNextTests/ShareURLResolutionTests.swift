import XCTest
@testable import UpNext

final class ShareURLResolutionTests: XCTestCase {
    func testARDItemURNSupportsEpisodeSectionAndExtraURLs() {
        XCTAssertEqual(
            ARDSoundsAPI.itemURN(in: URL(string: "https://www.ardsounds.de/episode/urn:ard:episode:fbbac50365a1338e/")!),
            "urn:ard:episode:fbbac50365a1338e"
        )
        XCTAssertEqual(
            ARDSoundsAPI.itemURN(in: URL(string: "https://www.ardaudiothek.de/episode/urn:ard:section:855c7a53dac72e0a/")!),
            "urn:ard:section:855c7a53dac72e0a"
        )
        XCTAssertEqual(
            ARDSoundsAPI.itemURN(in: URL(string: "https://www.ardsounds.de/episode/urn:ard:extra:d2fe7303d2dcbf5d/")!),
            "urn:ard:extra:d2fe7303d2dcbf5d"
        )
    }

    func testARDItemURNRejectsUnrelatedURLs() {
        XCTAssertNil(ARDSoundsAPI.itemURN(in: URL(string: "https://example.com/episode/123")!))
        XCTAssertNil(ARDSoundsAPI.itemURN(in: URL(string: "https://example.com/urn:ard:episode:fbbac50365a1338e")!))
    }

    func testHTMLFeedLinksAndMatchingEpisodeRemainDeterministic() {
        let importer = PodcastEpisodeShareImporter()
        let baseURL = URL(string: "https://example.com/episode/dark-matters")!
        let html = #"<link rel="alternate" type="application/rss+xml" href="/feed.xml">"#
        XCTAssertEqual(
            importer.discoverFeedURLs(in: html, baseURL: baseURL),
            [URL(string: "https://example.com/feed.xml")!]
        )

        let episodeURL = URL(string: "https://cdn.example.com/dark-matters.mp3")!
        let draft = PodcastEpisodeDraft(episodeData: [
            "title": "Dark Matters",
            "guid": "dark-matters",
            "enclosure": [["url": episodeURL.absoluteString, "type": "audio/mpeg"]]
        ])!
        XCTAssertEqual(importer.matchingEpisode(in: [draft], sharedURLs: [baseURL]), nil)
        XCTAssertEqual(importer.matchingEpisode(in: [draft], sharedURLs: [episodeURL]), draft)
    }
}
