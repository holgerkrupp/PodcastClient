import Foundation
import XCTest
@testable import UpNext

final class PlaybackSpeedLoadTokenTests: XCTestCase {
    func testMatchingPreferenceReadCanBeApplied() {
        let feed = URL(string: "https://example.com/feed.xml")!
        let token = PlaybackSpeedLoadToken(
            feedURL: feed,
            requestID: 4,
            selectionRevision: 8
        )

        XCTAssertTrue(token.isCurrent(
            feedURL: feed,
            requestID: 4,
            selectionRevision: 8
        ))
    }

    func testAnEarlierReadCannotOverrideANewerSpeedSelection() {
        let feed = URL(string: "https://example.com/feed.xml")!
        let token = PlaybackSpeedLoadToken(
            feedURL: feed,
            requestID: 4,
            selectionRevision: 8
        )

        // The user selected 1.5× while a saved 1.0× preference was loading.
        XCTAssertFalse(token.isCurrent(
            feedURL: feed,
            requestID: 4,
            selectionRevision: 9
        ))
    }

    func testOldPodcastReadCannotChangeNewPodcastSpeed() {
        let feedA = URL(string: "https://example.com/a.xml")!
        let feedB = URL(string: "https://example.com/b.xml")!
        let token = PlaybackSpeedLoadToken(
            feedURL: feedA,
            requestID: 5,
            selectionRevision: 2
        )

        XCTAssertFalse(token.isCurrent(
            feedURL: feedB,
            requestID: 5,
            selectionRevision: 2
        ))
    }

    func testNewerPreferenceReadSupersedesAnOlderRequest() {
        let feed = URL(string: "https://example.com/feed.xml")!
        let token = PlaybackSpeedLoadToken(
            feedURL: feed,
            requestID: 3,
            selectionRevision: 7
        )

        XCTAssertFalse(token.isCurrent(
            feedURL: feed,
            requestID: 4,
            selectionRevision: 7
        ))
    }
}
