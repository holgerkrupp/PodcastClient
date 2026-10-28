import SwiftData
import XCTest
@testable import UpNext

/// Regression fixtures for the legacy listening-history migration boundary.
/// These tests assert semantic coverage rather than destination row counts.
final class StoreSplitListeningHistoryMigrationRegressionTests: XCTestCase {
    private struct Stores {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    @MainActor
    private func makeStores() throws -> Stores {
        Stores(
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            userState: try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    func testBackgroundExpirationCancellationReachesStoreWorker() async {
        let worker = Task.detached {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return Task.isCancelled
        }
        let operation = Task {
            await StoreSplitTaskCancellation.awaitValue(of: worker)
        }

        operation.cancel()
        let workerObservedCancellation = await operation.value
        XCTAssertTrue(workerObservedCancellation)
    }

    @MainActor
    func testCacheReadinessRequiresMaterializedFeedEvidence() throws {
        let stores = try makeStores()
        let feed = URL(string: "https://example.com/readiness.xml")!
        _ = addPodcast(feedURL: feed, episodes: [], to: stores.legacy.mainContext)
        try stores.legacy.mainContext.save()

        let pending = StoreSplitFeedCacheReadiness.read(
            legacyContext: ModelContext(stores.legacy),
            cacheContext: ModelContext(stores.cache)
        )
        XCTAssertEqual(pending.status, .incomplete)
        XCTAssertEqual(pending.unverifiedRecoverabilityFeedCount, 1)
        XCTAssertEqual(pending.rssRecoverablePendingFeedCount, 0)
        XCTAssertFalse(pending.isSafeForCutover)

        let materialized = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Readiness fixture"],
            episodeRows: [],
            isCompleteFeed: true,
            cacheContainer: stores.cache
        )
        XCTAssertTrue(materialized.completed)

        let ready = StoreSplitFeedCacheReadiness.read(
            legacyContext: ModelContext(stores.legacy),
            cacheContext: ModelContext(stores.cache)
        )
        XCTAssertEqual(ready.status, .ready)
        XCTAssertTrue(ready.isSafeForCutover)
    }

    @MainActor
    private func addPodcast(
        feedURL: URL,
        episodes: [(guid: String, title: String)],
        to context: ModelContext
    ) -> [Episode] {
        let podcast = Podcast(feed: feedURL)
        podcast.title = "Listening history fixture"
        podcast.metaData?.isSubscribed = true
        context.insert(podcast)
        let values = episodes.map { value in
            Episode(
                guid: value.guid,
                title: value.title,
                publishDate: Date(timeIntervalSince1970: 1_600_000_000),
                url: URL(string: "https://audio.example.com/\(value.guid).mp3")!,
                podcast: podcast,
                duration: 3_600
            )
        }
        for episode in values { context.insert(episode) }
        podcast.episodes = values
        return values
    }

    @MainActor
    private func drain(_ stores: Stores) async -> [StoreSplitSliceReport] {
        var reports: [StoreSplitSliceReport] = []
        for _ in 0..<2_000 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: stores.legacy,
                userStateContainer: stores.userState,
                cacheContainer: stores.cache
            )
            reports.append(report)
            switch report.status {
            case .completed, .cancelled, .failed:
                return reports
            case .advanced, .phaseCompleted:
                continue
            }
        }
        return reports
    }

    @MainActor
    func testCompletedSessionsPreserveStableIdentityAndSemanticFields() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let episode = try XCTUnwrap(addPodcast(
            feedURL: URL(string: "https://example.com/history.xml")!,
            episodes: [("history-episode", "History episode")],
            to: legacy
        ).first)
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let end = start.addingTimeInterval(600)
        let rateSegment = RateSegment(
            rate: 2,
            startTime: start.addingTimeInterval(120),
            startPosition: 120,
            endTime: start.addingTimeInterval(300),
            endPosition: 480
        )
        let session = PlaySession(
            id: UUID(uuidString: "A35A72D4-3306-4C78-AD89-19A138AFE807"),
            episode: episode,
            sourceDeviceID: "fixture-device-id",
            sourceDeviceName: "Fixture iPhone",
            deviceModel: "iPhone17,1",
            osVersion: "26.0",
            appVersion: "2026.36",
            startTime: start,
            endTime: end,
            startPosition: 42.5,
            endPosition: 631.25,
            silenceGapTimeSavedSeconds: 37.5,
            segments: [rateSegment],
            endedCleanly: true
        )
        session.podcastName = "Fixture podcast"
        rateSegment.parentSession = session
        legacy.insert(rateSegment)
        legacy.insert(session)
        try legacy.save()

        let reports = await drain(stores)
        XCTAssertEqual(reports.last?.status, .completed)

        let identity = episode.stableEpisodeIdentity
        let expectedID = ListeningHistoryIdentity.make(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            startedAt: start,
            endedAt: end,
            startPosition: 42.5,
            endPosition: 631.25
        )
        let destination = try XCTUnwrap(
            ModelContext(stores.userState).fetch(
                FetchDescriptor<ListeningHistorySync>(
                    predicate: #Predicate { $0.id == expectedID }
                )
            ).first
        )
        XCTAssertEqual(destination.id, expectedID)
        XCTAssertEqual(destination.feedURL, identity.feedURL)
        XCTAssertEqual(destination.episodeID, identity.episodeID)
        XCTAssertEqual(destination.startedAt, start)
        XCTAssertEqual(destination.endedAt, end)
        XCTAssertEqual(destination.listenedSeconds, 600, accuracy: 0.000_001)
        XCTAssertEqual(destination.startPosition, 42.5, accuracy: 0.000_001)
        XCTAssertEqual(destination.endPosition, 631.25, accuracy: 0.000_001)
        XCTAssertEqual(destination.silenceGapTimeSavedSeconds, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(destination.playbackRateTimeSavedSeconds, 180, accuracy: 0.000_001)
        XCTAssertEqual(destination.sourceDeviceID, "fixture-device-id")
        XCTAssertEqual(destination.sourceDeviceName, "Fixture iPhone")
        XCTAssertEqual(destination.deviceModel, "iPhone17,1")
        XCTAssertEqual(destination.podcastName, "Fixture podcast")
        XCTAssertEqual(destination.episodeTitle, "History episode")
        XCTAssertTrue(destination.endedCleanly)
        XCTAssertTrue(destination.isLegacyMigrated)
        XCTAssertEqual(destination.updatedAt, end)
    }

    @MainActor
    func testVerifierDetectsMissingMiddleSessionDespiteOtherDestinationSessions() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let episodes = addPodcast(
            feedURL: URL(string: "https://example.com/missing-middle.xml")!,
            episodes: [("one", "One"), ("two", "Two"), ("three", "Three")],
            to: legacy
        )
        for (index, episode) in episodes.enumerated() {
            let start = Date(timeIntervalSince1970: 1_700_100_000 + Double(index * 1_000))
            legacy.insert(PlaySession(
                id: UUID(uuidString: [
                    "00000000-0000-4000-8000-000000000001",
                    "00000000-0000-4000-8000-000000000002",
                    "00000000-0000-4000-8000-000000000003"
                ][index]),
                episode: episode,
                sourceDeviceID: "history-device",
                startTime: start,
                endTime: start.addingTimeInterval(120),
                startPosition: 0,
                endPosition: 120,
                endedCleanly: true
            ))
        }
        try legacy.save()
        let reports = await drain(stores)
        XCTAssertEqual(reports.last?.status, .completed)

        let userState = ModelContext(stores.userState)
        let history = try userState.fetch(FetchDescriptor<ListeningHistorySync>())
        XCTAssertEqual(history.count, 3)
        let missing = try XCTUnwrap(history.first { $0.episodeID.contains("guid:two") })
        userState.delete(missing)
        try userState.save()

        let verification = StoreSplitMigrationVerifier.verify(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertFalse(
            verification.isLossless,
            "a missing middle session must fail semantic verification even when two other rows remain; issues: \(verification.issues)"
        )
        XCTAssertTrue(
            verification.issues.contains { $0.contains(missing.id) || $0.hasPrefix("missing_listening_history:") },
            "verification should identify the missing stable history identity; issues: \(verification.issues)"
        )
    }

    @MainActor
    func testRepeatedMigrationDoesNotMutateOrDuplicateHistoryAndBaseline() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let feed = URL(string: "https://example.com/idempotent.xml")!
        let episode = try XCTUnwrap(addPodcast(
            feedURL: feed,
            episodes: [("idempotent", "Idempotent")],
            to: legacy
        ).first)
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        legacy.insert(PlaySession(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000011"),
            episode: episode,
            sourceDeviceID: "idempotent-device",
            startTime: start,
            endTime: start.addingTimeInterval(300),
            startPosition: 0,
            endPosition: 300,
            silenceGapTimeSavedSeconds: 20,
            endedCleanly: true
        ))
        legacy.insert(PlaySessionSummary(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000012"),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: Date(timeIntervalSince1970: 1_672_531_200),
            podcastFeed: feed,
            podcastName: "Idempotent podcast",
            totalSeconds: 300,
            silenceGapTimeSavedSeconds: 20,
            playbackRateTimeSavedSeconds: 10,
            activeHourCount: 1
        ))
        try legacy.save()

        let first = await drain(stores)
        XCTAssertEqual(first.last?.status, .completed)
        let before = try historySnapshot(stores.userState)
        let baselineBefore = try baselineSnapshot(stores.userState)

        let second = await drain(stores)
        XCTAssertEqual(second.last?.status, .completed)
        let after = try historySnapshot(stores.userState)
        let baselineAfter = try baselineSnapshot(stores.userState)
        XCTAssertEqual(after, before)
        XCTAssertEqual(baselineAfter, baselineBefore)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(baselineAfter.count, 1)
        XCTAssertEqual(second.reduce(0) { $0 + $1.mutations }, 0)
    }

    @MainActor
    func testBaselinePreservesPerFeedListeningAndSavedTimeComponents() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let feedA = URL(string: "https://example.com/baseline-a.xml")!
        let feedB = URL(string: "https://example.com/baseline-b.xml")!
        func summary(
            _ feed: URL,
            id: String,
            year: Int,
            seconds: Double,
            silence: Double,
            rate: Double
        ) -> PlaySessionSummary {
            PlaySessionSummary(
                id: UUID(uuidString: id),
                periodKind: PlaySessionSummaryPeriod.year.rawValue,
                periodStart: Calendar(identifier: .gregorian).date(from: DateComponents(year: year)),
                podcastFeed: feed,
                podcastName: feed.lastPathComponent,
                totalSeconds: seconds,
                silenceGapTimeSavedSeconds: silence,
                playbackRateTimeSavedSeconds: rate,
                activeHourCount: 1
            )
        }
        legacy.insert(summary(
            feedA,
            id: "00000000-0000-4000-8000-000000000021",
            year: 2023,
            seconds: 3_600,
            silence: 300,
            rate: 120
        ))
        legacy.insert(summary(
            feedA,
            id: "00000000-0000-4000-8000-000000000022",
            year: 2024,
            seconds: 1_800,
            silence: 90,
            rate: 60
        ))
        legacy.insert(summary(
            feedB,
            id: "00000000-0000-4000-8000-000000000023",
            year: 2024,
            seconds: 600,
            silence: 50,
            rate: 25
        ))
        try legacy.save()

        let reports = await drain(stores)
        XCTAssertEqual(reports.last?.status, .completed)
        let baselines = try ModelContext(stores.userState)
            .fetch(FetchDescriptor<ListeningBaselineSync>())
        let byFeed = Dictionary(uniqueKeysWithValues: baselines.map { ($0.feedURL, $0) })
        let normalizedA = PodcastFeedIdentity.normalizedFeedURLString(feedA)
        let normalizedB = PodcastFeedIdentity.normalizedFeedURLString(feedB)
        XCTAssertEqual(Set(byFeed.keys), [normalizedA, normalizedB])
        let baselineA = try XCTUnwrap(byFeed[normalizedA])
        let baselineB = try XCTUnwrap(byFeed[normalizedB])
        XCTAssertEqual(baselineA.totalSeconds, 5_400, accuracy: 0.000_001)
        XCTAssertEqual(baselineA.silenceGapTimeSavedSeconds, 390, accuracy: 0.000_001)
        XCTAssertEqual(baselineA.playbackRateTimeSavedSeconds, 180, accuracy: 0.000_001)
        XCTAssertEqual(baselineB.totalSeconds, 600, accuracy: 0.000_001)
        XCTAssertEqual(baselineB.silenceGapTimeSavedSeconds, 50, accuracy: 0.000_001)
        XCTAssertEqual(baselineB.playbackRateTimeSavedSeconds, 25, accuracy: 0.000_001)
        XCTAssertTrue(baselines.allSatisfy { $0.capturedByDeviceID == ListeningDeviceIdentity.current().id })
    }

    @MainActor
    func testNewerDestinationHistoryIsNotOverwrittenByLegacyMigration() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let feed = URL(string: "https://example.com/conflict.xml")!
        let episode = try XCTUnwrap(addPodcast(
            feedURL: feed,
            episodes: [("conflict", "Conflict episode")],
            to: legacy
        ).first)
        let start = Date(timeIntervalSince1970: 1_700_300_000)
        let end = start.addingTimeInterval(500)
        let identity = episode.stableEpisodeIdentity
        let stableID = ListeningHistoryIdentity.make(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            startedAt: start,
            endedAt: end,
            startPosition: 25,
            endPosition: 425
        )
        legacy.insert(PlaySession(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000031"),
            episode: episode,
            sourceDeviceID: "legacy-device",
            sourceDeviceName: "Old phone",
            startTime: start,
            endTime: end,
            startPosition: 25,
            endPosition: 425,
            silenceGapTimeSavedSeconds: 12,
            endedCleanly: false
        ))
        try legacy.save()

        let remoteDate = end.addingTimeInterval(10_000)
        let userState = stores.userState.mainContext
        userState.insert(ListeningHistorySync(
            id: stableID,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            podcastName: "Newer remote name",
            episodeTitle: "Newer remote title",
            sourceDeviceID: "remote-device",
            sourceDeviceName: "Newer device",
            deviceModel: "Remote model",
            startedAt: start,
            endedAt: end,
            startPosition: 25,
            endPosition: 425,
            listenedSeconds: 450,
            silenceGapTimeSavedSeconds: 9,
            playbackRateTimeSavedSeconds: 30,
            endedCleanly: true,
            updatedAt: remoteDate
        ))
        try userState.save()

        let reports = await drain(stores)
        XCTAssertEqual(reports.last?.status, .completed)
        let stored = try XCTUnwrap(
            ModelContext(stores.userState).fetch(
                FetchDescriptor<ListeningHistorySync>(
                    predicate: #Predicate { $0.id == stableID }
                )
            ).first
        )
        XCTAssertEqual(stored.updatedAt, remoteDate)
        XCTAssertEqual(stored.sourceDeviceID, "remote-device")
        XCTAssertEqual(stored.sourceDeviceName, "Newer device")
        XCTAssertEqual(stored.deviceModel, "Remote model")
        XCTAssertEqual(stored.podcastName, "Newer remote name")
        XCTAssertEqual(stored.episodeTitle, "Newer remote title")
        XCTAssertEqual(stored.listenedSeconds, 450, accuracy: 0.000_001)
        XCTAssertEqual(stored.silenceGapTimeSavedSeconds, 9, accuracy: 0.000_001)
        XCTAssertEqual(stored.playbackRateTimeSavedSeconds, 30, accuracy: 0.000_001)
        XCTAssertTrue(stored.endedCleanly)
        XCTAssertFalse(stored.isLegacyMigrated)
    }

    @MainActor
    private func historySnapshot(_ container: ModelContainer) throws -> [String: String] {
        try ModelContext(container).fetch(FetchDescriptor<ListeningHistorySync>())
            .reduce(into: [:]) { result, value in
                result[value.id] = [
                    value.feedURL,
                    value.episodeID,
                    value.sourceDeviceID,
                    value.startedAt.timeIntervalSince1970.description,
                    value.endedAt.timeIntervalSince1970.description,
                    value.startPosition.description,
                    value.endPosition.description,
                    value.listenedSeconds.description,
                    value.silenceGapTimeSavedSeconds.description,
                    value.playbackRateTimeSavedSeconds.description,
                    value.updatedAt.timeIntervalSince1970.description,
                    String(value.isLegacyMigrated)
                ].joined(separator: "|")
            }
    }

    @MainActor
    private func baselineSnapshot(_ container: ModelContainer) throws -> [String: String] {
        try ModelContext(container).fetch(FetchDescriptor<ListeningBaselineSync>())
            .reduce(into: [:]) { result, value in
                result[value.id] = [
                    value.feedURL,
                    value.totalSeconds.description,
                    value.silenceGapTimeSavedSeconds.description,
                    value.playbackRateTimeSavedSeconds.description,
                    value.capturedByDeviceID ?? ""
                ].joined(separator: "|")
            }
    }
}
