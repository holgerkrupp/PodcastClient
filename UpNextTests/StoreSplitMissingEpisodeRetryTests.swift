import Foundation
import Darwin
import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitMissingEpisodeRetryTests: XCTestCase {
    private let feed = "https://example.com/retry.xml"
    private let episodeID = "guid:historical"
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func reference(_ stream: StoreSplitUserStateStream, id: String,
                           updatedAt: Date? = nil, digest: String = "fixture") -> StoreSplitMissingEpisodeReference {
        .init(stream: stream, sourceRecordID: id, feedURL: feed,
              episodeID: episodeID, sourceUpdatedAt: updatedAt ?? timestamp, payloadDigest: digest)
    }

    @MainActor
    func testProjectedHistorySurvivesDisabledOrIncompleteImport() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let sessionID = UUID()
        let session = PlaySession(id: sessionID,
                                  appVersion: ListeningDeviceIdentity.splitStoreProjectionAppVersion,
                                  startTime: timestamp, endTime: timestamp.addingTimeInterval(30),
                                  startPosition: 0, endPosition: 30)
        legacy.mainContext.insert(session)
        try legacy.mainContext.save()
        let disabled = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.listeningHistory]
        )
        XCTAssertEqual(disabled.failed, 0)
        let incomplete = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: true, changedStreams: [.listeningHistory]
        )
        XCTAssertEqual(incomplete.failed, 0)
        let retained = try ModelContext(legacy).fetch(FetchDescriptor<PlaySession>())
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.id, sessionID)
    }

    @MainActor
    func testMissingHistoryEpisodeDoesNotRewriteAnExistingSession() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let sessionID = UUID()
        let end = timestamp.addingTimeInterval(30)
        legacy.mainContext.insert(PlaySession(id: sessionID, appVersion: "original",
                                             startTime: timestamp, endTime: end,
                                             startPosition: 0, endPosition: 30))
        user.mainContext.insert(ListeningHistorySync(
            id: "missing", feedURL: feed, episodeID: episodeID, sourceDeviceID: "other",
            startedAt: timestamp, endedAt: end, startPosition: 0, endPosition: 30,
            listenedSeconds: 30
        ))
        try legacy.mainContext.save()
        try user.mainContext.save()
        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: true, changedStreams: [.listeningHistory]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.unresolvedStreams.contains(.listeningHistory))
        let retained = try ModelContext(legacy).fetch(FetchDescriptor<PlaySession>())
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.id, sessionID)
        XCTAssertEqual(retained.first?.appVersion, "original")
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedMissingEpisodeReference>()), 1)
    }

    @MainActor
    func testDrainLeaseExcludesAnotherWorkerWithoutBlockingEnqueue() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let directory = try XCTUnwrap(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
        ))
        // A separate open file description represents another process holding
        // the OS lease, independently of the in-process mutex.
        let lease = open(directory.appendingPathComponent("StoreSplitMissingEpisodeRetry.drain.lock").path,
                         O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lease, 0)
        guard lease >= 0 else { return }
        defer { flock(lease, LOCK_UN); close(lease) }
        XCTAssertEqual(flock(lease, LOCK_EX | LOCK_NB), 0)
        try StoreSplitMissingEpisodeLedger.enqueue([reference(.episodeState, id: "state")], cacheContainer: cache)
        let competing = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache
        )
        XCTAssertEqual(competing.failed, 1)
        XCTAssertEqual(competing.examined, 0)
        XCTAssertEqual(try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache).count, 1)
    }

    @MainActor
    func testNewerAndEqualLocalPlaybackStateSurvivesImportAndRetry() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: feed)!)
        let episode = Episode(guid: "historical", title: "Historical", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast)
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        episode.metaData = metadata
        metadata.playPosition = 80
        metadata.stateUpdatedAt = timestamp.addingTimeInterval(0.5)
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(episode)
        legacy.mainContext.insert(metadata)
        try legacy.mainContext.save()
        let state = EpisodeStateSync(feedURL: feed, episodeID: episodeID, playPosition: 12, updatedAt: timestamp)
        user.mainContext.insert(state)
        try user.mainContext.save()

        let imported = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.episodeState]
        )
        XCTAssertEqual(imported.failed, 0)
        var saved = try XCTUnwrap(ModelContext(legacy).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(saved.playPosition, 80)
        XCTAssertEqual(saved.stateUpdatedAt, timestamp.addingTimeInterval(0.5))

        try StoreSplitMissingEpisodeLedger.enqueue([
            reference(.episodeState, id: state.id, digest: StoreSplitMissingEpisodeFingerprint.episodeState(state))
        ], cacheContainer: cache)
        let retried = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache, now: timestamp
        )
        XCTAssertEqual(retried.failed, 0)
        XCTAssertTrue(retried.projectionBlocked)
        saved = try XCTUnwrap(ModelContext(legacy).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(saved.playPosition, 80)
        XCTAssertEqual(saved.stateUpdatedAt, timestamp.addingTimeInterval(0.5))

        let edit = ModelContext(legacy)
        let local = try XCTUnwrap(edit.fetch(FetchDescriptor<Episode>()).first?.metaData)
        local.stateUpdatedAt = timestamp
        try edit.save()
        let equal = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.episodeState]
        )
        XCTAssertEqual(equal.failed, 0)
        XCTAssertTrue(equal.unresolvedStreams.contains(.episodeState))
        saved = try XCTUnwrap(ModelContext(legacy).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(saved.playPosition, 80)
        let equalRetry = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            now: timestamp.addingTimeInterval(901)
        )
        XCTAssertEqual(equalRetry.failed, 0)
        XCTAssertEqual(equalRetry.applied, 0)
        XCTAssertTrue(equalRetry.projectionBlocked)
        XCTAssertEqual(equalRetry.postponed, 1)
        state.playPosition = 80
        try user.mainContext.save()
        let identical = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.episodeState]
        )
        XCTAssertEqual(identical.failed, 0)
        XCTAssertFalse(identical.unresolvedStreams.contains(.episodeState))
    }

    @MainActor
    func testUnresolvedImportPersistsReferencesAndHoldsStreams() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let state = EpisodeStateSync(feedURL: feed, episodeID: episodeID, playPosition: 12, updatedAt: timestamp)
        let bookmark = BookmarkSync(id: UUID().uuidString, feedURL: feed, episodeID: episodeID,
                                    time: 20, updatedAt: timestamp)
        user.mainContext.insert(state)
        user.mainContext.insert(bookmark)
        try user.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.episodeState, .bookmarks]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.unresolvedStreams, [.episodeState, .bookmarks])
        let page = try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache)
        XCTAssertEqual(Set(page.map(\.stream)), [.episodeState, .bookmarks])
    }

    @MainActor
    func testUnsupportedIdentityOnLaterPageKeepsWholeStreamCursorUncommitted() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        for index in 0..<200 {
            let id = "guid:" + String(format: "%032d", index)
            user.mainContext.insert(EpisodeStateSync(feedURL: feed, episodeID: id,
                                                     playPosition: 1, updatedAt: timestamp))
        }
        user.mainContext.insert(EpisodeStateSync(
            feedURL: feed, episodeID: "hash:" + String(repeating: "a", count: 64),
            playPosition: 1, updatedAt: timestamp
        ))
        try user.mainContext.save()
        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            projectListeningHistoryToLegacy: false, changedStreams: [.episodeState]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.unresolvedStreams.contains(.episodeState))
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedMissingEpisodeReference>()), 201)
    }

    @MainActor
    func testStateAndBookmarkRemainPendingAfterEpisodeArrivesAndCacheReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache.sqlite")
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        let bookmarkID = UUID().uuidString
        let state = EpisodeStateSync(feedURL: feed, episodeID: episodeID, playPosition: 42,
                                     maxPlayPosition: 45, updatedAt: timestamp)
        let bookmark = BookmarkSync(id: bookmarkID, feedURL: feed, episodeID: episodeID,
                                    time: 17, title: "Sample", createdAt: timestamp, updatedAt: timestamp)
        user.mainContext.insert(state)
        user.mainContext.insert(bookmark)
        try user.mainContext.save()
        try StoreSplitMissingEpisodeLedger.enqueue([
            reference(.episodeState, id: state.id, digest: StoreSplitMissingEpisodeFingerprint.episodeState(state)),
            reference(.bookmarks, id: bookmarkID, digest: StoreSplitMissingEpisodeFingerprint.bookmark(bookmark))
        ], cacheContainer: cache)

        let first = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache, now: timestamp
        )
        XCTAssertEqual(first.postponed, 2)
        XCTAssertEqual(first.applied, 0)

        let podcast = Podcast(feed: URL(string: feed)!)
        let episode = Episode(guid: "historical", title: "Historical", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast)
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(episode)
        try legacy.mainContext.save()
        let reopened = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        let retry = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: reopened,
            now: timestamp.addingTimeInterval(901)
        )
        XCTAssertEqual(retry.failed, 0)
        XCTAssertTrue(retry.projectionBlocked)
        XCTAssertEqual(retry.applied, 0)
        XCTAssertEqual(try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: reopened, now: .distantFuture).count, 2)
        let target = ModelContext(legacy)
        let savedEpisode = try XCTUnwrap(target.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertNotEqual(savedEpisode.metaData?.playPosition, 42)
        XCTAssertTrue(try target.fetch(FetchDescriptor<Bookmark>()).isEmpty)
    }

    @MainActor
    func testNewerRevisionSurvivesStaleAcknowledgementAndUnchangedEnqueue() throws {
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let old = reference(.episodeState, id: "state")
        try StoreSplitMissingEpisodeLedger.enqueue([old], cacheContainer: cache)
        let first = try XCTUnwrap(StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache).first)
        try StoreSplitMissingEpisodeLedger.enqueue([old], cacheContainer: cache)
        XCTAssertEqual(try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache).first?.generation, first.generation)
        try StoreSplitMissingEpisodeLedger.enqueue([
            reference(.episodeState, id: "state", updatedAt: timestamp.addingTimeInterval(10))
        ], cacheContainer: cache)
        XCTAssertFalse(try StoreSplitMissingEpisodeLedger.acknowledge(first, cacheContainer: cache))
        XCTAssertEqual(try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache).count, 1)
    }

    @MainActor
    func testSameTimestampPayloadChangeRemainsUnresolved() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: feed)!)
        let episode = Episode(guid: "historical", title: "Historical", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast)
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(episode)
        try legacy.mainContext.save()
        let state = EpisodeStateSync(feedURL: feed, episodeID: episodeID, playPosition: 10, updatedAt: timestamp)
        user.mainContext.insert(state)
        try user.mainContext.save()
        try StoreSplitMissingEpisodeLedger.enqueue([
            reference(.episodeState, id: state.id, digest: StoreSplitMissingEpisodeFingerprint.episodeState(state))
        ], cacheContainer: cache)
        state.playPosition = 20
        try user.mainContext.save()

        let result = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache, now: timestamp
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.postponed, 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedMissingEpisodeReference>()), 1)
        XCTAssertNotEqual(episode.metaData?.playPosition, 20)
    }

    @MainActor
    func testReferencedCacheOnlyEpisodeRemainsPendingWithoutCreatingDuplicate() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        legacy.mainContext.insert(Podcast(feed: URL(string: feed)!))
        try legacy.mainContext.save()
        let cacheID = StableIdentityKey.make(feed, episodeID)
        cache.mainContext.insert(CachedEpisode(
            id: cacheID, feedURL: feed, episodeID: episodeID, guid: "historical",
            title: "Archive", url: URL(string: "https://example.com/archive.mp3")!, duration: 200
        ))
        cache.mainContext.insert(CachedChapter(id: "chapter", feedURL: feed, episodeID: cacheID,
                                               title: "Chapter", start: 10, typeRawValue: MarkerType.ai.rawValue))
        cache.mainContext.insert(CachedTranscriptLine(id: "line", feedURL: feed, episodeID: cacheID,
                                                      text: "Sample", startTime: 5, sourceRawValue: CachedTranscriptSource.ai.rawValue))
        try cache.mainContext.save()
        let state = EpisodeStateSync(feedURL: feed, episodeID: episodeID, playPosition: 30, updatedAt: timestamp)
        user.mainContext.insert(state)
        try user.mainContext.save()
        try StoreSplitMissingEpisodeLedger.enqueue([
            reference(.episodeState, id: state.id, digest: StoreSplitMissingEpisodeFingerprint.episodeState(state))
        ], cacheContainer: cache)
        let result = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache, now: timestamp
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.postponed, 1)
        XCTAssertEqual(result.cacheEpisodesMaterialized, 0)
        XCTAssertTrue(try ModelContext(legacy).fetch(FetchDescriptor<Episode>()).isEmpty)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedChapter>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedTranscriptLine>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedMissingEpisodeReference>()), 1)
    }

    @MainActor
    func testCancellationAndUnsupportedReferenceRemainDurable() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let user = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        try StoreSplitMissingEpisodeLedger.enqueue([reference(.queueEntries, id: "queue")], cacheContainer: cache)
        let cancelled = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache,
            shouldContinue: { false }
        )
        XCTAssertTrue(cancelled.cancelled)
        let retry = await StoreSplitMissingEpisodeRetryService.runPage(
            legacyContainer: legacy, userStateContainer: user, cacheContainer: cache, now: timestamp
        )
        XCTAssertEqual(retry.postponed, 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedMissingEpisodeReference>()), 1)
    }

    @MainActor
    func testPageBudgetAndPostponementAvoidStarvation() throws {
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let references = (0..<101).map { reference(.queueEntries, id: "queue-\($0)") }
        try StoreSplitMissingEpisodeLedger.enqueue(Array(references.prefix(100)), cacheContainer: cache)
        try StoreSplitMissingEpisodeLedger.enqueue(Array(references.suffix(1)), cacheContainer: cache)
        let first = try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache, limit: 40, now: timestamp)
        XCTAssertEqual(first.count, 40)
        let completed = try StoreSplitMissingEpisodeLedger.finishPage(
            projected: [], postponed: first, superseded: [],
            now: timestamp, cacheContainer: cache
        )
        XCTAssertEqual(completed.postponed, 40)
        let second = try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: cache, limit: 100, now: timestamp)
        XCTAssertEqual(second.count, 61)
        XCTAssertTrue(Set(first.map(\.sourceRecordID)).isDisjoint(with: Set(second.map(\.sourceRecordID))))
    }

    @MainActor
    func testExistingCacheSchemaOpensWithAdditiveRetryTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.sqlite")
        try createOldSchemaStore(url: url)
        let reopened = try ModelContainerManager.makeCacheContainer(storageURL: url)
        let feeds = try ModelContext(reopened).fetch(FetchDescriptor<CachedPodcast>())
        XCTAssertEqual(feeds.first?.feedURL, feed)
        try StoreSplitMissingEpisodeLedger.enqueue([reference(.bookmarks, id: "old-store")], cacheContainer: reopened)
        XCTAssertEqual(try StoreSplitMissingEpisodeLedger.duePage(cacheContainer: reopened).count, 1)
    }

    @MainActor
    private func createOldSchemaStore(url: URL) throws {
        let schema = Schema([
            StoreSplitMigrationCheckpoint.self, CachedListeningBaselineAggregate.self,
            CachedListeningBaselineSource.self, StoreSplitMigrationVerification.self,
            StoreSplitFeedCacheCheckpoint.self, CachedFeedExtensionElement.self,
            AppliedAIContentRevision.self, CachedPodcast.self, CachedEpisode.self,
            CachedChapter.self, CachedTranscriptLine.self, CachedTranscriptAlignment.self,
            CachedTranscriptSynchronizationJob.self, CachedTranscriptionRecord.self,
            CachedDownloadRecord.self, CachedPlaySession.self, CachedRateSegment.self,
            CachedHourlyListeningStat.self, AITranscriptSync.self, AITranscriptChunkSync.self,
            AIChapterSetSync.self, FeedAlias.self
        ])
        let config = ModelConfiguration("PodcastCache", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        container.mainContext.insert(CachedPodcast(id: feed, feedURL: feed))
        try container.mainContext.save()
    }
}
