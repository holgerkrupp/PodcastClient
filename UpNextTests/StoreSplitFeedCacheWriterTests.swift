import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitFeedCacheWriterTests: XCTestCase {

    @MainActor
    private func makeContainers() throws -> (legacy: ModelContainer, cache: ModelContainer) {
        (
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    @discardableResult
    private func makePodcast(
        in container: ModelContainer,
        feed: String,
        episodeGUIDs: [String]
    ) throws -> Podcast {
        let context = container.mainContext
        let podcast = Podcast(feed: URL(string: feed)!)
        podcast.title = "Example"
        context.insert(podcast)
        for guid in episodeGUIDs {
            let episode = Episode(
                guid: guid,
                title: "Title \(guid)",
                publishDate: Date(timeIntervalSince1970: 1_000),
                url: URL(string: "\(feed)/\(guid).mp3")!,
                podcast: podcast,
                duration: 120
            )
            context.insert(episode)
        }
        try context.save()
        return podcast
    }

    private func cacheCounts(
        _ container: ModelContainer
    ) -> (podcasts: Int, episodes: Int) {
        let context = ModelContext(container)
        return (
            (try? context.fetchCount(FetchDescriptor<CachedPodcast>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<CachedEpisode>())) ?? -1
        )
    }

    @MainActor
    func testBootstrapCopiesFeedAndIsIdempotent() throws {
        let (legacy, cache) = try makeContainers()
        try makePodcast(in: legacy, feed: "https://example.com/a", episodeGUIDs: ["e1", "e2", "e3"])

        let firstPass = StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
            legacyContainer: legacy, cacheContainer: cache, limit: 10
        )
        XCTAssertEqual(firstPass, 1)
        var counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)

        // Presence of the CachedPodcast is the checkpoint: a second pass is a no-op.
        let secondPass = StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
            legacyContainer: legacy, cacheContainer: cache, limit: 10
        )
        XCTAssertEqual(secondPass, 0)
        counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)
    }

    @MainActor
    func testUpsertPrunesRemovedEpisodes() throws {
        let (legacy, cache) = try makeContainers()
        let feed = "https://example.com/b"
        let podcast = try makePodcast(in: legacy, feed: feed, episodeGUIDs: ["e1", "e2", "e3"])

        StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: podcast.feed!, legacyContainer: legacy, cacheContainer: cache
        )
        XCTAssertEqual(cacheCounts(cache).episodes, 3)

        // Remove one episode from the legacy feed, then re-run the dual-write.
        let context = legacy.mainContext
        if let toDelete = podcast.episodes?.first(where: { $0.guid == "e2" }) {
            context.delete(toDelete)
        }
        try context.save()

        StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: podcast.feed!, legacyContainer: legacy, cacheContainer: cache
        )
        let counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 2, "Stale cache episode should be pruned")
    }
}
