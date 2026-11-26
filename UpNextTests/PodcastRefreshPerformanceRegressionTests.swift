import Foundation
import SwiftData
import XCTest
@testable import UpNext

/// Fixture-backed refresh checks for issue #435.
///
/// Correctness tests run when the local fixture server is available. The
/// wall-clock matrix is deliberately opt-in because it is a measurement input,
/// not a device-independent pass/fail benchmark.
final class PodcastRefreshPerformanceRegressionTests: XCTestCase {
    private struct FixtureRequest: Decodable {
        let method: String
        let profile: String
        let feed: String
        let page: Int
        let status: Int
        let durationMilliseconds: Double

        enum CodingKeys: String, CodingKey {
            case method, profile, feed, page, status
            case durationMilliseconds = "duration_ms"
        }
    }

    private struct FixtureStats: Decodable {
        let counts: [String: Int]
        let requests: [FixtureRequest]
    }

    private struct Sample {
        let feeds: Int
        let workers: Int
        let order: String
        let repeatNumber: Int
        let seconds: Double
    }

    private func fixtureBaseURL() async throws -> URL {
        let value = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let baseURL = URL(string: value) else {
            throw XCTSkip("Invalid PODCAST_REFRESH_FIXTURE_BASE")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("fast/0"))
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("Fixture server did not return HTTP 200")
            }
        } catch is XCTSkip {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py first")
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py first")
        }
        return baseURL
    }

    private func resetFixture(at baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("__reset"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1
        _ = try await URLSession.shared.data(for: request)
    }

    private func fixtureStats(at baseURL: URL) async throws -> FixtureStats {
        let (data, response) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("__stats")
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Fixture stats endpoint is unavailable")
        }
        return try JSONDecoder().decode(FixtureStats.self, from: data)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            Marker.self,
            Bookmark.self,
            RateSegment.self,
            PlaySession.self,
            ListeningStat.self,
            PlaySessionSummary.self,
            TranscriptionRecord.self,
            configurations: configuration
        )
    }

    private func insertPodcast(
        feed: URL,
        in context: ModelContext,
        lastRefresh: Date? = nil
    ) -> Podcast {
        let podcast = Podcast(feed: feed)
        podcast.metaData?.lastRefresh = lastRefresh
        context.insert(podcast)
        return podcast
    }

    private func podcast(for feed: URL, in container: ModelContainer) throws -> Podcast {
        let context = ModelContext(container)
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        return try XCTUnwrap(podcasts.first { $0.feed == feed })
    }

    private func episodes(in container: ModelContainer) throws -> [Episode] {
        try ModelContext(container).fetch(FetchDescriptor<Episode>())
    }

    private func count(
        _ stats: FixtureStats,
        method: String,
        profile: String,
        status: Int
    ) -> Int {
        stats.counts["\(method) \(profile) \(status)"] ?? 0
    }

    func testFixtureCorrectnessMatrixPreservesStateAndHTTPSemantics() async throws {
        let baseURL = try await fixtureBaseURL()
        try await resetFixture(at: baseURL)

        let token = UUID().uuidString
        let unchangedURL = URL(string: "\(baseURL)/unchanged/0?case=\(token)")!
        let unsupportedURL = URL(string: "\(baseURL)/head-unsupported/1?case=\(token)")!
        let changedURL = URL(string: "\(baseURL)/changed/2?case=\(token)")!
        let staleURL = URL(string: "\(baseURL)/stale-last-modified/3?case=\(token)")!
        let pagedURL = URL(string: "\(baseURL)/paged/4?case=\(token)&episodes=2")!
        let historyURL = URL(string: "\(baseURL)/large-history/5?case=\(token)&episodes=24")!
        let limitedURL = URL(string: "\(baseURL)/rate-limited/6?case=\(token)&retry_after=0.05")!

        let container = try makeContainer()
        let context = ModelContext(container)
        let future = Date().addingTimeInterval(60)
        _ = insertPodcast(feed: unchangedURL, in: context, lastRefresh: future)
        _ = insertPodcast(feed: unsupportedURL, in: context)
        _ = insertPodcast(feed: changedURL, in: context)
        _ = insertPodcast(feed: staleURL, in: context)
        _ = insertPodcast(feed: pagedURL, in: context)
        _ = insertPodcast(feed: historyURL, in: context)
        _ = insertPodcast(
            feed: limitedURL,
            in: context,
            lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try context.save()

        let worker = PodcastModelActor(modelContainer: container)

        let unchanged = try await worker.updatePodcastWithSummary(
            unchangedURL,
            policy: .regular,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertFalse(unchanged.didUpdateFeed)
        XCTAssertEqual(try episodes(in: container).count, 0)

        let firstUnsupported = try await worker.updatePodcastWithSummary(
            unsupportedURL,
            policy: .regular,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(firstUnsupported.didUpdateFeed)
        let secondUnsupported = try await worker.updatePodcastWithSummary(
            unsupportedURL,
            policy: .regular,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertFalse(secondUnsupported.didUpdateFeed)

        _ = try await worker.updatePodcastWithSummary(
            changedURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        let changedPodcast = try podcast(for: changedURL, in: container)
        XCTAssertEqual(changedPodcast.desc, "Changed fixture revision 1")
        _ = try await worker.updatePodcastWithSummary(
            changedURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertEqual(try podcast(for: changedURL, in: container).desc, "Changed fixture revision 2")

        _ = try await worker.updatePodcastWithSummary(
            staleURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        let staleFirstDate = try XCTUnwrap(podcast(for: staleURL, in: container).metaData?.lastRefresh)
        let staleSecond = try await worker.updatePodcastWithSummary(
            staleURL,
            policy: .regular,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(staleSecond.didUpdateFeed)
        XCTAssertEqual(try podcast(for: staleURL, in: container).desc, "Standard description revision 2")
        XCTAssertGreaterThan(
            try XCTUnwrap(podcast(for: staleURL, in: container).metaData?.lastRefresh),
            staleFirstDate
        )

        let paged = try await worker.updatePodcastWithSummary(
            pagedURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(paged.didUpdateFeed)
        XCTAssertFalse(paged.isPartial)
        let pagedEpisodes = try episodes(in: container).filter { $0.podcast?.feed == pagedURL }
        XCTAssertEqual(pagedEpisodes.count, 4)
        XCTAssertEqual(Set(pagedEpisodes.compactMap(\.guid)).count, 4)

        _ = try await worker.updatePodcastWithSummary(
            historyURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        let historyEpisode = try XCTUnwrap(
            episodes(in: container).first { $0.podcast?.feed == historyURL }
        )
        let historyEditContext = ModelContext(container)
        let historyEpisodeToEdit = try XCTUnwrap(
            try historyEditContext.fetch(FetchDescriptor<Episode>()).first {
                $0.podcast?.feed == historyURL && $0.guid == historyEpisode.guid
            }
        )
        historyEpisodeToEdit.metaData?.playPosition = 42
        historyEpisodeToEdit.metaData?.setArchived(true)
        try historyEditContext.save()
        _ = try await worker.updatePodcastWithSummary(
            historyURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        let historyEpisodes = try episodes(in: container).filter { $0.podcast?.feed == historyURL }
        XCTAssertEqual(historyEpisodes.count, 24)
        let restoredHistoryEpisode = try XCTUnwrap(historyEpisodes.first { $0.guid == historyEpisode.guid })
        XCTAssertEqual(restoredHistoryEpisode.metaData?.playPosition, 42)
        XCTAssertTrue(restoredHistoryEpisode.metaData?.isArchived == true)

        do {
            _ = try await worker.updatePodcastWithSummary(
                limitedURL,
                policy: .manualSingle,
                silent: true,
                resolveExistingMissingDurations: false
            )
            XCTFail("The first rate-limited request should fail")
        } catch {
            // A 429 is recoverable and must not advance successful parse time.
        }
        XCTAssertEqual(
            try podcast(for: limitedURL, in: container).metaData?.lastRefresh,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let recovered = try await worker.updatePodcastWithSummary(
            limitedURL,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(recovered.didUpdateFeed)

        let privateURL = URL(string: "\(baseURL)/private/7?case=\(token)")!
        var unauthorizedRequest = URLRequest(url: privateURL)
        unauthorizedRequest.timeoutInterval = 1
        let (_, unauthorizedResponse) = try await URLSession.shared.data(for: unauthorizedRequest)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
        var authorizedRequest = URLRequest(url: privateURL)
        authorizedRequest.timeoutInterval = 1
        authorizedRequest.setValue(
            "Basic " + Data("fixture:password".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization"
        )
        let (authorizedBody, authorizedResponse) = try await URLSession.shared.data(for: authorizedRequest)
        XCTAssertEqual((authorizedResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: authorizedBody, as: UTF8.self).contains("Fixture private 7"))

        let stats = try await fixtureStats(at: baseURL)
        XCTAssertEqual(count(stats, method: "HEAD", profile: "unchanged", status: 200), 1)
        XCTAssertGreaterThanOrEqual(count(stats, method: "HEAD", profile: "head-unsupported", status: 405), 2)
        XCTAssertEqual(count(stats, method: "GET", profile: "head-unsupported", status: 200), 1)
        XCTAssertEqual(count(stats, method: "GET", profile: "head-unsupported", status: 304), 1)
        XCTAssertGreaterThanOrEqual(count(stats, method: "GET", profile: "rate-limited", status: 429), 1)
        XCTAssertGreaterThanOrEqual(count(stats, method: "GET", profile: "rate-limited", status: 200), 1)
        // URLSession may send a reserved Authorization header only after the
        // server's challenge, so the authorized probe can add a second 401.
        XCTAssertGreaterThanOrEqual(count(stats, method: "GET", profile: "private", status: 401), 1)
        XCTAssertEqual(count(stats, method: "GET", profile: "private", status: 200), 1)
        XCTAssertGreaterThanOrEqual(
            stats.requests.filter { $0.profile == "paged" && $0.status == 200 }.count,
            2
        )
    }

    func testFixtureCancellationLeavesNoPartialImport() async throws {
        let baseURL = try await fixtureBaseURL()
        try await resetFixture(at: baseURL)
        let feed = URL(string: "\(baseURL)/slow-get/20?case=cancel-\(UUID().uuidString)&episodes=60&delay=0.5")!
        let container = try makeContainer()
        let context = ModelContext(container)
        _ = insertPodcast(feed: feed, in: context)
        try context.save()

        let task = Task {
            try await PodcastModelActor(modelContainer: container).updatePodcastWithSummary(
                feed,
                policy: .manualSingle,
                silent: true,
                resolveExistingMissingDurations: false
            )
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled slow feed should not complete")
        } catch is CancellationError {
            // Expected interruption path.
        } catch {
            // URLSession may surface cancellation as a transport error.
        }

        XCTAssertTrue(try episodes(in: container).isEmpty)
        XCTAssertNil(try podcast(for: feed, in: container).metaData?.lastRefresh)
    }

    func testPlaybackActiveBackgroundRefreshPolicyIsSerialAndBounded() {
        for reason in [
            SubscriptionManager.FeedRefreshReason.foregroundQuiet,
            .appRefresh,
            .processing,
        ] {
            let policy = SubscriptionManager.BackgroundFeedRefreshPolicy.forReason(
                reason,
                playbackActive: true
            )
            XCTAssertEqual(policy.maxPodcastsPerRun, 1)
            XCTAssertEqual(policy.maxConcurrentPodcastUpdates, 1)
            XCTAssertLessThanOrEqual(policy.maxRuntime, 8)
            XCTAssertLessThanOrEqual(policy.perPodcastRuntimeLimit, 4)
        }
    }

    func testFixtureRefreshPerformanceMatrixAndOrderEffect() async throws {
        guard ProcessInfo.processInfo.environment["PODCAST_REFRESH_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set PODCAST_REFRESH_PERFORMANCE=1 for wall-clock measurements")
        }
        let baseURL = try await fixtureBaseURL()
        let delay = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_DELAY"] ?? "0.01"
        let previousConcurrency = UserDefaults.standard.object(forKey: "PodcastRefreshNetworkConcurrency")
        defer {
            if let previousConcurrency {
                UserDefaults.standard.set(previousConcurrency, forKey: "PodcastRefreshNetworkConcurrency")
            } else {
                UserDefaults.standard.removeObject(forKey: "PodcastRefreshNetworkConcurrency")
            }
        }

        func shuffled(_ count: Int, seed: Int) -> [Int] {
            var values = Array(0..<count)
            var state = UInt64(seed) &* 2862933555777941757 &+ 3037000493
            for index in stride(from: count - 1, through: 1, by: -1) {
                state = state &* 2862933555777941757 &+ 3037000493
                let destination = Int(state % UInt64(index + 1))
                values.swapAt(index, destination)
            }
            return values
        }

        func duration(_ start: ContinuousClock.Instant) -> Double {
            let components = start.duration(to: .now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }

        func run(feeds count: Int, workers: Int, order: [Int], repeatNumber: Int) async throws -> Double {
            try await resetFixture(at: baseURL)
            UserDefaults.standard.set(workers, forKey: "PodcastRefreshNetworkConcurrency")
            let container = try makeContainer()
            let context = ModelContext(container)
            let runID = "r\(repeatNumber)-\(UUID().uuidString)"
            let slowFeeds = Set((0..<count).filter { $0 % 4 == 3 })
            for number in order {
                let profile = slowFeeds.contains(number) ? "slow-head" : "fast"
                let feed = URL(string: "\(baseURL)/\(profile)/\(number)?run=\(runID)&delay=\(delay)")!
                _ = insertPodcast(
                    feed: feed,
                    in: context,
                    lastRefresh: Date().addingTimeInterval(60)
                )
            }
            try context.save()
            let start = ContinuousClock.now
            try await PodcastModelActor(modelContainer: container).refreshAllPodcasts()
            return duration(start)
        }

        var samples: [Sample] = []
        for count in [10, 50, 100] {
            for workers in [1, 4] {
                for repeatNumber in 1...5 {
                    let sorted = Array(0..<count)
                    let shuffledOrder = shuffled(count, seed: count * 100 + workers * 10 + repeatNumber)
                    let sortedSeconds = try await run(
                        feeds: count,
                        workers: workers,
                        order: sorted,
                        repeatNumber: repeatNumber
                    )
                    let shuffledSeconds = try await run(
                        feeds: count,
                        workers: workers,
                        order: shuffledOrder,
                        repeatNumber: repeatNumber + 100
                    )
                    samples.append(Sample(
                        feeds: count,
                        workers: workers,
                        order: "sorted",
                        repeatNumber: repeatNumber,
                        seconds: sortedSeconds
                    ))
                    samples.append(Sample(
                        feeds: count,
                        workers: workers,
                        order: "shuffled",
                        repeatNumber: repeatNumber,
                        seconds: shuffledSeconds
                    ))
                }
            }
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
            return sorted[index]
        }

        for count in [10, 50, 100] {
            for workers in [1, 4] {
                let matching = samples.filter { $0.feeds == count && $0.workers == workers }
                let all = matching.map(\.seconds)
                let sorted = matching.filter { $0.order == "sorted" }.map(\.seconds)
                let shuffled = matching.filter { $0.order == "shuffled" }.map(\.seconds)
                let sortedMedian = percentile(sorted, 0.5)
                let shuffledMedian = percentile(shuffled, 0.5)
                let orderDelta = abs(sortedMedian - shuffledMedian)
                print(
                    "PodcastRefreshPerformance feeds=\(count) workers=\(workers) "
                        + "p50=\(percentile(all, 0.5)) p95=\(percentile(all, 0.95)) "
                        + "sorted_p50=\(sortedMedian) shuffled_p50=\(shuffledMedian) "
                        + "order_delta=\(orderDelta)"
                )
                XCTAssertLessThan(
                    orderDelta,
                    max(1.0, max(sortedMedian, shuffledMedian) * 0.75),
                    "Possible fast-first/slow-last order effect for \(count) feeds / \(workers) workers"
                )
            }
        }
    }

    /// Issue #430: does the same feed get slower when it is scheduled late?
    /// Shuffling balances fast and slow fixtures across schedule positions, so
    /// a late-position slowdown here is order-dependent, not content bias.
    func testFixturePerFeedTimingEarlyVersusLateInShuffledOrder() async throws {
        guard ProcessInfo.processInfo.environment["PODCAST_REFRESH_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set PODCAST_REFRESH_PERFORMANCE=1 for wall-clock measurements")
        }
        let baseURL = try await fixtureBaseURL()
        let delay = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_DELAY"] ?? "0.01"
        let repetitions = Int(ProcessInfo.processInfo.environment["PODCAST_REFRESH_REPETITIONS"] ?? "") ?? 5
        let previousConcurrency = UserDefaults.standard.object(forKey: "PodcastRefreshNetworkConcurrency")
        defer {
            if let previousConcurrency {
                UserDefaults.standard.set(previousConcurrency, forKey: "PodcastRefreshNetworkConcurrency")
            } else {
                UserDefaults.standard.removeObject(forKey: "PodcastRefreshNetworkConcurrency")
            }
        }

        actor TimingLog {
            var timings: [PodcastRefreshFeedTiming] = []
            func append(_ timing: PodcastRefreshFeedTiming) { timings.append(timing) }
        }
        struct FeedSample {
            let feeds: Int
            let workers: Int
            let mode: String
            let feedNumber: Int
            let scheduledOrdinal: Int
            let milliseconds: Double
        }

        func shuffled(_ count: Int, seed: Int) -> [Int] {
            var values = Array(0..<count)
            var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
            for index in stride(from: count - 1, through: 1, by: -1) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                values.swapAt(index, Int((state >> 33) % UInt64(index + 1)))
            }
            return values
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard values.isEmpty == false else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }

        var samples: [FeedSample] = []
        var wallTimes: [String: [Double]] = [:]
        for mode in ["head", "get"] {
            for count in [10, 50, 100] {
                for workers in [1, 4] {
                    for repetition in 1...repetitions {
                        try await resetFixture(at: baseURL)
                        UserDefaults.standard.set(workers, forKey: "PodcastRefreshNetworkConcurrency")
                        let container = try makeContainer()
                        let context = ModelContext(container)
                        let runID = "\(mode)-\(count)-\(workers)-\(repetition)-\(UUID().uuidString)"
                        var feedNumbers: [URL: Int] = [:]
                        // Insertion order is the scheduling order of the
                        // subscribed-podcast fetch.
                        for number in shuffled(count, seed: count * 1_000 + workers * 100 + repetition) {
                            let profile = number % 4 == 3 ? "slow-head" : "fast"
                            let feed = URL(string: "\(baseURL)/\(profile)/\(number)?run=\(runID)&delay=\(delay)&episodes=10")!
                            feedNumbers[feed] = number
                            _ = insertPodcast(
                                feed: feed,
                                in: context,
                                // A future refresh date makes HEAD conclusive;
                                // nil forces GET + parse + first import.
                                lastRefresh: mode == "head" ? Date().addingTimeInterval(60) : nil
                            )
                        }
                        try context.save()
                        let log = TimingLog()
                        let start = ContinuousClock.now
                        try await PodcastModelActor(modelContainer: container).refreshAllPodcasts(
                            feedTiming: { await log.append($0) }
                        )
                        let wall = start.duration(to: .now).components
                        wallTimes["\(mode)-\(count)-\(workers)", default: []].append(
                            Double(wall.seconds) * 1_000 + Double(wall.attoseconds) / 1e15
                        )
                        let timings = await log.timings
                        XCTAssertEqual(timings.count, count)
                        XCTAssertTrue(timings.allSatisfy(\.succeeded))
                        for timing in timings {
                            samples.append(FeedSample(
                                feeds: count,
                                workers: workers,
                                mode: mode,
                                feedNumber: feedNumbers[timing.feed] ?? -1,
                                scheduledOrdinal: timing.scheduledOrdinal,
                                milliseconds: Double(timing.durationMilliseconds)
                            ))
                        }
                    }
                }
            }
        }

        for mode in ["head", "get"] {
            for count in [10, 50, 100] {
                for workers in [1, 4] {
                    let matching = samples.filter {
                        $0.mode == mode && $0.feeds == count && $0.workers == workers
                    }
                    let third = max(1, count / 3)
                    let early = matching.filter { $0.scheduledOrdinal < third }.map(\.milliseconds)
                    let late = matching.filter { $0.scheduledOrdinal >= count - third }.map(\.milliseconds)
                    // Same feed, early vs late: mean per feed in each bucket.
                    var perFeedDeltas: [Double] = []
                    for number in 0..<count {
                        let feedSamples = matching.filter { $0.feedNumber == number }
                        let feedEarly = feedSamples.filter { $0.scheduledOrdinal < third }.map(\.milliseconds)
                        let feedLate = feedSamples.filter { $0.scheduledOrdinal >= count - third }.map(\.milliseconds)
                        guard feedEarly.isEmpty == false, feedLate.isEmpty == false else { continue }
                        perFeedDeltas.append(
                            feedLate.reduce(0, +) / Double(feedLate.count)
                                - feedEarly.reduce(0, +) / Double(feedEarly.count)
                        )
                    }
                    let walls = wallTimes["\(mode)-\(count)-\(workers)"] ?? []
                    print(String(
                        format: "PodcastRefreshPerFeed mode=%@ feeds=%d workers=%d runs=%d "
                            + "feed_p50_ms=%.0f feed_p95_ms=%.0f early_p50_ms=%.0f early_p95_ms=%.0f "
                            + "late_p50_ms=%.0f late_p95_ms=%.0f same_feed_late_minus_early_median_ms=%.0f "
                            + "same_feed_pairs=%d wall_p50_ms=%.0f wall_p95_ms=%.0f",
                        mode, count, workers, walls.count,
                        percentile(matching.map(\.milliseconds), 0.5),
                        percentile(matching.map(\.milliseconds), 0.95),
                        percentile(early, 0.5), percentile(early, 0.95),
                        percentile(late, 0.5), percentile(late, 0.95),
                        percentile(perFeedDeltas, 0.5), perFeedDeltas.count,
                        percentile(walls, 0.5), percentile(walls, 0.95)
                    ))
                    // Broad guard only: a late-scheduled feed taking more than
                    // twice as long (and 100 ms more) at the median points to
                    // order-dependent degradation worth profiling.
                    let earlyMedian = percentile(early, 0.5)
                    XCTAssertLessThan(
                        percentile(late, 0.5),
                        max(earlyMedian * 2, earlyMedian + 100),
                        "Late-scheduled feeds slower for mode=\(mode) feeds=\(count) workers=\(workers)"
                    )
                }
            }
        }
    }
}
