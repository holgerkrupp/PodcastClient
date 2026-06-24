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
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, lastCheck: dates.last, now: now),
            0
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
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, lastCheck: dates.last, now: now),
            100
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
        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, lastCheck: dates.last, now: now),
            60
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

    func testDistantPredictionDoesNotOutrankUnmodelledStaleFeed() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 22, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 9)
        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(from: dates, after: now, calendar: calendar)
        )

        XCTAssertEqual(
            PodcastBackgroundRefreshPriority.score(prediction: prediction, lastCheck: dates.last, now: now),
            PodcastBackgroundRefreshPriority.score(prediction: nil, lastCheck: nil, now: now)
        )
    }

    func testCheckAfterExpectedReleaseAdvancesToNextScheduleSlot() throws {
        let dates = try weeklyDates(
            weekday: 2,
            through: date(2026, 6, 15, 8),
            count: 8
        )
        let now = date(2026, 6, 23, 6)

        let prediction = try XCTUnwrap(
            PodcastReleasePredictor.prediction(
                from: dates,
                after: now,
                lastCheck: date(2026, 6, 22, 10),
                calendar: calendar
            )
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
        dailyPodcast.episodes = (16...22).enumerated().map { index, day in
            Episode(
                guid: "daily-\(index)",
                title: "Daily \(index)",
                publishDate: date(2026, 6, day, 8),
                url: URL(string: "https://example.com/daily-\(index).mp3")!,
                podcast: dailyPodcast
            )
        }

        let weeklyPodcast = Podcast(feed: weeklyFeedURL)
        weeklyPodcast.title = "Weekly"
        weeklyPodcast.episodes = try weeklyDates(
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

        context.insert(dailyPodcast)
        context.insert(weeklyPodcast)
        try context.save()

        let maybeTarget = await SubscriptionManager(modelContainer: container)
            .nextPredictedReleaseRefreshTarget(after: date(2026, 6, 22, 12))
        let target = try XCTUnwrap(maybeTarget)

        XCTAssertEqual(target.feed, dailyFeedURL)
        XCTAssertEqual(target.releaseDate, date(2026, 6, 23, 8))
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
