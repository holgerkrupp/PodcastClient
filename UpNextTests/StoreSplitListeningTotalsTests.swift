import SwiftData
import XCTest
@testable import UpNext

/// Lifetime listening totals are summed across the `__legacy_shared__` migration
/// record and the live per-device rollups. That is only correct while the two are
/// disjoint, and only stable while neither is computed from the other.
final class StoreSplitListeningTotalsTests: XCTestCase {
    /// `__legacy_shared__` already accounts for every migrated session, and nothing
    /// ever subtracts from it. Clearing `isLegacyMigrated` on a live upsert would
    /// additionally admit the row to this device's per-device summary, so readers
    /// that sum the two would count the same seconds twice.
    func testLiveUpsertDoesNotPromoteAMigratedRowIntoTheLiveSummaries() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(userState)
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-1"
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(600)
        let id = ListeningHistoryIdentity.make(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: 0,
            endPosition: 600
        )
        let migrated = ListeningHistorySync(
            id: id,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            sourceDeviceID: "device-a",
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: 0,
            endPosition: 600,
            listenedSeconds: 600,
            isLegacyMigrated: true,
            updatedAt: startedAt
        )
        context.insert(migrated)
        try context.save()

        await StoreSplitListeningHistorySyncWriter(modelContainer: userState).upsert(
            StoreSplitListeningHistorySnapshot(
                id: id,
                identity: identity,
                podcastName: "Example",
                episodeTitle: "Episode 1",
                sourceDeviceID: "device-a",
                sourceDeviceName: "Phone",
                deviceModel: "iPhone",
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: 0,
                endPosition: 600,
                listenedSeconds: 600,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                endedCleanly: true
            )
        )

        let verification = ModelContext(userState)
        let stored = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<ListeningHistorySync>()).first
        )
        XCTAssertTrue(stored.isLegacyMigrated)
        let liveSeconds = try verification
            .fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.periodKind == PlaySessionSummaryPeriod.forever.rawValue }
            .reduce(0) { $0 + $1.totalSeconds }
        XCTAssertEqual(
            liveSeconds, 0,
            "a migrated row must contribute nothing to the live per-device rollup; __legacy_shared__ already carries it"
        )
    }

    /// The contrast case: a row that was never migrated is exactly what the live
    /// per-device rollup is for.
    func testLiveUpsertCountsARowThatWasNeverMigrated() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-1"
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(600)

        await StoreSplitListeningHistorySyncWriter(modelContainer: userState).upsert(
            StoreSplitListeningHistorySnapshot(
                id: ListeningHistoryIdentity.make(
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: 0,
                    endPosition: 600
                ),
                identity: identity,
                podcastName: "Example",
                episodeTitle: "Episode 1",
                sourceDeviceID: "device-a",
                sourceDeviceName: "Phone",
                deviceModel: "iPhone",
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: 0,
                endPosition: 600,
                listenedSeconds: 600,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                endedCleanly: true
            )
        )

        let liveSeconds = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.periodKind == PlaySessionSummaryPeriod.forever.rawValue }
            .reduce(0) { $0 + $1.totalSeconds }
        XCTAssertEqual(liveSeconds, 600)
    }

    /// The importer rewrites the legacy summary table from the synced summaries and
    /// the migration republishes that table as the authoritative `__legacy_shared__`
    /// record. Because the republish max-merges, a total that round-trips once can
    /// never come back down — on any device on the account.
    @MainActor
    func testProjectedSummariesAreNotRepublishedAsTheMigrationRecord() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let feed = URL(string: "https://example.com/feed.xml")!
        let periodStart = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let projected = PlaySessionSummary(
            id: PlaySessionSummary.splitStoreProjectionID(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
                periodKind: PlaySessionSummaryPeriod.year.rawValue,
                periodStart: periodStart
            ),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: periodStart,
            podcastFeed: feed,
            podcastName: "Example",
            totalSeconds: 9_999
        )
        legacy.mainContext.insert(projected)
        try legacy.mainContext.save()

        XCTAssertTrue(projected.isSplitStoreProjection)

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let published = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningSummarySync>())
        XCTAssertTrue(
            published.isEmpty,
            "a summary row that came from UserState must not be published back into it"
        )
    }

    @MainActor
    func testLocallyComputedSummariesAreStillRepublished() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let feed = URL(string: "https://example.com/feed.xml")!
        let periodStart = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let measured = PlaySessionSummary(
            id: UUID(),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: periodStart,
            podcastFeed: feed,
            podcastName: "Example",
            totalSeconds: 1_200
        )
        legacy.mainContext.insert(measured)
        try legacy.mainContext.save()

        XCTAssertFalse(measured.isSplitStoreProjection)

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let published = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.sourceDeviceID == ListeningDeviceIdentity.legacySharedID }
        XCTAssertEqual(published.count, 2, "the year row plus its synthesized forever rollup")
        XCTAssertEqual(
            published.first { $0.periodKind == PlaySessionSummaryPeriod.forever.rawValue }?
                .totalSeconds,
            1_200
        )
    }
}
