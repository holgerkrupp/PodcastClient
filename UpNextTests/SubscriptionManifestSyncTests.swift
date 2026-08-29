import XCTest
import SwiftData
@testable import UpNext

final class SubscriptionManifestSyncTests: XCTestCase {
    private let feed = URL(string: "https://example.com/feed.xml")!

    private func makeContainer() throws -> ModelContainer {
        // CloudKit mirroring is off: the test host has the app's iCloud
        // entitlements, and an in-memory store that tries to mirror tears itself
        // down on a simulator with no account.
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            Marker.self,
            Bookmark.self,
            RateSegment.self,
            PlaySession.self,
            ListeningStat.self,
            PlaySessionSummary.self,
            TranscriptionRecord.self,
            configurations: configuration
        )
    }

    @discardableResult
    private func insertPodcastWithEpisodes(in context: ModelContext) -> Podcast {
        let podcast = Podcast(feed: feed)
        podcast.title = "Example"
        context.insert(podcast)

        let dates: [(String, TimeInterval)] = [
            ("older", 1_000),
            ("newest", 3_000),
            ("middle", 2_000)
        ]

        for (name, timestamp) in dates {
            let episode = Episode(
                guid: name,
                title: name,
                publishDate: Date(timeIntervalSince1970: timestamp),
                url: URL(string: "https://example.com/\(name).mp3")!
            )
            context.insert(episode)
            episode.podcast = podcast
        }

        try? context.save()
        return podcast
    }

    func testManifestReportsNewestEpisodeFromTheStore() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertPodcastWithEpisodes(in: context)

        let manifest = await SubscriptionManifestModelActor(modelContainer: container)
            .makeManifest()

        let entry = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(entry.lastEpisodeDate, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(entry.lastEpisodeURL, "https://example.com/newest.mp3")
    }

    func testManifestReusesPublishedEpisodeWhileTheFeedIsUnchanged() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = insertPodcastWithEpisodes(in: context)
        let lastRefresh = Date(timeIntervalSince1970: 5_000)
        podcast.metaData?.lastRefresh = lastRefresh
        try context.save()

        let cached = SubscriptionManifestEntry(
            feedURL: feed.absoluteString,
            title: "Example",
            author: nil,
            description: nil,
            artworkURL: nil,
            lastRefresh: lastRefresh,
            lastEpisodeDate: Date(timeIntervalSince1970: 9_000),
            lastEpisodeURL: "https://example.com/cached.mp3"
        )
        let previousEntries = [feed.absoluteString: cached]
        let actor = SubscriptionManifestModelActor(modelContainer: container)

        let reusedManifest = await actor.makeManifest(previousEntries: previousEntries)
        let reused = try XCTUnwrap(reusedManifest.entries.first)
        XCTAssertEqual(reused.lastEpisodeURL, "https://example.com/cached.mp3")

        // A refresh invalidates the cached pointer, so the store decides again.
        podcast.metaData?.lastRefresh = Date(timeIntervalSince1970: 6_000)
        try context.save()

        let refreshedManifest = await actor.makeManifest(previousEntries: previousEntries)
        let refreshed = try XCTUnwrap(refreshedManifest.entries.first)
        XCTAssertEqual(refreshed.lastEpisodeURL, "https://example.com/newest.mp3")
    }

    func testManifestOmitsAFeedDeletedAfterItWasSubscribed() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = insertPodcastWithEpisodes(in: context)
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        try context.save()

        let actor = SubscriptionManifestModelActor(modelContainer: container)
        let deletedFeeds = [feed.absoluteString: Date(timeIntervalSince1970: 2_000)]

        let afterDeletion = await actor.makeManifest(deletedFeeds: deletedFeeds)
        XCTAssertTrue(afterDeletion.entries.isEmpty)

        // Subscribing again out-dates the deletion and publishes the feed.
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 3_000)
        try context.save()

        let afterResubscribing = await actor.makeManifest(deletedFeeds: deletedFeeds)
        XCTAssertEqual(afterResubscribing.entries.count, 1)
    }

    func testRestoreSkipsAFeedDeletedAfterTheManifestWasWritten() async throws {
        let container = try makeContainer()
        let entry = SubscriptionManifestEntry(
            feedURL: feed.absoluteString,
            title: "Example",
            author: nil,
            description: nil,
            artworkURL: nil,
            lastRefresh: nil,
            lastEpisodeDate: nil,
            lastEpisodeURL: nil
        )
        let manifest = SubscriptionManifest(
            updatedAt: Date(timeIntervalSince1970: 1_000),
            entries: [entry]
        )
        let actor = SubscriptionManifestModelActor(modelContainer: container)

        let feeds = await actor.restore(
            manifest,
            deletedFeeds: [feed.absoluteString: Date(timeIntervalSince1970: 2_000)]
        )

        XCTAssertTrue(feeds.isEmpty)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
    }

    func testRestoreAcceptsAManifestWrittenAfterTheDeletion() async throws {
        let container = try makeContainer()
        let entry = SubscriptionManifestEntry(
            feedURL: feed.absoluteString,
            title: "Example",
            author: nil,
            description: nil,
            artworkURL: nil,
            lastRefresh: nil,
            lastEpisodeDate: nil,
            lastEpisodeURL: nil
        )
        let manifest = SubscriptionManifest(
            updatedAt: Date(timeIntervalSince1970: 3_000),
            entries: [entry]
        )
        let actor = SubscriptionManifestModelActor(modelContainer: container)

        let feeds = await actor.restore(
            manifest,
            deletedFeeds: [feed.absoluteString: Date(timeIntervalSince1970: 2_000)]
        )

        XCTAssertEqual(feeds, [feed])
    }
}
