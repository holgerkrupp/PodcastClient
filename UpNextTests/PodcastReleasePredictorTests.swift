import SwiftData
import XCTest
@testable import UpNext

final class PodcastReleasePredictorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testWeeklyPodcastUpdatedYesterdayPredictsNextWeek() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 9)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 29, 8))
        // A week away and recently refreshed: scheduling information, not urgency.
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, now: now, lastRefresh: now),
            PodcastBackgroundRefreshPriority.Tier.idle.rawValue
        )
    }

    func testMissedWeeklyReleaseRemainsUrgentTheFollowingMorning() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 15, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 6)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 22, 8))
        // Overdue inside the follow-up window: top priority until a full
        // post-release parse proves the episode has not landed yet.
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(
                prediction: prediction,
                now: now,
                lastRefresh: date(2026, 6, 21, 9)
            ),
            PodcastBackgroundRefreshPriority.Tier.overdue.rawValue
        )
    }

    func testRecentPostReleaseParseCoolsDownOverduePrediction() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 15, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 6)
        let lastRefresh = date(2026, 6, 23, 5, 45)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 22, 8))
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(
                prediction: prediction,
                now: now,
                lastRefresh: lastRefresh,
                retryDelay: 30 * 60
            ),
            PodcastBackgroundRefreshPriority.Tier.idle.rawValue
        )
    }

    func testMondayWednesdayFridaySchedulePredictsWednesdaySlot() throws {
        let dates = [
            date(2026, 6, 1, 5), date(2026, 6, 3, 5), date(2026, 6, 5, 5),
            date(2026, 6, 8, 5), date(2026, 6, 10, 5), date(2026, 6, 12, 5),
            date(2026, 6, 15, 5), date(2026, 6, 17, 5), date(2026, 6, 19, 5),
            date(2026, 6, 22, 5)
        ]
        let now = date(2026, 6, 24, 4)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 24, 5))
        // Window opens within the hour (30 min out): elevated but below in-window.
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, now: now, lastRefresh: now),
            PodcastBackgroundRefreshPriority.Tier.withinHour.rawValue
        )
    }

    func testDailyScheduleStaysAnchoredToReleaseTime() throws {
        let dates = (9...22).map { date(2026, 6, $0, 8) }
        let now = date(2026, 6, 23, 7)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 23, 8))
    }

    func testFortnightlyPodcastIsNotMistakenForWeeklySchedule() throws {
        let dates = [
            date(2026, 4, 13, 8),
            date(2026, 4, 27, 8),
            date(2026, 5, 11, 8),
            date(2026, 5, 25, 8),
            date(2026, 6, 8, 8),
            date(2026, 6, 22, 8)
        ]
        let now = date(2026, 6, 23, 9)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 7, 6, 8))
    }

    func testIrregularPodcastUsesConservativeIntervalFallback() throws {
        let dates = [
            date(2026, 5, 1, 8),
            date(2026, 5, 8, 8),
            date(2026, 5, 16, 8),
            date(2026, 5, 31, 8),
            date(2026, 6, 16, 8)
        ]
        let now = date(2026, 6, 17, 9)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 7, 2, 8))
    }

    func testStaleUnmodelledFeedOutranksDistantPrediction() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 9)
        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        // A feed with a distant prediction but a recent parse is idle, while an
        // unmodelled feed not parsed in over a day earns the daily-staleness floor.
        let distantButRecent = PodcastBackgroundRefreshPriority.score(
            prediction: prediction,
            now: now,
            lastRefresh: now
        )
        let staleUnmodelled = PodcastBackgroundRefreshPriority.score(
            prediction: nil,
            now: now,
            lastRefresh: date(2026, 6, 21, 9)
        )

        XCTAssertEqual(distantButRecent, PodcastBackgroundRefreshPriority.Tier.idle.rawValue)
        XCTAssertEqual(staleUnmodelled, PodcastBackgroundRefreshPriority.Tier.staleFloor.rawValue)
        XCTAssertGreaterThan(staleUnmodelled, distantButRecent)
    }

    func testMissedReleaseAdvancesAfterFollowUpWindowLapses() throws {
        // The expected 6/22 episode never arrived and its follow-up window has
        // fully lapsed by 6/24, so the prediction moves on to the next slot
        // (a mere HEAD/check no longer advances it — only elapsed time does).
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 15, 8),
            count: 8
        )
        let now = date(2026, 6, 24, 9)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(prediction.releaseDate, date(2026, 6, 29, 8))
    }

    @MainActor
    func testPredictionIsCachedOnPodcastMetadata() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let feedURL = URL(string: "https://example.com/weekly.xml")!
        let podcast = Podcast(feed: feedURL)
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        )
        podcast.episodes = dates.enumerated().map { index, publishDate in
            Episode(
                guid: "weekly-\(index)",
                title: "Weekly \(index)",
                publishDate: publishDate,
                url: URL(string: "https://example.com/weekly-\(index).mp3")!,
                podcast: podcast
            )
        }
        context.insert(podcast)
        try context.save()

        let now = date(2026, 6, 23, 9)
        let expectedReleaseDate = date(2026, 6, 29, 8)
        let predictedReleaseDate = await SubscriptionManager(modelContainer: container)
            .predictedReleaseDate(for: podcast.persistentModelID, after: now)

        XCTAssertEqual(predictedReleaseDate, expectedReleaseDate)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == feedURL }
        )
        let storedPodcast = try XCTUnwrap(try verificationContext.fetch(descriptor).first)
        let metadata = try XCTUnwrap(storedPodcast.metaData)
        XCTAssertEqual(metadata.nextPredictedReleaseDate, expectedReleaseDate)
        XCTAssertEqual(metadata.nextPredictedRefreshStartDate, expectedReleaseDate.addingTimeInterval(-30 * 60))
        XCTAssertNotNil(metadata.nextPredictedRefreshEndDate)
        XCTAssertEqual(metadata.releasePredictionUpdatedAt, now)
    }

    @MainActor
    func testNextPredictedReleaseRefreshTargetChoosesEarliestRelease() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let dailyFeedURL = URL(string: "https://example.com/daily.xml")!
        let weeklyFeedURL = URL(string: "https://example.com/weekly.xml")!
        let dailyPodcast = Podcast(feed: dailyFeedURL)
        dailyPodcast.title = "Daily"
        let dailyEpisodes = (16...22).enumerated().map { index, day in
            Episode(
                guid: "daily-\(index)",
                title: "Daily \(index)",
                publishDate: date(2026, 6, day, 8),
                url: URL(string: "https://example.com/daily-\(index).mp3")!,
                podcast: dailyPodcast
            )
        }
        dailyPodcast.episodes = dailyEpisodes

        let weeklyPodcast = Podcast(feed: weeklyFeedURL)
        weeklyPodcast.title = "Weekly"
        let weeklyEpisodes = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        ).enumerated().map { index, publishDate in
            Episode(
                guid: "weekly-\(index)",
                title: "Weekly \(index)",
                publishDate: publishDate,
                url: URL(string: "https://example.com/weekly-\(index).mp3")!,
                podcast: weeklyPodcast
            )
        }
        weeklyPodcast.episodes = weeklyEpisodes

        context.insert(dailyPodcast)
        context.insert(weeklyPodcast)
        if let metaData = dailyPodcast.metaData {
            metaData.podcast = dailyPodcast
            context.insert(metaData)
        }
        if let metaData = weeklyPodcast.metaData {
            metaData.podcast = weeklyPodcast
            context.insert(metaData)
        }
        dailyEpisodes.forEach { context.insert($0) }
        weeklyEpisodes.forEach { context.insert($0) }
        try context.save()

        let maybeTarget = await SubscriptionManager(modelContainer: container)
            .nextPredictedReleaseRefreshTarget(after: date(2026, 6, 22, 12))
        let target = try XCTUnwrap(maybeTarget)

        XCTAssertEqual(target.feed, dailyFeedURL)
        XCTAssertEqual(target.releaseDate, date(2026, 6, 23, 8))
    }

    @MainActor
    func testNextPredictedReleaseRefreshTargetUsesAttemptDateInsteadOfCurrentScore() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let soonFeedURL = URL(string: "https://example.com/soon.xml")!
        let distantFeedURL = URL(string: "https://example.com/distant.xml")!

        let soonPodcast = Podcast(feed: soonFeedURL)
        soonPodcast.title = "Soon"
        let soonEpisodes = (15...21).enumerated().map { index, day in
            Episode(
                guid: "soon-\(index)",
                title: "Soon \(index)",
                publishDate: date(2026, 6, day, 14),
                url: URL(string: "https://example.com/soon-\(index).mp3")!,
                podcast: soonPodcast
            )
        }
        soonPodcast.episodes = soonEpisodes
        soonPodcast.metaData?.lastRefresh = date(2026, 6, 22, 11)

        let distantPodcast = Podcast(feed: distantFeedURL)
        distantPodcast.title = "Distant"
        let distantEpisodes = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        ).enumerated().map { index, publishDate in
            Episode(
                guid: "distant-\(index)",
                title: "Distant \(index)",
                publishDate: publishDate,
                url: URL(string: "https://example.com/distant-\(index).mp3")!,
                podcast: distantPodcast
            )
        }
        distantPodcast.episodes = distantEpisodes
        distantPodcast.metaData?.lastRefresh = date(2026, 6, 20, 11)

        context.insert(soonPodcast)
        context.insert(distantPodcast)
        if let metaData = soonPodcast.metaData {
            metaData.podcast = soonPodcast
            context.insert(metaData)
        }
        if let metaData = distantPodcast.metaData {
            metaData.podcast = distantPodcast
            context.insert(metaData)
        }
        soonEpisodes.forEach { context.insert($0) }
        distantEpisodes.forEach { context.insert($0) }
        try context.save()

        let maybeTarget = await SubscriptionManager(modelContainer: container)
            .nextPredictedReleaseRefreshTarget(after: date(2026, 6, 22, 12))
        let target = try XCTUnwrap(maybeTarget)

        XCTAssertEqual(target.feed, soonFeedURL)
        XCTAssertEqual(target.releaseDate, date(2026, 6, 22, 14))
    }

    @MainActor
    func testPredictedReleaseRefreshCandidatesAreSortedAndLimited() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        for hour in 6...11 {
            let feedURL = URL(string: "https://example.com/daily-\(hour).xml")!
            let podcast = Podcast(feed: feedURL)
            podcast.title = "Daily \(hour)"
            let episodes = (16...22).enumerated().map { index, day in
                Episode(
                    guid: "daily-\(hour)-\(index)",
                    title: "Daily \(hour) \(index)",
                    publishDate: date(2026, 6, day, hour),
                    url: URL(string: "https://example.com/daily-\(hour)-\(index).mp3")!,
                    podcast: podcast
                )
            }
            podcast.episodes = episodes
            context.insert(podcast)
            if let metaData = podcast.metaData {
                metaData.podcast = podcast
                context.insert(metaData)
            }
            episodes.forEach { context.insert($0) }
        }
        try context.save()

        let candidates = await SubscriptionManager(modelContainer: container)
            .predictedReleaseRefreshCandidates(
                after: date(2026, 6, 22, 12),
                limit: 5
            )

        XCTAssertEqual(candidates.map(\.title), ["Daily 6", "Daily 7", "Daily 8", "Daily 9", "Daily 10"])
        XCTAssertEqual(candidates.map(\.releaseDate), [
            date(2026, 6, 23, 6),
            date(2026, 6, 23, 7),
            date(2026, 6, 23, 8),
            date(2026, 6, 23, 9),
            date(2026, 6, 23, 10)
        ])
    }

    private func weeklyDates(
        weekday: Int,
        through lastDate: Date,
        count: Int
    ) throws -> [Date] {
        XCTAssertEqual(calendar.component(.weekday, from: lastDate), weekday)
        return try (0..<count).reversed().map { offset in
            try XCTUnwrap(calendar.date(byAdding: .day, value: -(offset * 7), to: lastDate))
        }
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
