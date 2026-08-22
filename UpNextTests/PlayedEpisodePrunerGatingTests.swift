import SwiftData
import XCTest
@testable import UpNext

/// The pruner ships disabled after it emptied a live queue, and it still runs at
/// every launch and after every import. These pin that being disabled costs
/// nothing rather than costing a full scan.
final class PlayedEpisodePrunerGatingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PlayedEpisodePlaylistPruner.isEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PlayedEpisodePlaylistPruner.isEnabledKey)
        super.tearDown()
    }

    func testDisabledPrunerRemovesNothing() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(legacy)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        context.insert(podcast)
        let episode = Episode(
            guid: "played-1",
            title: "Played",
            url: URL(string: "https://example.com/played.mp3")!,
            podcast: podcast
        )
        context.insert(episode)
        episode.metaData?.completionDate = Date(timeIntervalSince1970: 2_000)
        let playlist = Playlist()
        context.insert(playlist)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        entry.playlist = playlist
        entry.dateAdded = Date(timeIntervalSince1970: 1_000)
        try context.save()

        XCTAssertFalse(PlayedEpisodePlaylistPruner.isEnabled)
        let result = await PlayedEpisodePlaylistPruner(legacyContainer: legacy).prune()

        XCTAssertEqual(result.removedEntryCount, 0)
        XCTAssertEqual(
            try ModelContext(legacy).fetch(FetchDescriptor<PlaylistEntry>()).count, 1,
            "the entry matches the stale-membership rule; only the disabled flag protects it"
        )
    }

    /// The rule itself is unchanged — the early-out must not be mistaken for
    /// having softened it.
    func testStaleMembershipRuleIsUnchanged() {
        let completedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(PlayedEpisodeQueuePolicy.isStaleQueueMembership(
            isPlayed: true,
            completionDate: completedAt,
            addedAt: completedAt.addingTimeInterval(-1)
        ))
        XCTAssertFalse(PlayedEpisodeQueuePolicy.isStaleQueueMembership(
            isPlayed: true,
            completionDate: completedAt,
            addedAt: completedAt.addingTimeInterval(1)
        ))
        XCTAssertFalse(PlayedEpisodeQueuePolicy.isStaleQueueMembership(
            isPlayed: false,
            completionDate: nil,
            addedAt: nil
        ))
    }
}
