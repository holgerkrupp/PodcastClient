import Foundation
import XCTest
@testable import UpNext

final class PodcastFeedEpisodePagerTests: XCTestCase {
    func testBatchBoundariesPreserveOrderAndStableIDs() {
        for count in [0, 1, 19, 20, 21, 101, 5_000] {
            var pager = PodcastFeedEpisodePager(batchSize: 20)
            let url = URL(string: "https://example.com/feed.xml")!
            let input = drafts(count: count)

            var output = pager.appendPage(input, requestedURL: url, nextPageURL: nil)
            while pager.hasUndeliveredEpisodes {
                output.append(contentsOf: pager.nextBatch())
            }

            XCTAssertEqual(output.map(\.id), input.map(\.id), "count=\(count)")
            XCTAssertFalse(pager.hasMoreEpisodes)
        }
    }

    func testDuplicateGUIDAndGuidlessEnclosureAreDeduplicatedAcrossPages() {
        let firstPage = drafts(count: 2, ids: ["shared-guid", nil])
        let secondPage = [draft(guid: "shared-guid", enclosure: 99), draft(guid: nil, enclosure: 1), draft(guid: "new", enclosure: 2)]
        var pager = PodcastFeedEpisodePager(batchSize: 20)
        let firstURL = URL(string: "https://example.com/page-1.xml")!
        let nextURL = URL(string: "https://example.com/page-2.xml")!

        XCTAssertEqual(pager.appendPage(firstPage, requestedURL: firstURL, nextPageURL: nextURL).count, 2)
        XCTAssertEqual(pager.appendPage(secondPage, requestedURL: nextURL, nextPageURL: nil).map(\.id), ["new"])
    }

    func testRepeatedRFC5005PageIsRejected() {
        var pager = PodcastFeedEpisodePager(batchSize: 20)
        let pageURL = URL(string: "https://example.com/page.xml")!

        XCTAssertEqual(pager.appendPage(drafts(count: 1), requestedURL: pageURL, nextPageURL: pageURL).count, 1)
        XCTAssertNil(pager.nextPageURL)
        XCTAssertTrue(pager.hasVisited(pageURL))
    }

    private func drafts(count: Int, ids: [String?]? = nil) -> [PodcastEpisodeDraft] {
        (0..<count).map { index in
            let guid: String?
            if let ids, ids.indices.contains(index) {
                guid = ids[index]
            } else {
                guid = "episode-\(index)"
            }
            return draft(guid: guid, enclosure: index)
        }
    }

    private func draft(guid: String?, enclosure: Int) -> PodcastEpisodeDraft {
        var raw: [String: Any] = [
            "title": "Episode \(enclosure)",
            "enclosure": [[
                "url": "https://example.com/episode-\(enclosure).mp3",
                "type": "audio/mpeg"
            ]]
        ]
        if let guid { raw["guid"] = guid }
        return PodcastEpisodeDraft(episodeData: raw)!
    }
}
