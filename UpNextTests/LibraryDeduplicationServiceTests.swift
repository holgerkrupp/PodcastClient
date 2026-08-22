import SwiftData
import XCTest
@testable import UpNext

final class LibraryDeduplicationServiceTests: XCTestCase {

    /// Builds the shape the CloudKit re-attach produced: the same feed present
    /// twice, each copy carrying its own episode rows, and a queue whose entries
    /// are spread across both copies.
    @MainActor
    private func makeDuplicatedLibrary() throws -> ModelContainer {
        let legacy = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let context = legacy.mainContext
        let feed = URL(string: "https://example.com/feed.xml")!

        func makePodcast(subscribed: Bool, guids: [String]) -> Podcast {
            let podcast = Podcast(feed: feed)
            context.insert(podcast)
            podcast.metaData?.isSubscribed = subscribed
            var episodes: [Episode] = []
            for guid in guids {
                let episode = Episode(
                    guid: guid,
                    title: "Episode \(guid)",
                    url: URL(string: "https://example.com/\(guid).mp3")!,
                    podcast: podcast
                )
                context.insert(episode)
                episodes.append(episode)
            }
            podcast.episodes = episodes
            return podcast
        }

        let original = makePodcast(subscribed: true, guids: ["a", "b", "c"])
        let duplicate = makePodcast(subscribed: false, guids: ["a", "b", "c"])

        // The duplicate's copy of "a" is the one that carries playback state.
        let duplicateA = duplicate.episodes!.first { $0.guid == "a" }!
        duplicateA.metaData?.completionDate = Date(timeIntervalSince1970: 1000)
        duplicateA.metaData?.totalListenTime = 600

        let originalA = original.episodes!.first { $0.guid == "a" }!
        originalA.metaData?.totalListenTime = 600

        let queue = Playlist()
        context.insert(queue)
        let queued = [original.episodes![1], duplicate.episodes![1], original.episodes![2]]
        var entries: [PlaylistEntry] = []
        for (index, episode) in queued.enumerated() {
            let entry = PlaylistEntry(episode: episode, order: index)
            context.insert(entry)
            entry.playlist = queue
            episode.playlist = [entry]
            entries.append(entry)
        }
        queue.items = entries
        try context.save()
        return legacy
    }

    @MainActor
    func testDryRunReportsWithoutChangingAnything() async throws {
        let legacy = try makeDuplicatedLibrary()
        let before = try legacy.mainContext.fetchCount(FetchDescriptor<Podcast>())

        let report = await LibraryDeduplicationService(legacyContainer: legacy)
            .run(dryRun: true)

        XCTAssertTrue(report.isDryRun)
        XCTAssertEqual(report.podcastGroups, 1)
        XCTAssertEqual(report.podcastsRemoved, 1)
        let after = try legacy.mainContext.fetchCount(FetchDescriptor<Podcast>())
        XCTAssertEqual(after, before, "dry run must not delete anything")
        XCTAssertEqual(
            try legacy.mainContext.fetchCount(FetchDescriptor<Episode>()),
            6,
            "dry run must not delete episodes"
        )
    }

    @MainActor
    func testCollapsesDuplicatePodcastsKeepingTheSubscribedCopy() async throws {
        let legacy = try makeDuplicatedLibrary()

        _ = await LibraryDeduplicationService(legacyContainer: legacy).run(dryRun: false)

        let podcasts = try legacy.mainContext.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.metaData?.isSubscribed, true)
    }

    /// The regression that matters most: `Podcast.episodes` cascades and
    /// `Episode.podcast` has no inverse, so a re-parent that forgets to remove
    /// the episode from the loser's array deletes it along with the loser.
    @MainActor
    func testSurvivingEpisodesAreNotCascadeDeletedWithTheDuplicatePodcast() async throws {
        let legacy = try makeDuplicatedLibrary()

        _ = await LibraryDeduplicationService(legacyContainer: legacy).run(dryRun: false)

        let episodes = try legacy.mainContext.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, 3, "one row per distinct guid must survive")
        XCTAssertEqual(Set(episodes.compactMap(\.guid)), ["a", "b", "c"])
        for episode in episodes {
            XCTAssertNotNil(episode.podcast, "survivors must stay attached to a podcast")
        }
    }

    @MainActor
    func testKeepsRichestPlaybackStateAndDoesNotSumListenTime() async throws {
        let legacy = try makeDuplicatedLibrary()

        _ = await LibraryDeduplicationService(legacyContainer: legacy).run(dryRun: false)

        let episodes = try legacy.mainContext.fetch(FetchDescriptor<Episode>())
        let merged = try XCTUnwrap(episodes.first { $0.guid == "a" })
        XCTAssertEqual(
            merged.metaData?.completionDate,
            Date(timeIntervalSince1970: 1000),
            "the copy carrying completion state must win"
        )
        XCTAssertEqual(
            merged.metaData?.totalListenTime,
            600,
            "duplicates are copies of one episode; listen time must not be summed"
        )
    }

    @MainActor
    func testPlaylistKeepsOneEntryPerEpisodeVisibleFromBothSides() async throws {
        let legacy = try makeDuplicatedLibrary()

        _ = await LibraryDeduplicationService(legacyContainer: legacy).run(dryRun: false)

        let playlist = try XCTUnwrap(
            try legacy.mainContext.fetch(FetchDescriptor<Playlist>()).first
        )
        let entries = try legacy.mainContext.fetch(FetchDescriptor<PlaylistEntry>())
        XCTAssertEqual(entries.count, 2, "the two copies of 'b' collapse to one entry")
        XCTAssertEqual(playlist.items?.count, 2, "playlist.items must see them")
        for entry in entries {
            XCTAssertEqual(
                entry.playlist?.id,
                playlist.id,
                "the unlinked back-reference must be written too"
            )
            XCTAssertNotNil(entry.episode)
        }
        // `items` is an unordered SwiftData relationship — `ordered` is the
        // accessor every reader uses, so that is what has to come out right.
        XCTAssertEqual(
            playlist.ordered.map(\.order),
            [0, 1],
            "order must be compacted with no gaps"
        )
        XCTAssertEqual(
            playlist.ordered.compactMap { $0.episode?.guid },
            ["b", "c"],
            "queue order must survive the merge"
        )
    }

    /// Entries reachable from neither `playlist.items` nor `entry.playlist` are
    /// the shape the CloudKit re-import left behind. They must be surfaced, and
    /// they must survive: they may be the only remaining copy of a lost queue.
    @MainActor
    func testOrphanedEntriesAreReportedAndNotDeleted() async throws {
        let legacy = try makeDuplicatedLibrary()
        let context = legacy.mainContext
        let episode = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Episode>()).first
        )
        let orphan = PlaylistEntry(episode: episode, order: 99)
        context.insert(orphan)
        orphan.playlist = nil
        try context.save()

        let report = await LibraryDeduplicationService(legacyContainer: legacy)
            .run(dryRun: false)

        XCTAssertEqual(report.orphanEntries, 1)
        XCTAssertEqual(report.orphanEntriesWithEpisode, 1)
        XCTAssertEqual(report.orphanDistinctEpisodes, 1)

        let surviving = try context.fetch(FetchDescriptor<PlaylistEntry>())
        XCTAssertTrue(
            surviving.contains { $0.id == orphan.id },
            "an orphaned entry must not be deleted by deduplication"
        )
    }

    /// The statistics are recomputed from `PlaySession` rows, so a duplicated
    /// session inflates every total no matter how often analytics are rebuilt.
    @MainActor
    func testCollapsesDuplicatePlaySessionsKeepingTheCompleteOne() async throws {
        let legacy = try makeDuplicatedLibrary()
        let context = legacy.mainContext
        let episode = try XCTUnwrap(try context.fetch(FetchDescriptor<Episode>()).first)
        let sharedID = UUID()
        let start = Date(timeIntervalSince1970: 5_000)

        let complete = PlaySession(id: sharedID)
        complete.episode = episode
        complete.startTime = start
        complete.endTime = start.addingTimeInterval(600)
        complete.startPosition = 0
        complete.endPosition = 600
        context.insert(complete)

        // Same session, re-imported without its end — the copy that must lose.
        let truncated = PlaySession(id: sharedID)
        truncated.episode = episode
        truncated.startTime = start
        context.insert(truncated)
        try context.save()

        let report = await LibraryDeduplicationService(legacyContainer: legacy)
            .run(dryRun: false)

        XCTAssertEqual(report.playSessionsRemoved, 1)
        let sessions = try context.fetch(FetchDescriptor<PlaySession>())
            .filter { $0.id == sharedID }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            sessions.first?.endTime,
            start.addingTimeInterval(600),
            "the complete copy must survive"
        )
    }

    @MainActor
    func testIsIdempotent() async throws {
        let legacy = try makeDuplicatedLibrary()
        let service = LibraryDeduplicationService(legacyContainer: legacy)

        _ = await service.run(dryRun: false)
        let second = await service.run(dryRun: false)

        XCTAssertEqual(second.podcastsRemoved, 0)
        XCTAssertEqual(second.episodesRemoved, 0)
        XCTAssertEqual(second.playlistEntriesRemoved, 0)
    }
}
