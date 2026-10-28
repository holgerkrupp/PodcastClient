import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitIncrementalListeningHistoryVerificationTests: XCTestCase {
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

    @MainActor
    private func makeEpisode(in context: ModelContext) -> Episode {
        let podcast = Podcast(feed: URL(string: "https://example.com/verification.xml")!)
        podcast.title = "Verification fixture"
        podcast.metaData?.isSubscribed = true
        let episode = Episode(
            guid: "verification-episode",
            title: "Verification episode",
            publishDate: Date(timeIntervalSince1970: 1_600_000_000),
            url: URL(string: "https://audio.example.com/verification.mp3")!,
            podcast: podcast,
            duration: 3_600
        )
        context.insert(podcast)
        context.insert(episode)
        podcast.episodes = [episode]
        return episode
    }

    @MainActor
    private func completeBackfillCheckpoints(in cache: ModelContainer) throws {
        let context = ModelContext(cache)
        for phase in StoreSplitMigrationService.slicePhaseOrder
        where phase != StoreSplitMigrationService.Phase.listeningHistoryVerification {
            context.insert(StoreSplitMigrationCheckpoint(
                id: StoreSplitMigrationService.checkpointID(for: phase),
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: phase,
                cursor: "0",
                startedAt: .now,
                completedAt: .now
            ))
        }
        try context.save()
    }

    @MainActor
    private func addMatchingHistory(
        for session: PlaySession,
        episode: Episode,
        to context: ModelContext
    ) {
        let identity = episode.stableEpisodeIdentity
        let startedAt = session.startTime!
        let endedAt = session.endTime!
        let id = ListeningHistoryIdentity.make(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: session.startPosition ?? 0,
            endPosition: session.endPosition ?? 0
        )
        context.insert(ListeningHistorySync(
            id: id,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            podcastName: session.podcastName ?? episode.displayPodcastTitle,
            episodeTitle: episode.title,
            sourceDeviceID: session.sourceDeviceID ?? "legacy-device",
            sourceDeviceName: session.sourceDeviceName ?? session.deviceModel ?? "Legacy device",
            deviceModel: session.deviceModel,
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: session.startPosition ?? 0,
            endPosition: session.endPosition ?? 0,
            listenedSeconds: endedAt.timeIntervalSince(startedAt),
            silenceGapTimeSavedSeconds: session.silenceGapTimeSavedSeconds ?? 0,
            playbackRateTimeSavedSeconds: PlaybackRateSavingsCalculator.secondsSaved(in: session),
            endedCleanly: session.endedCleanly == true,
            isLegacyMigrated: true,
            updatedAt: endedAt
        ))
    }

    @MainActor
    func testProductionStageVerifiesAllSessionsAcrossBoundedPages() async throws {
        let stores = try makeStores()
        let episode = makeEpisode(in: stores.legacy.mainContext)
        let destination = ModelContext(stores.userState)
        for index in 0..<141 {
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 1_000))
            let session = PlaySession(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1)),
                episode: episode,
                sourceDeviceID: "fixture-device",
                sourceDeviceName: "Fixture iPhone",
                deviceModel: "iPhone17,1",
                startTime: start,
                endTime: start.addingTimeInterval(300),
                startPosition: 12,
                endPosition: 312,
                silenceGapTimeSavedSeconds: 5,
                endedCleanly: true
            )
            stores.legacy.mainContext.insert(session)
            addMatchingHistory(for: session, episode: episode, to: destination)
        }
        try stores.legacy.mainContext.save()
        try destination.save()
        try completeBackfillCheckpoints(in: stores.cache)

        let verificationDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        let previousInvalidation = verificationDefaults.object(
            forKey: "storeSplit.verificationAttemptInvalidated.v1"
        )
        defer {
            if let previousInvalidation {
                verificationDefaults.set(
                    previousInvalidation,
                    forKey: "storeSplit.verificationAttemptInvalidated.v1"
                )
            } else {
                verificationDefaults.removeObject(
                    forKey: "storeSplit.verificationAttemptInvalidated.v1"
                )
            }
        }
        verificationDefaults.set(false, forKey: "storeSplit.verificationAttemptInvalidated.v1")
        let cacheContext = ModelContext(stores.cache)
        let staleVerification = StoreSplitMigrationVerification(
            id: StoreSplitMigrationVerifier.verificationID,
            migrationVersion: StoreSplitMigrationService.migrationVersion
        )
        staleVerification.verifiedAt = .now
        staleVerification.issues = []
        cacheContext.insert(staleVerification)
        try cacheContext.save()
        XCTAssertTrue(StoreSplitMigrationService.isMigrationVerified(cacheContainer: stores.cache))

        let first = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(first.phase, StoreSplitMigrationService.Phase.listeningHistoryVerification)
        XCTAssertGreaterThan(first.processed, 0)
        XCTAssertLessThan(first.processed, 141)
        XCTAssertEqual(first.status, .advanced)

        var totalProcessed = first.processed
        var last = first
        for _ in 0..<10 where last.status != .completed {
            last = await StoreSplitMigrationService.runSlice(
                legacyContainer: stores.legacy,
                userStateContainer: stores.userState,
                cacheContainer: stores.cache
            )
            totalProcessed += last.processed
        }
        XCTAssertEqual(last.status, .completed)
        XCTAssertEqual(totalProcessed, 141)

        let verificationCheckpointID = StoreSplitMigrationService.checkpointID(
            for: StoreSplitMigrationService.Phase.listeningHistoryVerification
        )
        let checkpoint = try XCTUnwrap(
            ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == verificationCheckpointID }
            )).first
        )
        XCTAssertNotNil(checkpoint.completedAt)
        XCTAssertEqual(checkpoint.scannedCount, 141)
        XCTAssertEqual(checkpoint.failedCount, 0)
        XCTAssertEqual(StoreSplitMigrationService.cursorDisplay(checkpoint.cursor ?? ""), "141")
        XCTAssertFalse(StoreSplitMigrationService.isMigrationVerified(cacheContainer: stores.cache))
        let verificationID = StoreSplitMigrationVerifier.verificationID
        let invalidatedVerification = try XCTUnwrap(
            ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationVerification>(
                predicate: #Predicate {
                    $0.id == verificationID
                }
            )).first
        )
        XCTAssertNil(invalidatedVerification.verifiedAt)
        XCTAssertEqual(invalidatedVerification.issues, ["verification_in_progress"])
    }

    @MainActor
    func testMissingSessionBlocksStageWithoutAdvancingCursor() async throws {
        let stores = try makeStores()
        let episode = makeEpisode(in: stores.legacy.mainContext)
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        let session = PlaySession(
            id: UUID(uuidString: "A35A72D4-3306-4C78-AD89-19A138AFE807"),
            episode: episode,
            sourceDeviceID: "fixture-device",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            startPosition: 0,
            endPosition: 120,
            endedCleanly: true
        )
        stores.legacy.mainContext.insert(session)
        try stores.legacy.mainContext.save()
        try completeBackfillCheckpoints(in: stores.cache)

        let priorVerification = StoreSplitMigrationVerification(
            id: StoreSplitMigrationVerifier.verificationID,
            migrationVersion: StoreSplitMigrationService.migrationVersion
        )
        priorVerification.verifiedAt = Date(timeIntervalSince1970: 1_700_099_000)
        priorVerification.issues = []
        let cacheContext = ModelContext(stores.cache)
        cacheContext.insert(priorVerification)
        try cacheContext.save()
        let verificationDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        let invalidatedKey = "storeSplit.verificationAttemptInvalidated.v1"
        let previousInvalidationValue = verificationDefaults.object(forKey: invalidatedKey)
        defer {
            if let previousInvalidationValue {
                verificationDefaults.set(previousInvalidationValue, forKey: invalidatedKey)
            } else {
                verificationDefaults.removeObject(forKey: invalidatedKey)
            }
        }
        verificationDefaults.set(false, forKey: invalidatedKey)
        XCTAssertTrue(StoreSplitMigrationService.isMigrationVerified(cacheContainer: stores.cache))

        let report = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.error, "listening_history_verification_missing_record")
        XCTAssertFalse(StoreSplitMigrationService.isMigrationVerified(cacheContainer: stores.cache))
        XCTAssertNil(StoreSplitMigrationVerifier.latestVerification(cacheContainer: stores.cache))

        let verificationCheckpointID = StoreSplitMigrationService.checkpointID(
            for: StoreSplitMigrationService.Phase.listeningHistoryVerification
        )
        let checkpoint = try XCTUnwrap(
            ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == verificationCheckpointID }
            )).first
        )
        XCTAssertNil(checkpoint.completedAt)
        XCTAssertEqual(StoreSplitMigrationService.cursorDisplay(checkpoint.cursor ?? ""), "0")
        XCTAssertEqual(checkpoint.failedCount, 1)

        let destination = ModelContext(stores.userState)
        addMatchingHistory(for: session, episode: episode, to: destination)
        try destination.save()
        let retried = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(retried.status, .completed)

        let recoveredCheckpoint = try XCTUnwrap(
            ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == verificationCheckpointID }
            )).first
        )
        XCTAssertNotNil(recoveredCheckpoint.completedAt)
        XCTAssertEqual(StoreSplitMigrationService.cursorDisplay(recoveredCheckpoint.cursor ?? ""), "1")
        XCTAssertEqual(recoveredCheckpoint.failedCount, 0)
    }

    @MainActor
    func testNewerCloudRecordIsPreservedAndAccepted() async throws {
        let stores = try makeStores()
        let episode = makeEpisode(in: stores.legacy.mainContext)
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let session = PlaySession(
            id: UUID(),
            episode: episode,
            sourceDeviceID: "legacy-device",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            startPosition: 0,
            endPosition: 120,
            endedCleanly: true
        )
        stores.legacy.mainContext.insert(session)
        try stores.legacy.mainContext.save()

        let destination = ModelContext(stores.userState)
        addMatchingHistory(for: session, episode: episode, to: destination)
        let identity = episode.stableEpisodeIdentity
        let historyID = ListeningHistoryIdentity.make(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            startPosition: 0,
            endPosition: 120
        )
        let newer = try XCTUnwrap(destination.fetch(FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate { $0.id == historyID }
        )).first)
        newer.updatedAt = start.addingTimeInterval(600)
        newer.episodeTitle = "Newer device title"
        try destination.save()
        try completeBackfillCheckpoints(in: stores.cache)

        let report = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(report.status, .completed)

        let persisted = try XCTUnwrap(destination.fetch(FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate { $0.id == historyID }
        )).first)
        XCTAssertEqual(persisted.episodeTitle, "Newer device title")
        XCTAssertEqual(persisted.updatedAt, start.addingTimeInterval(600))
    }

    @MainActor
    func testIncompleteSessionRequiresCacheMaterializationBeforeCursorAdvances() async throws {
        let stores = try makeStores()
        let episode = makeEpisode(in: stores.legacy.mainContext)
        let startedAt = Date(timeIntervalSince1970: 1_700_300_000)
        let session = PlaySession(
            id: nil,
            episode: episode,
            sourceDeviceID: "fixture-device",
            sourceDeviceName: "Fixture iPhone",
            deviceModel: "iPhone17,1",
            startTime: startedAt,
            endTime: nil,
            startPosition: 23,
            endPosition: nil,
            silenceGapTimeSavedSeconds: 2,
            endedCleanly: false
        )
        stores.legacy.mainContext.insert(session)
        try stores.legacy.mainContext.save()
        try completeBackfillCheckpoints(in: stores.cache)

        let first = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.error, "listening_history_verification_missing_incomplete_cache_record")

        let checkpointID = StoreSplitMigrationService.checkpointID(
            for: StoreSplitMigrationService.Phase.listeningHistoryVerification
        )
        var checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == checkpointID }
            )
        ).first)
        XCTAssertEqual(StoreSplitMigrationService.cursorDisplay(checkpoint.cursor ?? ""), "0")
        XCTAssertNil(checkpoint.completedAt)

        let identity = episode.stableEpisodeIdentity
        let cachedID = StableIdentityKey.uuid(for: StableIdentityKey.make(
            identity.key,
            String(Int(startedAt.timeIntervalSince1970))
        )).uuidString
        let cacheContext = ModelContext(stores.cache)
        cacheContext.insert(CachedPlaySession(
            id: cachedID,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            podcastName: episode.displayPodcastTitle,
            episodeTitle: episode.title,
            sourceDeviceID: "fixture-device",
            sourceDeviceName: "Fixture iPhone",
            deviceModel: "iPhone17,1",
            startedAt: startedAt,
            endedAt: nil,
            startPosition: 23,
            endPosition: nil,
            silenceGapTimeSavedSeconds: 2,
            playbackRateTimeSavedSeconds: 0,
            endedCleanly: false,
            updatedAt: startedAt
        ))
        try cacheContext.save()

        let retried = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(retried.status, .completed)
        checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == checkpointID }
            )
        ).first)
        XCTAssertEqual(StoreSplitMigrationService.cursorDisplay(checkpoint.cursor ?? ""), "1")
        XCTAssertNotNil(checkpoint.completedAt)
        XCTAssertEqual(checkpoint.failedCount, 0)
    }
}
