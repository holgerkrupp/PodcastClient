import SwiftData
import XCTest
@testable import UpNext

/// Disk-backed coverage of the background copy of user data into UserState, with
/// the library in its real role: a writable local store, not a frozen source.
@MainActor
final class StoreCutoverTests: XCTestCase {
    private var directory: URL!
    private let feedURL = URL(string: "https://example.com/feed.xml")!

    private var libraryURL: URL { directory.appendingPathComponent("SharedDatabase.sqlite") }
    private var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreCutoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        appGroupDefaults.removeObject(forKey: StoreCutoverState.deferredCompleteKey)
    }

    override func tearDownWithError() throws {
        appGroupDefaults.removeObject(forKey: StoreCutoverState.deferredCompleteKey)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCopyMovesUserDataAndLeavesTheLibraryInPlace() async throws {
        let stores = try makeStores(episodeCount: 5)
        let outcome = await runCopy(stores)
        XCTAssertEqual(outcome, .committed)
        let userState = ModelContext(stores.userState)
        XCTAssertEqual(try userState.fetchCount(FetchDescriptor<SubscriptionSync>()), 1)
        XCTAssertEqual(try userState.fetchCount(FetchDescriptor<EpisodeStateSync>()), 5)
        XCTAssertEqual(try userState.fetchCount(FetchDescriptor<BookmarkSync>()), 1)
        XCTAssertEqual(try userState.fetchCount(FetchDescriptor<ListeningHistorySync>()), 1)
        XCTAssertEqual(try userState.fetchCount(FetchDescriptor<QueueEntrySync>()), 2)
        XCTAssertEqual(try ModelContext(stores.library).fetchCount(FetchDescriptor<Episode>()), 5)
    }

    func testInterruptedCopyResumesWithoutDuplicates() async throws {
        let stores = try makeStores(episodeCount: 30)
        let gate = CutoverGate(4)
        let interrupted = await StoreCutoverCoordinator.runDeferred(
            legacyContainer: stores.library,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache,
            shouldContinue: { gate.tick() },
            idle: {}
        )
        XCTAssertEqual(interrupted, .interrupted)
        let finished = await runCopy(stores)
        XCTAssertEqual(finished, .committed)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<EpisodeStateSync>()), 30)
    }

    func testEditsDuringTheCopyAreNotLost() async throws {
        let stores = try makeStores(episodeCount: 3)
        let gate = CutoverGate(2)
        _ = await StoreCutoverCoordinator.runDeferred(
            legacyContainer: stores.library,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache,
            shouldContinue: { gate.tick() },
            idle: {}
        )
        let context = ModelContext(stores.library)
        let added = Podcast(feed: URL(string: "https://example.com/added.xml")!)
        added.metaData?.isSubscribed = true
        added.metaData?.subscriptionDate = Date(timeIntervalSince1970: 2_000)
        context.insert(added)
        try context.save()
        let finished = await runCopy(stores)
        XCTAssertEqual(finished, .committed)
        XCTAssertEqual(try ModelContext(stores.library).fetchCount(FetchDescriptor<Podcast>()), 2)
    }

    func testNewerTombstoneInUserStateSurvivesTheCopy() async throws {
        let stores = try makeStores(episodeCount: 3)
        let entry = try XCTUnwrap(ModelContext(stores.library).fetch(FetchDescriptor<PlaylistEntry>())
            .first { $0.order == 0 })
        let identity = try XCTUnwrap(entry.episode?.stableEpisodeIdentity)
        let context = ModelContext(stores.userState)
        let tombstone = QueueEntrySync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            sortIndex: 0,
            addedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 9_000_000_000)
        )
        tombstone.isDeleted = true
        tombstone.deletedAt = Date(timeIntervalSince1970: 9_000_000_000)
        context.insert(tombstone)
        try context.save()

        let outcome = await runCopy(stores)
        XCTAssertEqual(outcome, .committed)
        let rows = try ModelContext(stores.userState).fetch(FetchDescriptor<QueueEntrySync>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.episodeID == identity.episodeID }?.isDeleted, true)
    }

    func testDuplicateYearSummariesCountOnce() async throws {
        let stores = try makeStores(episodeCount: 1)
        let context = ModelContext(stores.library)
        // The same year and feed three times, as a CloudKit re-attach leaves it.
        for seconds in [3_600.0, 3_600.0, 1_800.0] {
            context.insert(PlaySessionSummary(
                id: UUID(),
                periodKind: PlaySessionSummaryPeriod.year.rawValue,
                periodStart: Date(timeIntervalSince1970: 0),
                podcastFeed: feedURL,
                podcastName: "Example",
                totalSeconds: seconds
            ))
        }
        try context.save()
        let outcome = await runCopy(stores)
        XCTAssertEqual(outcome, .committed)
        let baselines = try ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(baselines.map(\.totalSeconds), [3_600])
    }

    func testFinishedEpisodesAreNotCarriedIntoPlaylists() async throws {
        let stores = try makeStores(episodeCount: 2)
        let context = ModelContext(stores.library)
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first { $0.guid == "episode-0" })
        episode.metaData?.isHistory = true
        episode.metaData?.completionDate = Date(timeIntervalSince1970: 50_000)
        try context.save()
        let outcome = await runCopy(stores)
        XCTAssertEqual(outcome, .committed)
        let active = try ModelContext(stores.userState).fetch(FetchDescriptor<QueueEntrySync>())
            .filter { $0.isDeleted == false }
        XCTAssertEqual(active.count, 1)
    }

    func testStaleActiveSubscriptionCreatesNoPodcastAfterTheLibrarySwitch() async throws {
        let stores = try makeStores(episodeCount: 1)
        StoreCutoverState.beginLocalLibrary()
        let cutoff = try XCTUnwrap(StoreCutoverState.localLibraryStartedAt)
        let context = ModelContext(stores.userState)
        context.insert(SubscriptionSync(
            feedURL: "https://example.com/stale.xml",
            isSubscribed: true,
            subscribedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        context.insert(SubscriptionSync(
            feedURL: "https://example.com/new-elsewhere.xml",
            isSubscribed: true,
            subscribedAt: cutoff.addingTimeInterval(60),
            updatedAt: cutoff.addingTimeInterval(60)
        ))
        try context.save()
        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: stores.library,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache,
            authoritativePlaylists: false,
            projectListeningHistoryToLegacy: false,
            episodeStateProjectionRecencyCutoff: nil,
            isInitialRuntimeHydration: true
        )
        let feeds = try ModelContext(stores.library).fetch(FetchDescriptor<Podcast>())
            .compactMap { $0.feed?.absoluteString }
        XCTAssertFalse(feeds.contains { $0.contains("stale") })
        XCTAssertTrue(feeds.contains { $0.contains("new-elsewhere") })
        XCTAssertEqual(
            try ModelContext(stores.userState).fetch(FetchDescriptor<SubscriptionSync>()).filter(\.isSubscribed).count,
            2,
            "The synced rows are left as they are"
        )
    }

    func testCleanupTombstonesOnlyOldRowsMissingFromTheLibrary() async throws {
        let stores = try makeStores(episodeCount: 1)
        let copied = await runCopy(stores)
        XCTAssertEqual(copied, .committed)
        let cutoff = Date(timeIntervalSince1970: 5_000)
        let context = ModelContext(stores.userState)
        context.insert(SubscriptionSync(
            feedURL: "https://example.com/stale.xml",
            isSubscribed: true,
            subscribedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        context.insert(SubscriptionSync(
            feedURL: "https://example.com/new-elsewhere.xml",
            isSubscribed: true,
            subscribedAt: cutoff.addingTimeInterval(60),
            updatedAt: cutoff.addingTimeInterval(60)
        ))
        try context.save()

        let changed = try StoreSplitMigrationService.tombstoneSubscriptionsMissingFromLibrary(
            libraryContainer: stores.library,
            userStateContainer: stores.userState,
            olderThan: cutoff
        )
        XCTAssertEqual(changed, 1)
        let rows = try ModelContext(stores.userState).fetch(FetchDescriptor<SubscriptionSync>())
        XCTAssertEqual(rows.first { $0.feedURL.contains("stale") }?.isSubscribed, false)
        XCTAssertEqual(rows.first { $0.feedURL.contains("new-elsewhere") }?.isSubscribed, true)
        XCTAssertEqual(rows.first { $0.feedURL.contains("feed.xml") }?.isSubscribed, true, "A real subscription stays")

        let again = try StoreSplitMigrationService.tombstoneSubscriptionsMissingFromLibrary(
            libraryContainer: stores.library,
            userStateContainer: stores.userState,
            olderThan: cutoff
        )
        XCTAssertEqual(again, 0)
    }

    func testCleanupDoesNothingWhenTheLibraryIsEmpty() throws {
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let context = ModelContext(userState)
        context.insert(SubscriptionSync(
            feedURL: "https://example.com/real.xml",
            isSubscribed: true,
            subscribedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()
        let changed = try StoreSplitMigrationService.tombstoneSubscriptionsMissingFromLibrary(
            libraryContainer: library,
            userStateContainer: userState,
            olderThan: .now
        )
        XCTAssertEqual(changed, 0)
    }

    func testInflatedBaselineFromAnOlderTierIsCorrected() throws {
        let stores = try makeStores(episodeCount: 1)
        let library = ModelContext(stores.library)
        library.insert(PlaySessionSummary(
            id: UUID(),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: Date(timeIntervalSince1970: 0),
            podcastFeed: feedURL,
            totalSeconds: 3_600
        ))
        try library.save()
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let userState = ModelContext(stores.userState)
        userState.insert(ListeningBaselineSync(feedURL: feedKey, totalSeconds: 9_000, capturedByDeviceID: "other"))
        userState.insert(ListeningBaselineSync(feedURL: "https://example.com/old-tier.xml", totalSeconds: 9_000))
        try userState.save()

        _ = try StoreSplitMigrationService.repairInflatedBaseline(
            libraryContainer: stores.library,
            userStateContainer: stores.userState
        )
        let rows = try ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalSeconds }, 3_600)
    }

    func testBaselineCloseToTheSummariesIsLeftAlone() throws {
        let stores = try makeStores(episodeCount: 1)
        let library = ModelContext(stores.library)
        library.insert(PlaySessionSummary(
            id: UUID(),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: Date(timeIntervalSince1970: 0),
            podcastFeed: feedURL,
            totalSeconds: 3_000
        ))
        try library.save()
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let userState = ModelContext(stores.userState)
        userState.insert(ListeningBaselineSync(feedURL: feedKey, totalSeconds: 3_600))
        try userState.save()
        let changed = try StoreSplitMigrationService.repairInflatedBaseline(
            libraryContainer: stores.library,
            userStateContainer: stores.userState
        )
        XCTAssertEqual(changed, 0)
    }

    func testClassificationFollowsTheLibraryFile() {
        XCTAssertEqual(StoreBootstrapMode.resolve(legacyStoreExists: true), .legacyUpgrade)
        XCTAssertEqual(StoreBootstrapMode.resolve(legacyStoreExists: false), .freshSplitInstall)
        XCTAssertEqual(
            StoreBootstrapMode.resolve(legacyStoreExists: false, installationWasPreviouslyInitialized: true),
            .existingLibraryUnavailable
        )
        XCTAssertFalse(StoreBootstrapMode.legacyUpgrade.usesInMemoryRuntimeProjection)
    }

    func testLibraryContainerIsNeverCloudKitAttached() throws {
        let container = try ModelContainerManager.makeLegacyContainer(storageURL: libraryURL)
        XCTAssertTrue(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
    }

    // MARK: - Fresh-install runtime

    func testFirstBuildHoldsPriorityEpisodesAndTranscriptsFillInLater() async throws {
        let cache = try ModelContainerManager.makeCacheContainer(
            storageURL: directory.appendingPathComponent("PodcastCache.sqlite")
        )
        let context = ModelContext(cache)
        let feed = feedURL.absoluteString
        context.insert(CachedPodcast(id: feed, feedURL: feed))
        for index in 0..<4 {
            context.insert(CachedEpisode(id: "\(StableIdentityKey.make(feed))\(index)", feedURL: feed, title: "E\(index)"))
        }
        let keptID = "\(StableIdentityKey.make(feed))0"
        context.insert(CachedTranscriptLine(id: "line", feedURL: feed, episodeID: keptID, text: "Hello"))
        try context.save()
        let runtime = try StoreRuntimeProjection.open(
            at: directory.appendingPathComponent("LibraryRuntime.sqlite"),
            isCurrent: true
        )
        _ = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: cache,
            runtimeContainer: runtime,
            includesTranscripts: false,
            priorityEpisodes: [keptID]
        )
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(
            FetchDescriptor<CachedEpisode>()
        ), 4)
        XCTAssertLessThan(try ModelContext(runtime).fetchCount(FetchDescriptor<Episode>()), 4)
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<TranscriptLineAndTime>()), 0)
    }

    func testRuntimeBuildResumesAfterInterruption() throws {
        let cache = try ModelContainerManager.makeCacheContainer(
            storageURL: directory.appendingPathComponent("PodcastCache.sqlite")
        )
        let context = ModelContext(cache)
        for index in 0..<3 {
            let feed = "https://example.com/\(index).xml"
            context.insert(CachedPodcast(id: feed, feedURL: feed))
        }
        try context.save()
        let runtime = try StoreRuntimeProjection.open(
            at: directory.appendingPathComponent("LibraryRuntime.sqlite"),
            isCurrent: true
        )
        let gate = CutoverGate(2)
        let cursor = CursorBox()
        let first = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: cache,
            runtimeContainer: runtime,
            shouldContinue: { gate.tick() },
            checkpoint: { cursor.value = $0 }
        )
        XCTAssertTrue(first.interrupted)
        let second = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: cache,
            runtimeContainer: runtime,
            resumeAfter: try XCTUnwrap(cursor.value)
        )
        XCTAssertFalse(second.interrupted)
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Podcast>()), 3)
    }

    func testRuntimeProjectionSurvivesReopenAndIsDiscardedWhenStale() throws {
        let url = directory.appendingPathComponent("LibraryRuntime.sqlite")
        do {
            let container = try StoreRuntimeProjection.open(at: url, isCurrent: false)
            let context = ModelContext(container)
            context.insert(Podcast(feed: feedURL))
            try context.save()
        }
        do {
            let reopened = try StoreRuntimeProjection.open(at: url, isCurrent: true)
            XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<Podcast>()), 1)
        }
        let rebuilt = try StoreRuntimeProjection.open(at: url, isCurrent: false)
        XCTAssertEqual(try ModelContext(rebuilt).fetchCount(FetchDescriptor<Podcast>()), 0)
    }

    // MARK: - Helpers

    private final class CutoverGate: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(_ remaining: Int) { self.remaining = remaining }
        func tick() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private final class CursorBox: @unchecked Sendable {
        var value: String?
    }

    private struct Stores {
        let library: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    private func runCopy(_ stores: Stores) async -> StoreCutoverOutcome {
        await StoreCutoverCoordinator.runDeferred(
            legacyContainer: stores.library,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache,
            shouldContinue: { true },
            idle: {}
        )
    }

    private func makeStores(episodeCount: Int) throws -> Stores {
        let library = try ModelContainerManager.makeLegacyContainer(storageURL: libraryURL)
        let context = ModelContext(library)
        let podcast = Podcast(feed: feedURL)
        podcast.title = "Example"
        podcast.metaData?.isSubscribed = true
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        context.insert(podcast)
        var episodes: [Episode] = []
        for index in 0..<episodeCount {
            let episode = Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                publishDate: Date(timeIntervalSince1970: Double(index) * 86_400),
                url: URL(string: "https://example.com/\(index).mp3")!,
                podcast: podcast,
                duration: 120
            )
            episode.metaData?.playPosition = Double(index + 1)
            episode.metaData?.maxPlayposition = Double(index + 2)
            episode.metaData?.lastPlayed = Date(timeIntervalSince1970: 1_000 + Double(index))
            episodes.append(episode)
            context.insert(episode)
        }
        podcast.episodes = episodes
        let queue = Playlist()
        queue.title = Playlist.defaultQueueTitle
        var entries: [PlaylistEntry] = []
        for index in 0..<min(2, episodes.count) {
            let entry = PlaylistEntry(episode: episodes[index], order: index)
            entry.dateAdded = Date(timeIntervalSince1970: 100 + Double(index))
            entry.playlist = queue
            entries.append(entry)
        }
        queue.items = entries
        context.insert(queue)
        if let first = episodes.first {
            let bookmark = Bookmark(start: 30, title: "Remember", type: .bookmark)
            bookmark.uuid = UUID()
            bookmark.creationtime = Date(timeIntervalSince1970: 5_000)
            bookmark.bookmarkEpisode = first
            first.bookmarks = [bookmark]
            context.insert(bookmark)
            context.insert(PlaySession(
                id: UUID(),
                episode: first,
                startTime: Date(timeIntervalSince1970: 3_000),
                endTime: Date(timeIntervalSince1970: 3_120),
                startPosition: 0,
                endPosition: 120,
                endedCleanly: true
            ))
        }
        try context.save()
        return Stores(
            library: library,
            userState: try ModelContainerManager.makeUserStateContainer(
                storageURL: directory.appendingPathComponent("UserState.sqlite")
            ),
            cache: try ModelContainerManager.makeCacheContainer(
                storageURL: directory.appendingPathComponent("PodcastCache.sqlite")
            )
        )
    }
}
