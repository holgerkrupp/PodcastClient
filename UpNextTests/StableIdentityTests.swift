import XCTest
@testable import UpNext

final class StableIdentityTests: XCTestCase {
    func testEpisodeIdentityPrefersGUIDWithinFeed() {
        let feedURL = URL(string: "https://example.com/podcast.xml")!
        let identity = EpisodeStableIdentity.make(
            feedURL: feedURL,
            episodeGUID: "episode-123",
            enclosureURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            episodeURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            linkURL: URL(string: "https://example.com/episode")!
        )

        XCTAssertEqual(identity.feedURL, PodcastFeedIdentity.normalizedFeedURLString(feedURL))
        XCTAssertEqual(identity.episodeID, "episode-123")
        XCTAssertEqual(identity.key, "\(PodcastFeedIdentity.normalizedFeedURLString(feedURL))|episode-123")
    }

    func testEpisodeIdentityFallsBackToEnclosureURLWhenGUIDMissing() {
        let identity = EpisodeStableIdentity.make(
            feedURL: URL(string: "https://example.com/podcast.xml")!,
            episodeGUID: nil,
            enclosureURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            episodeURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            linkURL: nil
        )

        XCTAssertEqual(identity.episodeID, "https://cdn.example.com/audio.mp3")
    }

    func testEpisodeIdentityFallsBackToHashWhenAllIdentifiersMissing() {
        let identity = EpisodeStableIdentity.make(
            feedURL: URL(string: "https://example.com/podcast.xml")!,
            episodeGUID: nil,
            enclosureURL: nil,
            episodeURL: nil,
            linkURL: nil
        )

        XCTAssertEqual(identity.feedURL, PodcastFeedIdentity.normalizedFeedURLString(URL(string: "https://example.com/podcast.xml")!))
        XCTAssertEqual(identity.episodeID.count, 64)
    }

    func testMergePolicyPrefersNewestIncomingRecord() {
        let existing = Date(timeIntervalSince1970: 1_000)
        let incoming = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(StoreSplitMergePolicy.prefersIncoming(existingUpdatedAt: existing, incomingUpdatedAt: incoming))
        XCTAssertFalse(StoreSplitMergePolicy.prefersIncoming(existingUpdatedAt: incoming, incomingUpdatedAt: existing))
    }

    func testQueueEntriesSortBySortIndex() {
        let entries = [
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-3", sortIndex: 3),
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-1", sortIndex: 1),
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-2", sortIndex: 2)
        ]

        XCTAssertEqual(entries.sorted { $0.sortIndex < $1.sortIndex }.map(\.episodeID), ["episode-1", "episode-2", "episode-3"])
    }
}
