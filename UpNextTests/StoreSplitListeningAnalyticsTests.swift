import SwiftData
import XCTest
@testable import UpNext

@MainActor
final class StoreSplitListeningAnalyticsTests: XCTestCase {
    func testLocalAnalyticsCacheIsDurableAndRetrySafe() async throws {
        let cache = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let writer = StoreSplitLocalAnalyticsWriter(modelContainer: cache)
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:episode"
        )
        let cachedPodcast = CachedPodcast(
            id: identity.feedURL,
            feedURL: identity.feedURL,
            title: "Podcast",
            feed: URL(string: identity.feedURL)
        )
        let cachedEpisode = CachedEpisode(
            id: identity.key,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            guid: "episode",
            title: "Episode",
            url: URL(string: "https://example.com/episode.mp3")
        )
        cachedEpisode.podcast = cachedPodcast
        cache.mainContext.insert(cachedPodcast)
        cache.mainContext.insert(cachedEpisode)
        try cache.mainContext.save()
        // Inside the writer's 30-day retention window: an epoch-anchored date
        // would be pruned by `pruneExpiredSessions` before the assertions run.
        let start = Calendar.current.startOfDay(for: .now)
            .addingTimeInterval(10 * 3_600 + 30 * 60)
        let end = start.addingTimeInterval(5_400)
        let snapshot = StoreSplitLocalAnalyticsSessionSnapshot(
            sessionID: UUID().uuidString,
            identity: identity,
            podcastName: "Podcast",
            episodeTitle: "Episode",
            sourceDeviceID: "phone",
            sourceDeviceName: "iPhone",
            deviceModel: "iPhone",
            osVersion: "26.0",
            appVersion: "1",
            startedAt: start,
            endedAt: end,
            startPosition: 0,
            endPosition: 5_400,
            silenceGapTimeSavedSeconds: 90,
            playbackRateTimeSavedSeconds: 300,
            endedCleanly: true,
            rateSegments: [
                StoreSplitLocalRateSegmentSnapshot(
                    rate: 1.5,
                    startTime: start,
                    startPosition: 0,
                    endTime: end,
                    endPosition: 5_400
                )
            ]
        )

        await writer.upsert(snapshot)
        await writer.upsert(snapshot)

        let context = ModelContext(cache)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CachedPlaySession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CachedRateSegment>()), 1)
        let hours = try context.fetch(FetchDescriptor<CachedHourlyListeningStat>())
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.totalSeconds }, 5_400, accuracy: 0.001)
        XCTAssertEqual(
            hours.reduce(0) { $0 + $1.playbackRateTimeSavedSeconds },
            300,
            accuracy: 0.001
        )

        let rebuiltRuntime = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let projection = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: cache,
            runtimeContainer: rebuiltRuntime
        )
        XCTAssertEqual(projection.playSessions, 1)
        XCTAssertEqual(projection.hourlyStats, 2)
        XCTAssertEqual(
            try rebuiltRuntime.mainContext.fetch(FetchDescriptor<ListeningStat>())
                .reduce(0) { $0 + ($1.totalSeconds ?? 0) },
            5_400,
            accuracy: 0.001
        )
    }

    func testLiveSummariesAddDevicesAndRetryDoesNotDoubleCount() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let writer = StoreSplitListeningHistorySyncWriter(modelContainer: userState)
        let feed = "https://example.com/feed.xml"
        let first = historySnapshot(
            id: "phone-session",
            feed: feed,
            deviceID: "phone",
            deviceName: "iPhone",
            start: Date(timeIntervalSince1970: 1_000),
            duration: 60
        )
        let second = historySnapshot(
            id: "mac-session",
            feed: feed,
            deviceID: "mac",
            deviceName: "Mac",
            start: Date(timeIntervalSince1970: 2_000),
            duration: 120
        )

        await writer.upsert(first)
        await writer.upsert(second)
        await writer.upsert(first)

        let context = ModelContext(userState)
        let forever = try context.fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.periodKind == PlaySessionSummaryPeriod.forever.rawValue }
        XCTAssertEqual(Set(forever.compactMap(\.sourceDeviceID)), ["phone", "mac"])
        XCTAssertEqual(
            ListeningSummaryAggregation.globalStatistics(from: forever).totalSeconds,
            180,
            accuracy: 0.001
        )
    }

    func testLiveSummarySplitsSessionAcrossCalendarBoundaries() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let writer = StoreSplitListeningHistorySyncWriter(modelContainer: userState)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 15,
            hour: 23
        )))

        await writer.upsert(historySnapshot(
            id: "cross-midnight",
            feed: "https://example.com/feed.xml",
            deviceID: "phone",
            deviceName: "iPhone",
            start: start,
            duration: 7_200
        ))

        let daily = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.periodKind == PlaySessionSummaryPeriod.day.rawValue }
            .sorted { $0.periodStart < $1.periodStart }
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily[0].totalSeconds, 3_600, accuracy: 0.001)
        XCTAssertEqual(daily[1].totalSeconds, 3_600, accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.totalSeconds }, 7_200, accuracy: 0.001)
    }

    func testCrossDeviceHistoryProjectsOnceAndRebuildsStatistics() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = runtime.mainContext
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            publishDate: Date(timeIntervalSince1970: 100),
            url: URL(string: "https://example.com/episode.mp3")!,
            podcast: podcast,
            duration: 3_600,
            author: "Author",
            source: .feedDownload
        )
        context.insert(podcast)
        context.insert(episode)
        try context.save()

        let writer = StoreSplitListeningHistorySyncWriter(modelContainer: userState)
        await writer.upsert(historySnapshot(
            id: "phone",
            feed: podcast.feed!.absoluteString,
            deviceID: "phone",
            deviceName: "iPhone",
            start: Date(timeIntervalSince1970: 1_000),
            duration: 60
        ))
        await writer.upsert(historySnapshot(
            id: "mac",
            feed: podcast.feed!.absoluteString,
            deviceID: "mac",
            deviceName: "Mac",
            start: Date(timeIntervalSince1970: 2_000),
            duration: 120
        ))

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            projectListeningHistoryToLegacy: true
        )
        await PlaySessionTrackerActor(modelContainer: runtime).rebuildListeningStats()

        let projected = ModelContext(runtime)
        let sessions = try projected.fetch(FetchDescriptor<PlaySession>())
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.compactMap(\.sourceDeviceName)), ["iPhone", "Mac"])
        let stats = try projected.fetch(FetchDescriptor<ListeningStat>())
        XCTAssertEqual(
            stats.reduce(0) { $0 + ($1.totalSeconds ?? 0) },
            180,
            accuracy: 0.001
        )
    }

    func testMigratedHistoryDoesNotEnterLiveDeviceSummary() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = userState.mainContext
        let migrated = ListeningHistorySync(
            id: "migrated",
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:episode",
            sourceDeviceID: "phone",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            listenedSeconds: 60,
            isLegacyMigrated: true
        )
        context.insert(migrated)
        try context.save()

        let writer = StoreSplitListeningHistorySyncWriter(modelContainer: userState)
        await writer.upsert(historySnapshot(
            id: "new",
            feed: migrated.feedURL,
            deviceID: "phone",
            deviceName: "iPhone",
            start: Date(timeIntervalSince1970: 2_000),
            duration: 120
        ))

        let summaries = try ModelContext(userState)
            .fetch(FetchDescriptor<ListeningSummarySync>())
            .filter { $0.periodKind == PlaySessionSummaryPeriod.forever.rawValue }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].totalSeconds, 120, accuracy: 0.001)
    }

    func testLegacyMigrationBackfillsLocalRawAnalyticsAndMarksHistory() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cache = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let context = legacy.mainContext
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "legacy-episode",
            title: "Legacy episode",
            publishDate: Date(timeIntervalSince1970: 100),
            url: URL(string: "https://example.com/legacy.mp3")!,
            podcast: podcast,
            duration: 600,
            author: "Author",
            source: .feedDownload
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(180)
        let session = PlaySession(
            id: UUID(),
            episode: episode,
            sourceDeviceID: "legacy-phone",
            sourceDeviceName: "Old iPhone",
            startTime: start,
            endTime: end,
            startPosition: 0,
            endPosition: 180,
            segments: [RateSegment(
                rate: 1.5,
                startTime: start,
                startPosition: 0,
                endTime: end,
                endPosition: 180
            )],
            endedCleanly: true
        )
        context.insert(podcast)
        context.insert(episode)
        context.insert(session)
        try context.save()

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: legacy,
            userStateContainer: userState,
            cacheContainer: cache,
            includeAIContent: false
        )

        let user = ModelContext(userState)
        let histories = try user.fetch(FetchDescriptor<ListeningHistorySync>())
        XCTAssertEqual(histories.count, 1)
        XCTAssertTrue(histories[0].isLegacyMigrated)
        let local = ModelContext(cache)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CachedPlaySession>()), 1)
        XCTAssertEqual(try local.fetchCount(FetchDescriptor<CachedRateSegment>()), 1)
        XCTAssertEqual(
            try local.fetch(FetchDescriptor<CachedHourlyListeningStat>())
                .reduce(0) { $0 + $1.totalSeconds },
            180,
            accuracy: 0.001
        )
    }

    private func historySnapshot(
        id: String,
        feed: String,
        deviceID: String,
        deviceName: String,
        start: Date,
        duration: TimeInterval
    ) -> StoreSplitListeningHistorySnapshot {
        StoreSplitListeningHistorySnapshot(
            id: id,
            identity: EpisodeStableIdentity(
                feedURL: feed,
                episodeID: "guid:episode"
            ),
            podcastName: "Podcast",
            episodeTitle: "Episode",
            sourceDeviceID: deviceID,
            sourceDeviceName: deviceName,
            deviceModel: deviceName,
            startedAt: start,
            endedAt: start.addingTimeInterval(duration),
            startPosition: 0,
            endPosition: duration,
            listenedSeconds: duration,
            silenceGapTimeSavedSeconds: 0,
            playbackRateTimeSavedSeconds: 0,
            endedCleanly: true
        )
    }
}
