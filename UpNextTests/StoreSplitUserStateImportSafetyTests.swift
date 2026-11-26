import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitUserStateImportSafetyTests: XCTestCase {
    @MainActor
    func testOversizedTimestampBoundaryDoesNotProducePartialImportSnapshot() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let timestamp = Date(timeIntervalSince1970: 1234)
        for index in 0..<501 {
            userState.mainContext.insert(EpisodeStateSync(
                feedURL: "https://example.com/feed.xml",
                episodeID: "episode-\(index)",
                updatedAt: timestamp
            ))
        }
        try userState.mainContext.save()
        XCTAssertThrowsError(try ModelContainerManager.shared.latestUserStateChangeStamps(userState))
    }

    func testCommitOfCapturedSnapshotLeavesLaterImportEligible() throws {
        let suite = "StoreSplitUserStateImportSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let captured: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] = [
            .episodeState: .init(date: Date(timeIntervalSince1970: 100), recordIDsAtTimestamp: ["first"])
        ]
        let later: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] = [
            .episodeState: .init(date: Date(timeIntervalSince1970: 200), recordIDsAtTimestamp: ["later"])
        ]
        StoreSplitImportCursorStore.commit(captured, streams: [.episodeState], defaults: defaults)
        XCTAssertEqual(
            StoreSplitImportCursorStore.changedStreams(current: later, force: false, defaults: defaults),
            [.episodeState]
        )
    }

    @MainActor
    func testPreferenceOnlyImportBuildsPodcastIndex() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/preferences.xml")!
        runtime.mainContext.insert(Podcast(feed: feed))
        try runtime.mainContext.save()
        userState.mainContext.insert(PodcastPreferenceSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed), autoDownload: true
        ))
        try userState.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime, userStateContainer: userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.feedsToBootstrap.isEmpty)
        let podcast = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.settings?.autoDownload, true)
    }

    @MainActor
    func testRepeatedNoChangeImportsDoNotFetchTheLibraryPodcastIndex() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        for index in 0..<300 {
            runtime.mainContext.insert(Podcast(feed: URL(string: "https://example.com/\(index).xml")!))
        }
        try runtime.mainContext.save()

        StoreSplitUserStateImporter.debugPodcastIndexBuildCount = 0
        for _ in 0..<3 {
            let result = await StoreSplitUserStateImporter.apply(
                legacyContainer: runtime,
                userStateContainer: userState,
                projectListeningHistoryToLegacy: false,
                changedStreams: []
            )
            XCTAssertEqual(result.failed, 0)
        }
        XCTAssertEqual(StoreSplitUserStateImporter.debugPodcastIndexBuildCount, 0)
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Podcast>()), 300)
    }


    // MARK: - #104 record-level incremental import

    /// A cursor at T that lists record "a" must still import "b", which shares
    /// the timestamp, and "c" after it, while not re-reading "a".
    @MainActor
    func testEqualTimestampBoundaryRecordIsNotSkipped() async throws {
        let (defaults, suite) = try makeCursorDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try makePreferenceFixture(count: 3)
        let boundary = Date(timeIntervalSince1970: 1_000)
        let records = try insertPreferences(
            for: fixture.feeds,
            dates: [boundary, boundary, boundary.addingTimeInterval(1)],
            in: fixture.userState
        )
        StoreSplitImportCursorStore.advance(
            .preferences, through: boundary, recordIDsAtTimestamp: [records[0]], defaults: defaults
        )
        StoreSplitImportCursorStore.markFullPassCompleted(.preferences, defaults: defaults)

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.streamMetrics[.preferences]?.rowsFetched, 2)
        XCTAssertEqual(result.streamMetrics[.preferences]?.fullPass, false)
        let applied = try autoDownloadByFeed(fixture.runtime)
        XCTAssertNil(applied[fixture.feeds[0]] ?? nil, "already covered by the cursor")
        XCTAssertEqual(applied[fixture.feeds[1]] ?? nil, true, "same timestamp, not in the cursor")
        XCTAssertEqual(applied[fixture.feeds[2]] ?? nil, true)
        let cursor = try XCTUnwrap(StoreSplitImportCursorStore.load(defaults: defaults)[.preferences])
        XCTAssertEqual(cursor.importedThrough, boundary.addingTimeInterval(1))
        XCTAssertEqual(cursor.recordIDsAtTimestamp, [records[2]])
    }

    /// Re-projecting unchanged synchronized state writes nothing.
    @MainActor
    func testNoOpImportMakesZeroLibrarySaves() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/noop.xml")!
        let podcast = Podcast(feed: feed)
        let episode = Episode(
            guid: "noop-episode",
            title: "No-op",
            url: URL(string: "https://example.com/noop.mp3")!,
            podcast: podcast
        )
        runtime.mainContext.insert(podcast)
        runtime.mainContext.insert(episode)
        _ = Playlist.ensureDefaultQueue(in: runtime.mainContext)
        try runtime.mainContext.save()
        let identity = episode.stableEpisodeIdentity
        let feedKey = PodcastFeedIdentity.normalizedFeedURLString(feed)
        let stamp = Date(timeIntervalSince1970: 5_000)
        userState.mainContext.insert(SubscriptionSync(feedURL: feedKey, subscribedAt: stamp, updatedAt: stamp))
        userState.mainContext.insert(PodcastPreferenceSync(feedURL: feedKey, autoDownload: true, updatedAt: stamp))
        userState.mainContext.insert(EpisodeStateSync(
            feedURL: identity.feedURL, episodeID: identity.episodeID,
            playPosition: 42, maxPlayPosition: 42, lastPlayedAt: stamp, updatedAt: stamp
        ))
        userState.mainContext.insert(QueueEntrySync(
            feedURL: identity.feedURL, episodeID: identity.episodeID,
            sortIndex: 0, addedAt: stamp, updatedAt: stamp
        ))
        try userState.mainContext.save()

        let streams: Set<StoreSplitUserStateStream> = [
            .subscriptions, .preferences, .episodeState, .playlists, .queueEntries
        ]
        let first = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime, userStateContainer: userState,
            projectListeningHistoryToLegacy: false, changedStreams: streams
        )
        XCTAssertEqual(first.failed, 0)
        XCTAssertGreaterThan(first.librarySaves, 0)

        // No cursor (full pass): every row is read again but nothing changes.
        let second = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime, userStateContainer: userState,
            projectListeningHistoryToLegacy: false, changedStreams: streams
        )
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(second.librarySaves, 0, "\(second.streamMetrics)")
        XCTAssertEqual(second.streamMetrics.values.reduce(0) { $0 + $1.rowsChanged }, 0)
        XCTAssertGreaterThan(second.streamMetrics[.episodeState]?.rowsFetched ?? 0, 0)
    }

    /// A new importer instance (as after relaunch) starts from the persisted
    /// cursor and reads only rows written since.
    @MainActor
    func testCursorSurvivesRelaunchAndReadsOnlyNewRows() async throws {
        let (defaults, suite) = try makeCursorDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try makePreferenceFixture(count: 4)
        let base = Date(timeIntervalSince1970: 2_000)
        _ = try insertPreferences(
            for: Array(fixture.feeds.prefix(3)),
            dates: (0..<3).map { base.addingTimeInterval(Double($0)) },
            in: fixture.userState
        )
        let first = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertEqual(first.streamMetrics[.preferences]?.rowsFetched, 3)
        XCTAssertEqual(first.streamMetrics[.preferences]?.fullPass, true)

        _ = try insertPreferences(
            for: [fixture.feeds[3]], dates: [base.addingTimeInterval(10)], in: fixture.userState
        )
        let second = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(second.streamMetrics[.preferences]?.fullPass, false)
        XCTAssertEqual(second.streamMetrics[.preferences]?.rowsFetched, 1)
        XCTAssertEqual(try autoDownloadByFeed(fixture.runtime)[fixture.feeds[3]] ?? nil, true)

        let third = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertEqual(third.streamMetrics[.preferences]?.rowsFetched, 0)
        XCTAssertEqual(third.librarySaves, 0)
    }

    /// An interrupted pass keeps the batches it saved; the next pass resumes
    /// after them and applies the rest exactly once.
    @MainActor
    func testInterruptedBatchResumesAfterLastSavedBatch() async throws {
        let (defaults, suite) = try makeCursorDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try makePreferenceFixture(count: 5)
        let base = Date(timeIntervalSince1970: 3_000)
        _ = try insertPreferences(
            for: fixture.feeds,
            dates: (0..<5).map { base.addingTimeInterval(Double($0)) },
            in: fixture.userState
        )
        StoreSplitUserStateImporter.debugSourcePageSizeOverride = 2
        StoreSplitUserStateImporter.debugStopAfterDeltaBatches = 1
        defer {
            StoreSplitUserStateImporter.debugSourcePageSizeOverride = nil
            StoreSplitUserStateImporter.debugStopAfterDeltaBatches = nil
        }

        let interrupted = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertTrue(interrupted.interruptedByPlayback)
        XCTAssertEqual(interrupted.streamMetrics[.preferences]?.rowsFetched, 2)
        XCTAssertEqual(
            StoreSplitImportCursorStore.load(defaults: defaults)[.preferences]?.importedThrough,
            base.addingTimeInterval(1)
        )
        XCTAssertNil(
            StoreSplitImportCursorStore.load(defaults: defaults)[.preferences]?.fullPassCompletedAt,
            "an interrupted pass is not a completed full pass"
        )

        StoreSplitUserStateImporter.debugStopAfterDeltaBatches = nil
        let resumed = await StoreSplitUserStateImporter.apply(
            legacyContainer: fixture.runtime, userStateContainer: fixture.userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences],
            cursorSuiteName: suite
        )
        XCTAssertEqual(resumed.failed, 0)
        XCTAssertFalse(resumed.interruptedByPlayback)
        XCTAssertEqual(resumed.streamMetrics[.preferences]?.fullPass, false, "resumes, not restarts")
        XCTAssertEqual(resumed.streamMetrics[.preferences]?.rowsFetched, 3)
        XCTAssertNotNil(
            StoreSplitImportCursorStore.load(defaults: defaults)[.preferences]?.fullPassCompletedAt
        )
        let applied = try autoDownloadByFeed(fixture.runtime)
        XCTAssertEqual(fixture.feeds.compactMap { applied[$0] ?? nil }, Array(repeating: true, count: 5))
        XCTAssertEqual(
            StoreSplitImportCursorStore.load(defaults: defaults)[.preferences]?.importedThrough,
            base.addingTimeInterval(4)
        )
    }

    // MARK: Helpers

    private func makeCursorDefaults() throws -> (UserDefaults, String) {
        let suite = "StoreSplitUserStateImportSafetyTests.cursor.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private struct PreferenceFixture {
        let runtime: ModelContainer
        let userState: ModelContainer
        let feeds: [URL]
    }

    @MainActor
    private func makePreferenceFixture(count: Int) throws -> PreferenceFixture {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feeds = (0..<count).map { URL(string: "https://example.com/incremental-\($0).xml")! }
        for feed in feeds { runtime.mainContext.insert(Podcast(feed: feed)) }
        try runtime.mainContext.save()
        return PreferenceFixture(runtime: runtime, userState: userState, feeds: feeds)
    }

    /// Inserts one `autoDownload = true` preference per feed and returns the
    /// record IDs in the same order.
    @MainActor
    private func insertPreferences(
        for feeds: [URL],
        dates: [Date],
        in userState: ModelContainer
    ) throws -> [String] {
        let ids = zip(feeds, dates).map { feed, date in
            let record = PodcastPreferenceSync(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
                autoDownload: true,
                updatedAt: date
            )
            userState.mainContext.insert(record)
            return record.id
        }
        try userState.mainContext.save()
        return ids
    }

    @MainActor
    private func autoDownloadByFeed(_ runtime: ModelContainer) throws -> [URL: Bool?] {
        let context = ModelContext(runtime)
        return try context.fetch(FetchDescriptor<Podcast>()).reduce(into: [:]) { values, podcast in
            guard let feed = podcast.feed else { return }
            values[feed] = podcast.settings?.autoDownload
        }
    }
}
