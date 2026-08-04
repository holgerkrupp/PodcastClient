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

        // The current cache projection version is the checkpoint.
        let secondPass = StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
            legacyContainer: legacy, cacheContainer: cache, limit: 10
        )
        XCTAssertEqual(secondPass, 0)
        counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)
    }

    @MainActor
    func testBootstrapUpgradesAnExistingPhaseTwoCacheProjectionOnce() throws {
        let (legacy, cache) = try makeContainers()
        try makePodcast(in: legacy, feed: "https://example.com/upgrade", episodeGUIDs: ["e1"])

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            1
        )

        let context = cache.mainContext
        let cachedPodcast = try XCTUnwrap(
            context.fetch(FetchDescriptor<CachedPodcast>()).first
        )
        cachedPodcast.cacheSchemaVersion = 1
        try context.save()

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            1
        )
        let verification = ModelContext(cache)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<CachedPodcast>()).first?.cacheSchemaVersion,
            StoreSplitFeedCacheWriter.currentCacheSchemaVersion
        )
        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            0
        )
    }

    @MainActor
    func testUpsertCopiesPhaseThreeSupplementalCacheData() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/details",
            episodeGUIDs: ["e1"]
        )
        let context = legacy.mainContext
        let episode = try XCTUnwrap(podcast.episodes?.first)

        let chapter = Marker(
            start: 12,
            title: "Introduction",
            type: .podlove,
            duration: 30
        )
        chapter.episode = episode
        episode.chapters = [chapter]
        context.insert(chapter)

        let line = TranscriptLineAndTime(
            speaker: "Host",
            text: "Welcome",
            startTime: 1.5,
            endTime: 3
        )
        line.episode = episode
        episode.transcriptLines = [line]
        context.insert(line)

        context.insert(
            TranscriptionRecord(
                episodeURL: try XCTUnwrap(episode.url),
                episodeTitle: episode.title,
                podcastTitle: podcast.title,
                localeIdentifier: "en_US",
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: Date(timeIntervalSince1970: 20),
                audioDuration: 120
            )
        )
        try context.save()

        StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        )

        let verification = ModelContext(cache)
        let cachedPodcast = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertEqual(cachedPodcast.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedChapter>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedTranscriptLine>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedTranscriptionRecord>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedDownloadRecord>()), 1)

        let cachedChapter = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedChapter>()).first
        )
        XCTAssertEqual(cachedChapter.title, "Introduction")
        XCTAssertEqual(cachedChapter.typeRawValue, MarkerType.podlove.rawValue)
        let cachedLine = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedTranscriptLine>()).first
        )
        XCTAssertEqual(cachedLine.speaker, "Host")
        XCTAssertEqual(cachedLine.text, "Welcome")
    }

    @MainActor
    func testFeedAliasUpsertIsNormalizedAndIdempotent() throws {
        let (_, cache) = try makeContainers()
        let oldURL = URL(string: "HTTPS://Example.COM:443/feed#old")!
        let newURL = URL(string: "https://example.com/new-feed")!

        StoreSplitFeedCacheWriter.upsertFeedAlias(
            from: oldURL,
            to: newURL,
            reason: .permanentRedirect,
            cacheContainer: cache
        )
        StoreSplitFeedCacheWriter.upsertFeedAlias(
            from: oldURL,
            to: newURL,
            reason: .explicitSwitch,
            cacheContainer: cache
        )

        let context = ModelContext(cache)
        let aliases = try context.fetch(FetchDescriptor<FeedAlias>())
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases[0].oldFeedURL, "https://example.com/feed")
        XCTAssertEqual(aliases[0].newFeedURL, "https://example.com/new-feed")
        XCTAssertEqual(aliases[0].reasonRawValue, FeedAliasReason.explicitSwitch.rawValue)
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
        XCTAssertEqual(
            try ModelContext(cache).fetchCount(FetchDescriptor<CachedDownloadRecord>()),
            2,
            "Supplemental cache rows for removed episodes should also be pruned"
        )
    }
}
