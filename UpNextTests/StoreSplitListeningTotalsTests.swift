import SwiftData
import XCTest
@testable import UpNext

/// Per-account listening totals: the frozen pre-split baseline plus the sessions
/// recorded since.
///
/// The synced store carries no aggregates, so there is no second version of any
/// total to reconcile against. These tests pin the two things that keep it that
/// way — the baseline is written once and never moves, and migrated sessions are
/// never added on top of the baseline that already contains them.
final class StoreSplitListeningTotalsTests: XCTestCase {
    // MARK: - The account rule

    func testLifetimeIsBaselinePlusLiveSessions() {
        XCTAssertEqual(
            AccountListeningTotals.lifetimeSeconds(
                baselineSeconds: 1_000,
                liveSeconds: 250,
                migratedSeconds: 400
            ),
            1_250,
            "migrated sessions are inside the baseline; adding them again is the double-count"
        )
    }

    func testLifetimeFallsBackToMigratedSessionsWithoutABaseline() {
        XCTAssertEqual(
            AccountListeningTotals.lifetimeSeconds(
                baselineSeconds: nil,
                liveSeconds: 250,
                migratedSeconds: 400
            ),
            650,
            "with no baseline the migrated rows are the only record of the pre-split era"
        )
    }

    func testDeviceSharesAddToTheAccountTotal() {
        let shares = AccountListeningTotals.deviceShares(
            secondsByDevice: ["phone": 300, "mac": 100],
            baselineSeconds: 200
        )
        XCTAssertEqual(
            shares.map(\.deviceID),
            ["phone", ListeningDeviceIdentity.legacySharedID, "mac"],
            "ordered by contribution, so the biggest share reads first"
        )
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 1, accuracy: 0.000_001)
        XCTAssertEqual(shares[0].share, 0.5, accuracy: 0.000_001)
    }

    func testDeviceSharesOmitTheBaselineWhenThereIsNone() {
        let shares = AccountListeningTotals.deviceShares(
            secondsByDevice: ["phone": 300],
            baselineSeconds: nil
        )
        XCTAssertEqual(shares.map(\.deviceID), ["phone"])
        XCTAssertEqual(shares[0].share, 1, accuracy: 0.000_001)
    }

    // MARK: - Session rows

    /// The baseline covers every migrated session and nothing ever subtracts from
    /// it, so a live upsert must not quietly reclassify a migrated row as live.
    func testLiveUpsertDoesNotReclassifyAMigratedRow() async throws {
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
        context.insert(ListeningHistorySync(
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
        ))
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

        let stored = try XCTUnwrap(
            try ModelContext(userState)
                .fetch(FetchDescriptor<ListeningHistorySync>()).first
        )
        XCTAssertTrue(stored.isLegacyMigrated)
    }

    /// Publishing a session must not create anything but the session. An
    /// aggregate written here would immediately be a second version of a number
    /// the sessions already carry.
    func testPublishingASessionCreatesNoAggregate() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-1"
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await StoreSplitListeningHistorySyncWriter(modelContainer: userState).upsert(
            StoreSplitListeningHistorySnapshot(
                id: "session-1",
                identity: identity,
                podcastName: "Example",
                episodeTitle: "Episode 1",
                sourceDeviceID: "device-a",
                sourceDeviceName: "Phone",
                deviceModel: "iPhone",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(600),
                startPosition: 0,
                endPosition: 600,
                listenedSeconds: 600,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                endedCleanly: true
            )
        )

        let context = ModelContext(userState)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ListeningHistorySync>()).count, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ListeningBaselineSync>()).count, 0,
            "only the migration writes a baseline, and it writes it once"
        )
    }

    // MARK: - Baseline capture

    @MainActor
    func testBaselineCapturesLifetimeFromYearSummariesOnly() throws {
        let (legacy, userState) = try makeStores()
        let feed = URL(string: "https://example.com/feed.xml")!
        insertLegacySummary(feed: feed, kind: .year, seconds: 3_600, in: legacy)
        insertLegacySummary(feed: feed, kind: .year, seconds: 1_800, in: legacy, yearOffset: 1)
        // Inside a year already counted — including it would double-count.
        insertLegacySummary(feed: feed, kind: .month, seconds: 1_800, in: legacy)
        try legacy.mainContext.save()

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let baselines = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(baselines[0].totalSeconds, 5_400)
    }

    /// The defect this design removes: a total that can be re-derived from data
    /// the sync itself produced can ratchet upwards and never come back down.
    /// A write-once constant cannot.
    @MainActor
    func testBaselineIsWriteOnceAndDoesNotMoveOnRecapture() throws {
        let (legacy, userState) = try makeStores()
        let feed = URL(string: "https://example.com/feed.xml")!
        insertLegacySummary(feed: feed, kind: .year, seconds: 3_600, in: legacy)
        try legacy.mainContext.save()

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        // The legacy table grows — a re-import, a rebuild, anything.
        insertLegacySummary(feed: feed, kind: .year, seconds: 9_000, in: legacy, yearOffset: 2)
        try legacy.mainContext.save()

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let baselines = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(
            baselines[0].totalSeconds, 3_600,
            "the baseline is a constant from the moment of capture; recapture must not move it"
        )
    }

    /// A store whose year-level rollups were pruned must still yield a baseline.
    /// Summing within one tier is safe; summing across tiers is not, which is why
    /// the capture picks the coarsest tier present rather than everything.
    @MainActor
    func testBaselineFallsBackToTheCoarsestAvailableTier() throws {
        let (legacy, userState) = try makeStores()
        let feed = URL(string: "https://example.com/feed.xml")!
        insertLegacySummary(feed: feed, kind: .week, seconds: 600, in: legacy)
        insertLegacySummary(feed: feed, kind: .day, seconds: 600, in: legacy)
        try legacy.mainContext.save()

        _ = StoreSplitMigrationService.rebuildListeningSummaries(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let baselines = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(
            baselines[0].totalSeconds, 600,
            "the week tier is used and the day rows inside it are not added on top"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeStores() throws -> (ModelContainer, ModelContainer) {
        (
            try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func insertLegacySummary(
        feed: URL,
        kind: PlaySessionSummaryPeriod,
        seconds: Double,
        in container: ModelContainer,
        yearOffset: Int = 0
    ) {
        var components = DateComponents()
        components.year = 2023 + yearOffset
        components.month = 1
        components.day = 1
        let start = Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
        container.mainContext.insert(PlaySessionSummary(
            id: UUID(),
            periodKind: kind.rawValue,
            periodStart: start,
            podcastFeed: feed,
            podcastName: "Example",
            totalSeconds: seconds
        ))
    }
}
