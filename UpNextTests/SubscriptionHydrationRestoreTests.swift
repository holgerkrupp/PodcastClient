import SwiftData
import XCTest
@testable import UpNext

/// #483 / #443: prioritized, bounded, incremental second-device restore and
/// the readiness value the Queue and Settings show.
final class SubscriptionHydrationRestoreTests: XCTestCase {
    private typealias Scheduler = SubscriptionHydrationScheduler

    // MARK: Priority

    func testReferencePrioritiesRankResumeThenQueueHeadThenQueueThenPlaylists() {
        let priorities = Scheduler.ReferencePriorities(
            currentFeeds: ["https://example.com/current.xml"],
            queueFeedsInOrder: [
                "https://example.com/head-1.xml",
                "https://example.com/head-2.xml",
                "https://example.com/current.xml",
                "https://example.com/tail.xml"
            ],
            playlistFeeds: ["https://example.com/playlist.xml", "https://example.com/tail.xml"],
            queueHeadCount: 2
        )
        func rank(_ feed: String) -> Scheduler.Priority? {
            priorities.priority(for: URL(string: feed)!)
        }
        XCTAssertEqual(rank("https://example.com/current.xml"), .currentEpisode)
        XCTAssertEqual(rank("https://example.com/head-1.xml"), .queueHead)
        XCTAssertEqual(rank("https://example.com/head-2.xml"), .queueHead)
        // A feed keeps its most urgent rank.
        XCTAssertEqual(rank("https://example.com/tail.xml"), .queue)
        XCTAssertEqual(rank("https://example.com/playlist.xml"), .manualPlaylist)
        // Feed identity uses comparison keys, not exact strings.
        XCTAssertEqual(rank("HTTPS://EXAMPLE.COM/head-1.xml"), .queueHead)
        XCTAssertNil(rank("https://example.com/unrelated.xml"))

        let requests = [
            "https://example.com/unrelated.xml",
            "https://example.com/playlist.xml",
            "https://example.com/tail.xml",
            "https://example.com/current.xml",
            "https://example.com/head-2.xml"
        ].map { (key: $0, feed: URL(string: $0)!) }
        let ordered = Scheduler.orderedRequests(requests, priorities: priorities)
        XCTAssertEqual(ordered.map(\.key), [
            "https://example.com/current.xml",
            "https://example.com/head-2.xml",
            "https://example.com/tail.xml",
            "https://example.com/playlist.xml",
            "https://example.com/unrelated.xml"
        ])
        XCTAssertEqual(ordered.last?.priority, .otherReference)
    }

    @MainActor
    func testReferencePrioritiesReadQueueOrderAndPlaylistsFromUserState() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let context = userState.mainContext
        for (index, feed) in ["q0", "q1", "q2", "q3", "q4"].enumerated() {
            // Inserted out of order; sortIndex decides the queue head.
            context.insert(PlaylistEntrySync(
                playlistID: Playlist.defaultQueueSyncID,
                feedURL: "https://example.com/\(feed).xml",
                episodeID: "e\(index)",
                sortIndex: 4 - index
            ))
        }
        context.insert(PlaylistEntrySync(
            playlistID: Playlist.defaultQueueSyncID,
            feedURL: "https://example.com/deleted.xml",
            episodeID: "gone",
            sortIndex: 0,
            isDeleted: true,
            deletedAt: .now
        ))
        context.insert(PlaylistEntrySync(
            playlistID: UUID().uuidString,
            feedURL: "https://example.com/playlist.xml",
            episodeID: "p",
            sortIndex: 0
        ))
        try context.save()

        let priorities = Scheduler.referencePriorities(userState: userState)
        func rank(_ name: String) -> Scheduler.Priority? {
            priorities.priority(for: URL(string: "https://example.com/\(name).xml")!)
        }
        XCTAssertEqual(rank("q4"), .queueHead)
        XCTAssertEqual(rank("q3"), .queueHead)
        XCTAssertEqual(rank("q2"), .queueHead)
        XCTAssertEqual(rank("q1"), .queue)
        XCTAssertEqual(rank("q0"), .queue)
        XCTAssertEqual(rank("playlist"), .manualPlaylist)
        XCTAssertNil(rank("deleted"))
    }

    @MainActor
    func testDueStubsReferencedByTheQueueAreSelectedFirst() async throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feeds = ["a", "b", "c", "d"].map { URL(string: "https://example.com/stub-\($0).xml")! }
        for feed in feeds {
            userState.mainContext.insert(SubscriptionSync(feedURL: feed.absoluteString))
        }
        try userState.mainContext.save()
        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: library,
            userStateContainer: userState,
            changedStreams: [.subscriptions],
            cursorSuiteName: nil
        )

        let priorities = Scheduler.ReferencePriorities(
            currentFeeds: [],
            queueFeedsInOrder: [feeds[3].absoluteString],
            playlistFeeds: [feeds[2].absoluteString]
        )
        XCTAssertEqual(Scheduler.dueFeeds(in: library, limit: 10), feeds)
        XCTAssertEqual(
            Scheduler.dueFeeds(in: library, limit: 2, priorities: priorities),
            [feeds[3], feeds[2]]
        )
    }

    // MARK: Bounded concurrency

    private actor ConcurrencyProbe {
        private(set) var current = 0
        private(set) var maximum = 0
        private(set) var finished: [Int] = []

        func enter() {
            current += 1
            maximum = max(maximum, current)
        }

        func leave(_ item: Int) {
            current -= 1
            finished.append(item)
        }
    }

    @MainActor
    func testBoundedPoolRespectsLimitAndASlowOrFailingFeedDoesNotBlockOthers() async {
        let probe = ConcurrencyProbe()
        var queue = Array(0..<8)
        var outcomes: [Int: Bool] = [:]
        await Scheduler.runBounded(
            maxConcurrent: 3,
            next: { queue.isEmpty ? nil : queue.removeFirst() },
            shouldContinue: { true },
            operation: { @Sendable (item: Int) async -> Bool in
                await probe.enter()
                if item == 0 {
                    // A slow feed: holds its slot until every other feed is done.
                    for _ in 0..<500 {
                        if await probe.finished.count == 7 { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                await probe.leave(item)
                // Item 3 is malformed/unauthorized.
                return item != 3
            },
            completed: { (item: Int, succeeded: Bool) in outcomes[item] = succeeded }
        )
        let maximum = await probe.maximum
        let finished = await probe.finished
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertGreaterThanOrEqual(maximum, 2, "fetches should overlap")
        XCTAssertEqual(outcomes.count, 8)
        XCTAssertEqual(outcomes[3], false)
        XCTAssertEqual(outcomes.values.filter { $0 }.count, 7)
        XCTAssertEqual(finished.last, 0, "the slow feed must not hold back the others")
    }

    @MainActor
    func testBoundedPoolPullsLateHigherPriorityWorkAndStopsWhenAsked() async {
        var queue = [10, 11, 12]
        var started: [Int] = []
        var completedCount = 0
        await Scheduler.runBounded(
            maxConcurrent: 1,
            next: {
                // Work that arrives mid-run is served before older work.
                if started.count == 1 { queue.insert(1, at: 0) }
                guard queue.isEmpty == false else { return nil }
                let item = queue.removeFirst()
                started.append(item)
                return item
            },
            shouldContinue: { completedCount < 3 },
            operation: { @Sendable (item: Int) async -> Int in item },
            completed: { (_: Int, _: Int) in completedCount += 1 }
        )
        XCTAssertEqual(started, [10, 1, 11])
    }

    // MARK: Incremental publication

    @MainActor
    func testFeedCommitPublishesItsQueueEntriesInOrderWithoutTouchingOthers() async throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)

        let presentPodcast = Podcast(feed: URL(string: "https://example.com/present.xml")!)
        let present = Episode(
            guid: "present-b",
            title: "B",
            url: URL(string: "https://example.com/b.mp3")!,
            podcast: presentPodcast
        )
        presentPodcast.episodes = [present]
        library.mainContext.insert(presentPodcast)
        library.mainContext.insert(Playlist())
        try library.mainContext.save()

        // The late feed is not in the library yet; only its identities exist.
        let lateFeed = URL(string: "https://example.com/late.xml")!
        let latePodcast = Podcast(feed: lateFeed)
        let lateA = Episode(guid: "late-a", title: "A", url: URL(string: "https://example.com/a.mp3")!, podcast: latePodcast)
        let lateC = Episode(guid: "late-c", title: "C", url: URL(string: "https://example.com/c.mp3")!, podcast: latePodcast)

        let context = userState.mainContext
        context.insert(PlaylistSync(
            id: Playlist.defaultQueueSyncID,
            title: Playlist.defaultQueueTitle,
            symbolName: Playlist.defaultQueueSymbolName,
            sortIndex: 0,
            kindRawValue: Playlist.Kind.manual.rawValue
        ))
        for (index, episode) in [lateA, present, lateC].enumerated() {
            let identity = episode.stableEpisodeIdentity
            context.insert(PlaylistEntrySync(
                playlistID: Playlist.defaultQueueSyncID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: index
            ))
        }
        try context.save()

        let first = await ModelContainerManager.applyHydratedPlaylistMembership(
            runtime: library, userState: userState, cache: nil
        )
        XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(first.playlistFeedsToBootstrap.map(PodcastFeedIdentity.normalizedFeedURLString),
                       [PodcastFeedIdentity.normalizedFeedURLString(lateFeed)])
        let partial = try queueGUIDs(in: library)
        XCTAssertEqual(partial.guids, ["present-b"], "resolved entries show while others are pending")

        // The feed commit lands (what PodcastModelActor's validated import saves).
        latePodcast.episodes = [lateA, lateC]
        library.mainContext.insert(latePodcast)
        try library.mainContext.save()

        let published = await ModelContainerManager.applyHydratedPlaylistMembership(
            runtime: library, userState: userState, cache: nil
        )
        XCTAssertEqual(published.failed, 0)
        XCTAssertTrue(published.playlistFeedsToBootstrap.isEmpty)
        let complete = try queueGUIDs(in: library)
        XCTAssertEqual(complete.guids, ["late-a", "present-b", "late-c"], "exact synced order")
        XCTAssertEqual(complete.entryIDs["present-b"], partial.entryIDs["present-b"], "stable entry identity")
    }

    @MainActor
    private func queueGUIDs(in library: ModelContainer) throws -> (guids: [String], entryIDs: [String: PersistentIdentifier]) {
        let context = ModelContext(library)
        let queue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>()).first { $0.title == Playlist.defaultQueueTitle }
        )
        let entries = queue.ordered
        var ids: [String: PersistentIdentifier] = [:]
        for entry in entries {
            if let guid = entry.episode?.guid { ids[guid] = entry.persistentModelID }
        }
        return (entries.compactMap { $0.episode?.guid }, ids)
    }

    // MARK: Readiness

    func testReadinessDistinguishesEmptyWaitingRestoringPartialAndComplete() {
        typealias Readiness = PlaylistRestoreReadiness
        XCTAssertEqual(Readiness.derive(.init()), .empty)
        XCTAssertEqual(Readiness.derive(.init(cloudReferenceCount: 12)), .waitingForICloud)
        XCTAssertEqual(Readiness.derive(.init(awaitingInitialImport: true)), .waitingForICloud)
        // Local-only entries with no portable references are simply shown.
        XCTAssertEqual(Readiness.derive(.init(resolvedCount: 3)), .complete)
        XCTAssertEqual(Readiness.derive(.init(referenceCount: 4, resolvedCount: 4)), .complete)
        XCTAssertEqual(Readiness.derive(.init(referenceCount: 4, resolvedCount: 6)), .complete)

        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, pendingFeedCount: 2)),
            .restoring(resolved: 3, total: 10)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, isHydrating: true)),
            .restoring(resolved: 3, total: 10)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, pendingFeedCount: 2, isHydrating: true, isOffline: true)),
            .partial(resolved: 3, total: 10, blocker: .offline)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, loginFeedCount: 1)),
            .partial(resolved: 3, total: 10, blocker: .needsLogin)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, failedFeedCount: 1)),
            .partial(resolved: 3, total: 10, blocker: .unavailable)
        )
        // Offline never hides a sign-in-only blocker behind a network message.
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 2, resolvedCount: 0, loginFeedCount: 1, isOffline: true)),
            .partial(resolved: 0, total: 2, blocker: .needsLogin)
        )
        XCTAssertFalse(Readiness.complete.isVisible)
        XCTAssertFalse(Readiness.empty.isVisible)
        XCTAssertTrue(Readiness.waitingForICloud.isVisible)
    }

    @MainActor
    func testRestoreFactsClassifyReferencedFeeds() throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)

        let fetched = Podcast(feed: URL(string: "https://example.com/fetched.xml")!)
        fetched.metaData = PodcastMetaData()
        let episode = Episode(guid: "f", title: "F", url: URL(string: "https://example.com/f.mp3")!, podcast: fetched)
        fetched.episodes = [episode]
        let locked = Podcast(feed: URL(string: "https://example.com/locked.xml")!)
        locked.metaData = PodcastMetaData()
        locked.metaData?.credentialState = .needsLogin
        let failing = Podcast(feed: URL(string: "https://example.com/failing.xml")!)
        failing.metaData = PodcastMetaData()
        failing.metaData?.lastFeedFailureDate = .now
        let unfetched = Podcast(feed: URL(string: "https://example.com/unfetched.xml")!)
        unfetched.metaData = PodcastMetaData()
        let emptyFeed = Podcast(feed: URL(string: "https://example.com/empty.xml")!)
        emptyFeed.metaData = PodcastMetaData()
        emptyFeed.metaData?.feedUpdateCheckDate = .now
        for podcast in [fetched, locked, failing, unfetched, emptyFeed] { library.mainContext.insert(podcast) }
        try library.mainContext.save()

        let playlistID = UUID().uuidString
        for (index, name) in ["fetched", "locked", "failing", "unknown", "unfetched", "empty"].enumerated() {
            userState.mainContext.insert(PlaylistEntrySync(
                playlistID: playlistID,
                feedURL: "https://example.com/\(name).xml",
                episodeID: "e\(index)",
                sortIndex: index
            ))
        }
        try userState.mainContext.save()

        let facts = PlaylistRestoreFacts.read(
            playlistSyncID: playlistID,
            includesLegacyQueueEntries: false,
            library: library,
            userState: userState
        )
        XCTAssertEqual(facts.referenceCount, 6)
        XCTAssertEqual(facts.loginFeedCount, 1)
        XCTAssertEqual(facts.loginFeed?.absoluteString, "https://example.com/locked.xml")
        // Failed, fetched-but-empty and not-in-library feeds are not "restoring":
        // without another fetch nothing more arrives, so no indefinite spinner.
        XCTAssertEqual(facts.failedFeedCount, 3)
        XCTAssertEqual(facts.pendingFeedCount, 1, "only a never-fetched local stub is pending")
        XCTAssertEqual(
            Set(facts.retryFeeds.map(\.absoluteString)),
            [
                "https://example.com/fetched.xml",
                "https://example.com/failing.xml",
                "https://example.com/unknown.xml",
                "https://example.com/unfetched.xml",
                "https://example.com/empty.xml"
            ]
        )
    }
}
