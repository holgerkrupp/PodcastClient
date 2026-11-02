import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class PlaybackSessionSyncTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([PlaybackSessionSync.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func snapshot(url: String, position: Double) -> PlaybackSessionSnapshot {
        PlaybackSessionSnapshot(
            identity: EpisodeStableIdentity.make(
                feedURL: URL(string: "https://example.com/feed.xml"),
                episodeGUID: url,
                enclosureURL: URL(string: url),
                episodeURL: URL(string: url),
                linkURL: nil,
                title: "Episode",
                publishDate: nil
            ),
            episodeURL: url,
            position: position,
            isPlaying: false
        )
    }

    /// The copy keeps a feed's newest subscription date, so a hidden duplicate
    /// must not be the one holding it.
    func testHidingADuplicateLeavesTheFeedSubscribedForTheLibraryCopy() async throws {
        let library = try ModelContainer(
            for: Podcast.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(library)
        let feed = try XCTUnwrap(URL(string: "https://example.com/duplicate.xml"))
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let refreshed = Podcast(feed: feed)
        let duplicate = Podcast(feed: feed)
        let refreshedMetadata = PodcastMetaData()
        refreshedMetadata.subscriptionDate = older
        refreshedMetadata.lastRefresh = newer
        let duplicateMetadata = PodcastMetaData()
        duplicateMetadata.subscriptionDate = newer
        duplicateMetadata.lastRefresh = older
        refreshed.metaData = refreshedMetadata
        duplicate.metaData = duplicateMetadata
        context.insert(refreshed)
        context.insert(duplicate)
        try context.save()

        let userState = try makeContainer()
        let hidden = await StoreSplitUserStateImporter.hideDuplicateLibraryPodcasts(
            legacyContainer: library,
            userStateContainer: userState
        )

        XCTAssertEqual(hidden, 1)
        let podcasts = try ModelContext(library).fetch(FetchDescriptor<Podcast>())
        let loser = try XCTUnwrap(podcasts.first { $0.metaData?.isSubscribed == false })
        let survivor = try XCTUnwrap(podcasts.first { $0.metaData?.isSubscribed != false })
        XCTAssertNil(loser.metaData?.subscriptionDate)
        XCTAssertNotNil(survivor.metaData?.subscriptionDate)
    }

    func testDeletingADuplicateKeepsTheSameFeedSubscribed() async throws {
        let library = try ModelContainer(
            for: Podcast.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(library)
        let feed = try XCTUnwrap(URL(string: "https://example.com/deleted-duplicate.xml"))
        let kept = Podcast(feed: feed)
        kept.title = "Kept"
        let duplicate = Podcast(feed: feed)
        duplicate.title = "Duplicate"
        context.insert(kept)
        context.insert(duplicate)
        for number in 0..<60 {
            let episode = Episode(
                guid: "episode-\(number)",
                title: "Episode \(number)",
                url: try XCTUnwrap(URL(string: "https://example.com/\(number).mp3")),
                podcast: duplicate
            )
            context.insert(episode)
        }
        try context.save()

        try await PodcastModelActor(modelContainer: library).deletePodcast(duplicate.persistentModelID)

        let verification = ModelContext(library)
        let remaining = try verification.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(remaining.map(\.title), ["Kept"])
        XCTAssertNotEqual(remaining.first?.metaData?.isSubscribed, false)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testDeletingAPodcastKeepsItsHistory() async throws {
        let library = try ModelContainer(
            for: Podcast.self, PlaySession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(library)
        let feed = try XCTUnwrap(URL(string: "https://example.com/history-\(UUID().uuidString).xml"))
        let podcast = Podcast(feed: feed)
        podcast.title = "Gone Podcast"
        context.insert(podcast)
        let episode = Episode(
            title: "Gone Episode",
            url: try XCTUnwrap(URL(string: "https://example.com/gone.mp3")),
            podcast: podcast
        )
        context.insert(episode)
        let session = PlaySession(id: UUID(), episode: episode, startTime: Date(timeIntervalSince1970: 1_000))
        session.podcastName = "Gone Podcast"
        context.insert(session)
        try context.save()

        // A second copy keeps this test away from the shared subscription stores.
        let otherCopy = Podcast(feed: feed)
        context.insert(otherCopy)
        try context.save()
        try await PodcastModelActor(modelContainer: library).deletePodcast(podcast.persistentModelID)

        let kept = try XCTUnwrap(try ModelContext(library).fetch(FetchDescriptor<PlaySession>()).first)
        XCTAssertNil(kept.episode)
        XCTAssertEqual(kept.historyEpisodeTitle, "Gone Episode")
        XCTAssertEqual(kept.historyPodcastFeed, feed)
        XCTAssertEqual(kept.podcastName, "Gone Podcast")
    }

    func testArchivedCoverLoadsFromItsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let source = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.8))
        let feed = try XCTUnwrap(URL(string: "https://example.com/archived.xml"))

        await PodcastCoverArchive(directory: directory).store(data, feed: feed, title: "Archived")

        let files = PodcastCoverArchive.coverFiles(in: directory)
        let file = try XCTUnwrap(files.byFeed[feed.absoluteString])
        XCTAssertEqual(files.byTitle["Archived"], file)
        let loaded = await ImageLoaderAndCache.loadUIImage(from: file)
        XCTAssertNotNil(loaded)
    }

    func testHistoryForADeletedPodcastDoesNotFetchItsFeed() async throws {
        let library = try ModelContainer(
            for: Podcast.self, PlaySession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let userState = try ModelContainer(
            for: ListeningHistorySync.self, SubscriptionSync.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(userState)
        context.insert(ListeningHistorySync(
            id: "history",
            feedURL: "https://example.com/deleted.xml",
            episodeID: "guid:gone",
            podcastName: "Gone Podcast",
            episodeTitle: "Gone Episode",
            sourceDeviceID: "other",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            listenedSeconds: 600
        ))
        try context.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: library,
            userStateContainer: userState,
            changedStreams: [.listeningHistory]
        )

        XCTAssertTrue(result.feedsToBootstrap.isEmpty)
        let session = try XCTUnwrap(try ModelContext(library).fetch(FetchDescriptor<PlaySession>()).first)
        XCTAssertEqual(session.historyEpisodeTitle, "Gone Episode")
        XCTAssertEqual(session.podcastName, "Gone Podcast")
    }

    func testNewestRemoteSessionIgnoresThisDevice() async throws {
        let container = try makeContainer()
        let writer = PlaybackSessionSyncWriter(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_000)
        try await writer.upsert(snapshot(url: "https://example.com/older.mp3", position: 10), at: start, deviceID: "older")
        try await writer.upsert(snapshot(url: "https://example.com/newer.mp3", position: 20), at: start.addingTimeInterval(10), deviceID: "newer")
        try await writer.upsert(snapshot(url: "https://example.com/mine.mp3", position: 30), at: start.addingTimeInterval(20), deviceID: "me")

        let session = PlaybackSessionSyncPolicy.newestRemoteSession(in: container, excludingDeviceID: "me")

        XCTAssertEqual(session?.episodeURL, "https://example.com/newer.mp3")
        XCTAssertEqual(session?.position, 20)
    }

    /// A queued snapshot can drain after a newer direct write from the same device.
    func testOlderQueuedSnapshotDoesNotReplaceNewerWrite() async throws {
        let container = try makeContainer()
        let writer = PlaybackSessionSyncWriter(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_000)
        try await writer.upsert(snapshot(url: "https://example.com/a.mp3", position: 50), at: start.addingTimeInterval(10), deviceID: "device")
        try await writer.upsert(snapshot(url: "https://example.com/a.mp3", position: 5), at: start, deviceID: "device")

        let session = PlaybackSessionSyncPolicy.newestRemoteSession(in: container, excludingDeviceID: "me")

        XCTAssertEqual(session?.position, 50)
    }

    /// A rewind on another device has a lower position but is still followed.
    func testFollowingDependsOnTimeNotPosition() {
        let handled = Date(timeIntervalSince1970: 1_000)
        let rewound = RemotePlaybackSession(
            episodeURL: "https://example.com/a.mp3",
            position: 1,
            isPlaying: false,
            updatedAt: handled.addingTimeInterval(1)
        )
        let stale = RemotePlaybackSession(
            episodeURL: "https://example.com/a.mp3",
            position: 9_000,
            isPlaying: false,
            updatedAt: handled
        )

        XCTAssertTrue(PlaybackSessionSyncPolicy.shouldFollow(rewound, handledThrough: handled))
        XCTAssertFalse(PlaybackSessionSyncPolicy.shouldFollow(stale, handledThrough: handled))
        XCTAssertTrue(PlaybackSessionSyncPolicy.shouldFollow(stale, handledThrough: nil))
    }
}
