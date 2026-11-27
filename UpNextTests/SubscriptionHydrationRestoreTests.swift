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

        // Restoring only while this playlist's own feeds are fetched or a
        // running pass can pick up its never-fetched feeds (#519).
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, pendingFeedCount: 2, isHydrating: true)),
            .restoring(resolved: 3, total: 10)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, failedFeedCount: 1, inFlightFeedCount: 1)),
            .restoring(resolved: 3, total: 10)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, pendingFeedCount: 2)),
            .partial(resolved: 3, total: 10, blocker: .waiting)
        )
        XCTAssertEqual(
            Readiness.derive(.init(referenceCount: 10, resolvedCount: 3, waitingFeedCount: 1, isHydrating: true)),
            .partial(resolved: 3, total: 10, blocker: .waiting)
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
        // A read failure is unknown, never "empty" or "restoring".
        XCTAssertEqual(Readiness.derive(.init(isHydrating: true, readFailed: true)), .unknown)
        XCTAssertEqual(Readiness.derive(.init(cloudReferenceCount: 3, readFailed: true)), .waitingForICloud)
        XCTAssertFalse(Readiness.unknown.isVisible)
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
        XCTAssertEqual(facts.resolvedCount, 0)
        XCTAssertFalse(facts.readFailed)
        XCTAssertEqual(facts.loginFeedCount, 1)
        XCTAssertEqual(facts.loginFeed?.absoluteString, "https://example.com/locked.xml")
        // Fetched-without-the-episode, fetched-but-empty and not-in-library
        // feeds are not "restoring": without another fetch nothing more
        // arrives, so no indefinite spinner.
        XCTAssertEqual(facts.failedFeedCount, 3)
        XCTAssertEqual(facts.waitingFeedCount, 1, "a just-failed feed waits for its backoff")
        XCTAssertEqual(facts.pendingFeedCount, 1, "only a never-fetched local stub is pending")
        XCTAssertEqual(facts.unresolvedFeedKeys.count, 6)
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

    // MARK: Effective membership (#519)

    @MainActor
    private func makeQueueLibrary(
        _ library: ModelContainer,
        feed: URL,
        guids: [String],
        queued: Int
    ) throws -> [Episode] {
        let podcast = Podcast(feed: feed)
        podcast.metaData = PodcastMetaData()
        let episodes = guids.map {
            Episode(guid: $0, title: $0, url: URL(string: "https://example.com/\($0).mp3")!, podcast: podcast)
        }
        podcast.episodes = episodes
        let queue = Playlist()
        library.mainContext.insert(podcast)
        library.mainContext.insert(queue)
        for (index, episode) in episodes.prefix(queued).enumerated() {
            let entry = PlaylistEntry(episode: episode, order: index)
            entry.playlist = queue
            library.mainContext.insert(entry)
        }
        try library.mainContext.save()
        return episodes
    }

    @MainActor
    func testEstablishedQueueIgnoresStaleAliasesTombstonesAndFeedSpellings() throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/feed.xml")!
        // a, b are queued here; c was removed elsewhere; f is in the library
        // but not queued (a local removal not exported yet).
        _ = try makeQueueLibrary(library, feed: feed, guids: ["a", "b", "c", "f"], queued: 2)
        let context = userState.mainContext
        let aliasID = UUID().uuidString
        for id in [Playlist.defaultQueueSyncID, aliasID] {
            context.insert(PlaylistSync(
                id: id, title: Playlist.defaultQueueTitle, symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0, kindRawValue: Playlist.Kind.manual.rawValue
            ))
        }
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        func playlistEntry(_ playlistID: String, _ feedURL: String, _ guid: String, deletedAt: Date? = nil, at date: Date) {
            context.insert(PlaylistEntrySync(
                playlistID: playlistID, feedURL: feedURL, episodeID: "guid:\(guid)", sortIndex: 0,
                isDeleted: deletedAt != nil, deletedAt: deletedAt, updatedAt: date
            ))
        }
        func queueEntry(_ feedURL: String, _ guid: String, deletedAt: Date? = nil, at date: Date) {
            context.insert(QueueEntrySync(
                feedURL: feedURL, episodeID: "guid:\(guid)", sortIndex: 0,
                isDeleted: deletedAt != nil, deletedAt: deletedAt, updatedAt: date
            ))
        }
        let spelling = "https://EXAMPLE.com/feed.xml/"
        // a: playlist alias + queue record for the same episode.
        playlistEntry(aliasID, feed.absoluteString, "a", at: old)
        queueEntry(feed.absoluteString, "a", at: new)
        // b: the same queue membership under two feed URL spellings.
        queueEntry(feed.absoluteString, "b", at: old)
        queueEntry(spelling, "b", at: new)
        // c: an old playlist row, removed later through the queue.
        playlistEntry(Playlist.defaultQueueSyncID, feed.absoluteString, "c", at: old)
        queueEntry(feed.absoluteString, "c", deletedAt: new, at: new)
        // d: not in this library, active in one alias, newer tombstone in another.
        playlistEntry(Playlist.defaultQueueSyncID, "https://example.com/gone.xml", "d", at: old)
        playlistEntry(aliasID, "https://example.com/gone.xml", "d", deletedAt: new, at: new)
        // e: only ever a tombstone.
        queueEntry("https://example.com/gone.xml", "e", deletedAt: new, at: new)
        // f: in the library, not queued here.
        queueEntry(feed.absoluteString, "f", at: new)
        try context.save()

        let facts = PlaylistRestoreFacts.read(
            playlistSyncID: Playlist.defaultQueueSyncID,
            includesLegacyQueueEntries: true,
            library: library,
            userState: userState
        )
        XCTAssertEqual(facts.resolvedCount, 2)
        XCTAssertEqual(facts.referenceCount, 2, "stale aliases, tombstones and spellings must not inflate the total")
        XCTAssertEqual(facts.locallyAvailableCount, 1)
        XCTAssertTrue(facts.retryFeeds.isEmpty, "an established local queue needs no feed work")
        XCTAssertTrue(facts.unresolvedFeedKeys.isEmpty)
        XCTAssertEqual(
            PlaylistRestoreReadiness.derive(.init(
                referenceCount: facts.referenceCount,
                resolvedCount: facts.resolvedCount,
                isHydrating: true
            )),
            .complete
        )
    }

    @MainActor
    func testUnrelatedHydrationDoesNotShowThisPlaylistAsRestoring() throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/feed.xml")!
        _ = try makeQueueLibrary(library, feed: feed, guids: ["a"], queued: 1)
        userState.mainContext.insert(QueueEntrySync(feedURL: feed.absoluteString, episodeID: "guid:a", sortIndex: 0))
        // Fetched feed that no longer lists this episode.
        userState.mainContext.insert(QueueEntrySync(feedURL: feed.absoluteString, episodeID: "guid:gone", sortIndex: 1))
        try userState.mainContext.save()

        let facts = PlaylistRestoreFacts.read(
            playlistSyncID: Playlist.defaultQueueSyncID,
            includesLegacyQueueEntries: true,
            library: library,
            userState: userState
        )
        XCTAssertEqual(facts.resolvedCount, 1)
        XCTAssertEqual(facts.referenceCount, 2)
        XCTAssertEqual(facts.failedFeedCount, 1)
        XCTAssertEqual(facts.pendingFeedCount, 0)
        let otherFeeds: Set<String> = ["https://example.com/other.xml"]
        func readiness(inFlight: Set<String>) -> PlaylistRestoreReadiness {
            .derive(.init(
                referenceCount: facts.referenceCount,
                resolvedCount: facts.resolvedCount,
                pendingFeedCount: facts.pendingFeedCount,
                failedFeedCount: facts.failedFeedCount,
                inFlightFeedCount: facts.unresolvedFeedKeys.intersection(inFlight).count,
                isHydrating: true
            ))
        }
        XCTAssertEqual(readiness(inFlight: otherFeeds), .partial(resolved: 1, total: 2, blocker: .unavailable))
        XCTAssertEqual(
            readiness(inFlight: [PodcastFeedIdentity.normalizedFeedURLString(feed)]),
            .restoring(resolved: 1, total: 2)
        )
    }

    @MainActor
    func testFreshDeviceRestoreCountsProgressively() throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feedA = "https://example.com/a.xml"
        let feedB = "https://example.com/b.xml"
        for (feed, guid, index) in [(feedA, "a1", 0), (feedA, "a2", 1), (feedB, "b1", 2)] {
            userState.mainContext.insert(QueueEntrySync(feedURL: feed, episodeID: "guid:\(guid)", sortIndex: index))
        }
        try userState.mainContext.save()
        // Subscription stubs, never fetched.
        for feed in [feedA, feedB] {
            let podcast = Podcast(feed: URL(string: feed)!)
            podcast.metaData = PodcastMetaData()
            library.mainContext.insert(podcast)
        }
        library.mainContext.insert(Playlist())
        try library.mainContext.save()

        func read() -> PlaylistRestoreFacts {
            PlaylistRestoreFacts.read(
                playlistSyncID: Playlist.defaultQueueSyncID,
                includesLegacyQueueEntries: true,
                library: library,
                userState: userState
            )
        }
        var facts = read()
        XCTAssertEqual(facts.referenceCount, 3)
        XCTAssertEqual(facts.resolvedCount, 0)
        XCTAssertEqual(facts.pendingFeedCount, 2)

        // Feed A arrives and its entries are projected into the queue.
        let context = library.mainContext
        let podcastA = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first { $0.feed?.absoluteString == feedA })
        let queue = try XCTUnwrap(context.fetch(FetchDescriptor<Playlist>()).first)
        for (index, guid) in ["a1", "a2"].enumerated() {
            let episode = Episode(guid: guid, title: guid, url: URL(string: "https://example.com/\(guid).mp3")!, podcast: podcastA)
            context.insert(episode)
            let entry = PlaylistEntry(episode: episode, order: index)
            entry.playlist = queue
            context.insert(entry)
        }
        podcastA.metaData?.feedUpdateCheckDate = .now
        try context.save()

        facts = read()
        XCTAssertEqual(facts.referenceCount, 3)
        XCTAssertEqual(facts.resolvedCount, 2)
        XCTAssertEqual(facts.pendingFeedCount, 1)
        XCTAssertEqual(
            PlaylistRestoreReadiness.derive(.init(
                referenceCount: facts.referenceCount,
                resolvedCount: facts.resolvedCount,
                pendingFeedCount: facts.pendingFeedCount,
                isHydrating: true
            )),
            .restoring(resolved: 2, total: 3)
        )
    }

    func testResolverAppliesNewestRecordPerIdentity() {
        var resolver = PlaylistMembershipResolver()
        let key = PlaylistMembershipResolver.identityKey(feedURL: "https://example.com/f.xml", episodeID: "guid:x")
        XCTAssertEqual(
            key,
            PlaylistMembershipResolver.identityKey(feedURL: "https://EXAMPLE.com/f.xml/", episodeID: "guid:x")
        )
        let t1 = Date(timeIntervalSince1970: 1)
        let t2 = Date(timeIntervalSince1970: 2)
        let t3 = Date(timeIntervalSince1970: 3)
        // Newest first: a playlist tombstone at t3 beats an older active alias.
        XCTAssertEqual(resolver.resolvePlaylistEntry(playlistKey: "q", identityKey: key, updatedAt: t2,
                                                     isTombstone: false, isDefaultQueue: true), .active)
        XCTAssertEqual(resolver.resolvePlaylistEntry(playlistKey: "q", identityKey: key, updatedAt: t1,
                                                     isTombstone: true, isDefaultQueue: true), .superseded)
        // Queue record older than the playlist record defers to it.
        XCTAssertEqual(resolver.resolveQueueEntry(identityKey: key, updatedAt: t1, isTombstone: true), .superseded)
        // Equal or newer queue record wins; an older queue alias never overrides it.
        XCTAssertEqual(resolver.resolveQueueEntry(identityKey: key, updatedAt: t3, isTombstone: false), .active)
        XCTAssertEqual(resolver.resolveQueueEntry(identityKey: key, updatedAt: t2, isTombstone: true), .superseded)
    }
}
