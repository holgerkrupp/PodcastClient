import XCTest
import SwiftData
@testable import UpNext

final class ModelContextExistingModelTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        // CloudKit mirroring is off: the test host has the app's iCloud
        // entitlements, and an in-memory store that tries to mirror tears itself
        // down on a simulator with no account.
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

    private func makeContext() throws -> ModelContext {
        ModelContext(try makeContainer())
    }

    private func insertPodcast(_ name: String, in context: ModelContext) -> Podcast {
        let podcast = Podcast(feed: URL(string: "https://example.com/\(name).xml")!)
        podcast.title = name
        context.insert(podcast)
        return podcast
    }

    func testExistingModelDropsAnIdentifierWhoseRowIsGone() throws {
        let context = try makeContext()
        let kept = insertPodcast("kept", in: context)
        let removed = insertPodcast("removed", in: context)
        try context.save()

        let keptID = kept.persistentModelID
        let removedID = removed.persistentModelID
        context.delete(removed)
        try context.save()

        let foundKept: Podcast? = context.existingModel(for: keptID)
        let foundRemoved: Podcast? = context.existingModel(for: removedID)

        XCTAssertEqual(foundKept?.title, "kept")
        XCTAssertNil(foundRemoved)
    }

    func testExistingModelsResolvesABatchAndSkipsDeletedRows() throws {
        let context = try makeContext()
        let first = insertPodcast("first", in: context)
        let second = insertPodcast("second", in: context)
        let removed = insertPodcast("removed", in: context)
        try context.save()

        let ids = [first, second, removed].map(\.persistentModelID)
        context.delete(removed)
        try context.save()

        let resolved: [PersistentIdentifier: Podcast] = context.existingModels(for: ids)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[ids[0]]?.title, "first")
        XCTAssertEqual(resolved[ids[1]]?.title, "second")
        XCTAssertNil(resolved[ids[2]])
    }

    func testExistingModelsOnAnEmptyBatchDoesNotFetch() throws {
        let context = try makeContext()
        _ = insertPodcast("only", in: context)
        try context.save()

        let resolved: [PersistentIdentifier: Podcast] = context.existingModels(for: [])

        XCTAssertTrue(resolved.isEmpty)
    }

    func testExistingModelDoesNotReturnADeletedRowFromAnotherContext() throws {
        let container = try makeContainer()
        let writer = ModelContext(container)
        let reader = ModelContext(container)
        let podcast = insertPodcast("shared", in: writer)
        try writer.save()

        let id = podcast.persistentModelID
        XCTAssertNotNil(reader.existingModel(for: id) as Podcast?)

        writer.delete(podcast)
        try writer.save()

        let freshReader = ModelContext(container)
        XCTAssertNil(freshReader.existingModel(for: id) as Podcast?)
    }

    func testPodcastMutationCoordinatorSerializesTheSameFeed() async {
        actor Probe {
            var active = 0
            var maximum = 0

            func enter() {
                active += 1
                maximum = max(maximum, active)
            }

            func leave() {
                active -= 1
            }
        }

        let coordinator = PodcastMutationCoordinator()
        let probe = Probe()
        let feed = URL(string: "https://example.com/shared.xml")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await coordinator.withExclusive(feedURL: feed) {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                    }
                }
            }
        }

        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testPodcastMutationCoordinatorRemovesCancelledWaiter() async throws {
        actor Probe {
            var secondOperationStarted = false

            func markSecondOperationStarted() {
                secondOperationStarted = true
            }
        }

        let coordinator = PodcastMutationCoordinator()
        let probe = Probe()
        let feed = URL(string: "https://example.com/cancelled-waiter.xml")!
        let holder = Task {
            try await coordinator.withExclusive(feedURL: feed) {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        try await Task.sleep(for: .milliseconds(25))

        let waiter = Task {
            try await coordinator.withExclusive(feedURL: feed) {
                await probe.markSecondOperationStarted()
            }
        }
        try await Task.sleep(for: .milliseconds(25))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("A cancelled waiter must not run after the active operation")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await holder.value

        let secondOperationStarted = await probe.secondOperationStarted
        XCTAssertFalse(secondOperationStarted)
    }

    func testFeedRefreshCoordinatorSharesSufficientIntentAndKeepsJoinedOwner() async throws {
        actor Counter {
            var count = 0
            func started() { count += 1 }
        }
        let coordinator = FeedRefreshCoordinator()
        let counter = Counter()
        let feed = URL(string: "https://example.com/shared-refresh.xml")!
        let intent = FeedRefreshCoordinator.Intent(
            requiresGET: false,
            visible: false,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let operation: @Sendable () async throws -> PodcastUpdateSummary = {
            await counter.started()
            try await Task.sleep(for: .milliseconds(120))
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: 1)
        }

        let first = Task { try await coordinator.run(feedURL: feed, intent: intent, operation: operation) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await coordinator.run(feedURL: feed, intent: intent, operation: operation) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()

        do {
            _ = try await first.value
            XCTFail("A cancelled owner should stop waiting")
        } catch is CancellationError {
            // The joined owner keeps the shared network work alive.
        }
        let result = try await second.value
        XCTAssertTrue(result.didUpdateFeed)
        let operationCount = await counter.count
        XCTAssertEqual(operationCount, 1)
    }

    func testFeedRefreshCoordinatorReportsProgressToJoinedCaller() async throws {
        actor Recorder {
            var values: [Double] = []
            func add(_ value: Double) { values.append(value) }
        }
        let coordinator = FeedRefreshCoordinator()
        let firstRecorder = Recorder()
        let secondRecorder = Recorder()
        let feed = URL(string: "https://example.com/progress.xml")!
        let intent = FeedRefreshCoordinator.Intent(
            requiresGET: true,
            visible: true,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let operation: @Sendable (SubscriptionProgressHandler?) async throws -> PodcastUpdateSummary = { progress in
            await progress?(SubscriptionProgressUpdate(0.5, "Halfway"))
            try await Task.sleep(for: .milliseconds(80))
            await progress?(SubscriptionProgressUpdate(1, "Done"))
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: 0)
        }
        let first = Task {
            try await coordinator.run(feedURL: feed, intent: intent, progress: { update in
                await firstRecorder.add(update.fractionCompleted)
            }, operation: operation)
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task {
            try await coordinator.run(feedURL: feed, intent: intent, progress: { update in
                await secondRecorder.add(update.fractionCompleted)
            }, operation: operation)
        }
        _ = try await first.value
        _ = try await second.value
        let firstValues = await firstRecorder.values
        let secondValues = await secondRecorder.values
        XCTAssertEqual(firstValues.last, 1)
        XCTAssertEqual(secondValues.last, 1)
    }

    func testFeedRefreshCoordinatorSeparatesAccessProfiles() async throws {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let coordinator = FeedRefreshCoordinator()
        let counter = Counter()
        let feed = URL(string: "https://example.com/private.xml")!
        let intent = FeedRefreshCoordinator.Intent(
            requiresGET: true,
            visible: false,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let operation: @Sendable () async throws -> PodcastUpdateSummary = {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: 0)
        }
        async let first = coordinator.run(
            feedURL: feed, profileScope: "account-a", intent: intent, operation: operation
        )
        async let second = coordinator.run(
            feedURL: feed, profileScope: "account-b", intent: intent, operation: operation
        )
        _ = try await (first, second)
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testFeedRefreshCoordinatorRunsStrongerGETAfterHEADOnlyFlight() async throws {
        actor Counter {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let coordinator = FeedRefreshCoordinator()
        let counter = Counter()
        let feed = URL(string: "https://example.com/stronger-refresh.xml")!
        let headIntent = FeedRefreshCoordinator.Intent(
            requiresGET: false,
            visible: false,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let getIntent = FeedRefreshCoordinator.Intent(
            requiresGET: true,
            visible: true,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let operation: @Sendable () async throws -> PodcastUpdateSummary = {
            let count = await counter.next()
            try await Task.sleep(for: .milliseconds(50))
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: count)
        }

        let first = Task { try await coordinator.run(feedURL: feed, intent: headIntent, operation: operation) }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { try await coordinator.run(feedURL: feed, intent: getIntent, operation: operation) }
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.newEpisodeCount, 1)
        XCTAssertEqual(secondResult.newEpisodeCount, 2)
    }

    func testFixtureRefreshUpdatesStoredStandardDescriptionAndLiveItem() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let feed = URL(string: baseURL + "/dynamic/99?run=\(UUID().uuidString)"),
              let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py for the integration fixture")
        }
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Podcast(feed: feed))
        try context.save()

        let worker = PodcastModelActor(modelContainer: container)
        let first = try await worker.updatePodcastWithSummary(
            feed,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(first.didUpdateFeed)
        let firstStored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(firstStored.desc, "Standard description revision 1")
        XCTAssertEqual(firstStored.liveItems.first?.status, .pending)

        let second = try await worker.updatePodcastWithSummary(
            feed,
            policy: .regular,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(second.didUpdateFeed)
        let secondStored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(secondStored.desc, "Standard description revision 2")
        XCTAssertEqual(secondStored.liveItems.first?.status, .live)
    }

    func testFixtureManualAllNetworkBenchmark() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100 --delay 1")
        }

        let previousConcurrency = UserDefaults.standard.object(forKey: "PodcastRefreshNetworkConcurrency")
        defer {
            if let previousConcurrency {
                UserDefaults.standard.set(previousConcurrency, forKey: "PodcastRefreshNetworkConcurrency")
            } else {
                UserDefaults.standard.removeObject(forKey: "PodcastRefreshNetworkConcurrency")
            }
        }

        func run(concurrency: Int) async throws -> TimeInterval {
            let container = try makeContainer()
            let context = ModelContext(container)
            for index in 0..<50 {
                let feed = URL(string: baseURL + "/slow-head/\(index)")!
                let podcast = Podcast(feed: feed)
                podcast.metaData?.lastRefresh = Date()
                context.insert(podcast)
            }
            try context.save()
            UserDefaults.standard.set(concurrency, forKey: "PodcastRefreshNetworkConcurrency")
            let start = ContinuousClock.now
            try await PodcastModelActor(modelContainer: container).refreshAllPodcasts()
            return Double(start.duration(to: .now).components.seconds)
                + Double(start.duration(to: .now).components.attoseconds) / 1e18
        }

        let serial = try await run(concurrency: 1)
        let parallel = try await run(concurrency: 4)
        print("PodcastRefreshBenchmark feeds=50 serial=\(serial)s parallel=\(parallel)s")
        XCTAssertLessThan(parallel, serial * 0.7)
    }

    func testFixtureUnsupportedHEADUsesValidated304WithoutAdvancingParseTime() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let feed = URL(string: baseURL + "/head-unsupported/98?run=\(UUID().uuidString)"),
              let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py")
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Podcast(feed: feed))
        try context.save()
        let worker = PodcastModelActor(modelContainer: container)
        let first = try await worker.updatePodcastWithSummary(feed, policy: .regular, silent: true)
        XCTAssertTrue(first.didUpdateFeed)
        let firstParseTime = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Podcast>()).first?.metaData?.lastRefresh
        )

        let second = try await worker.updatePodcastWithSummary(feed, policy: .regular, silent: true)
        XCTAssertFalse(second.didUpdateFeed)
        let secondParseTime = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Podcast>()).first?.metaData?.lastRefresh
        )
        XCTAssertEqual(secondParseTime, firstParseTime)
    }

    func testFixtureHundredFeedRunReportsEveryCompletion() async throws {
        actor Progress {
            var completed = 0
            var total = 0
            func record(_ completed: Int, _ total: Int) {
                self.completed = completed
                self.total = total
            }
        }
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100")
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<100 {
            let podcast = Podcast(feed: URL(string: baseURL + "/unchanged/\(index)")!)
            podcast.metaData?.lastRefresh = Date()
            context.insert(podcast)
        }
        try context.save()
        let progress = Progress()
        try await PodcastModelActor(modelContainer: container).refreshAllPodcasts { completed, total in
            await progress.record(completed, total)
        }
        let finalCompleted = await progress.completed
        let finalTotal = await progress.total
        XCTAssertEqual(finalCompleted, 100)
        XCTAssertEqual(finalTotal, 100)
    }

    func testFixtureTenFeedImportRemainsIdempotentWithFourWorkers() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100 --episodes 1")
        }

        let previousConcurrency = UserDefaults.standard.object(forKey: "PodcastRefreshNetworkConcurrency")
        UserDefaults.standard.set(4, forKey: "PodcastRefreshNetworkConcurrency")
        defer {
            if let previousConcurrency {
                UserDefaults.standard.set(previousConcurrency, forKey: "PodcastRefreshNetworkConcurrency")
            } else {
                UserDefaults.standard.removeObject(forKey: "PodcastRefreshNetworkConcurrency")
            }
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let runID = UUID().uuidString
        for index in 0..<10 {
            context.insert(Podcast(feed: URL(string: baseURL + "/fast/\(index)?run=\(runID)")!))
        }
        try context.save()

        let worker = PodcastModelActor(modelContainer: container)
        try await worker.refreshAllPodcasts()
        let firstCount = try ModelContext(container).fetchCount(FetchDescriptor<Episode>())
        XCTAssertEqual(firstCount, 10)
        try await worker.refreshAllPodcasts()
        let secondCount = try ModelContext(container).fetchCount(FetchDescriptor<Episode>())
        XCTAssertEqual(secondCount, 10)
    }

    func testFixturePagedSeedImportsBothPagesWithoutDuplicateEpisode() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let feed = URL(string: baseURL + "/paged/97?run=\(UUID().uuidString)"),
              let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100 --episodes 1")
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Podcast(feed: feed))
        try context.save()
        let worker = PodcastModelActor(modelContainer: container)
        let summary = try await worker.updatePodcastWithSummary(
            feed,
            policy: .manualSingle,
            silent: true,
            resolveExistingMissingDurations: false
        )
        XCTAssertTrue(summary.didUpdateFeed)
        XCTAssertFalse(summary.isPartial)
        let episodes = try ModelContext(container).fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(Set(episodes.compactMap(\.guid)), ["paged-97-0", "paged-97-1"])
        XCTAssertEqual(episodes.count, 2)
    }

    func testFixtureRepeatRefreshPreservesEpisodePlaybackAndArchiveState() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let feed = URL(string: baseURL + "/fast/96?run=\(UUID().uuidString)"),
              let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100 --episodes 1")
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Podcast(feed: feed))
        try context.save()
        let worker = PodcastModelActor(modelContainer: container)
        _ = try await worker.updatePodcastWithSummary(feed, policy: .manualSingle, silent: true)

        let editContext = ModelContext(container)
        let before = try XCTUnwrap(editContext.fetch(FetchDescriptor<Episode>()).first)
        let userState = try XCTUnwrap(before.metaData)
        userState.playPosition = 42
        userState.setArchived(true)
        try editContext.save()

        _ = try await worker.updatePodcastWithSummary(feed, policy: .manualSingle, silent: true)
        let episodes = try ModelContext(container).fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.metaData?.playPosition, 42)
        XCTAssertEqual(episodes.first?.metaData?.isArchived, true)
    }

    func testFixtureServerFailureDoesNotAdvanceSuccessfulParseTime() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let feed = URL(string: baseURL + "/server-error/95?run=\(UUID().uuidString)"),
              let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start the fixture server with --feeds 100 --episodes 1")
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = Podcast(feed: feed)
        let previousParse = Date(timeIntervalSince1970: 1_700_000_000)
        podcast.metaData?.lastRefresh = previousParse
        context.insert(podcast)
        try context.save()

        do {
            _ = try await PodcastModelActor(modelContainer: container)
                .updatePodcastWithSummary(feed, policy: .manualSingle, silent: true)
            XCTFail("The fixture should return HTTP 503")
        } catch {
            // The failed request must remain distinct from the last successful parse.
        }
        let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(stored.metaData?.lastRefresh, previousParse)
    }

    func testPodcastFeedCommitCoordinatorAllowsOnlyOneWriter() async {
        actor Probe {
            var active = 0
            var maximum = 0

            func enter() {
                active += 1
                maximum = max(maximum, active)
            }

            func leave() {
                active -= 1
            }
        }

        let coordinator = PodcastFeedCommitCoordinator.shared
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? await coordinator.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(15))
                    await probe.leave()
                    await coordinator.release()
                }
            }
        }

        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testPodcastFeedCommitCoordinatorCancelsQueuedWriter() async throws {
        let coordinator = PodcastFeedCommitCoordinator.shared
        try await coordinator.acquire()
        let queued = Task {
            try await coordinator.acquire()
            await coordinator.release()
        }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do {
            try await queued.value
            XCTFail("The canceled writer acquired the gate")
        } catch is CancellationError {
            // The held writer can now release without a canceled waiter ahead of the next feed.
        }
        await coordinator.release()
        try await coordinator.acquire()
        await coordinator.release()
    }

    func testPodcastHostRequestLimiterCapsOneOriginAtTwoRequests() async {
        actor Probe {
            var active = 0
            var maximum = 0
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave() { active -= 1 }
        }
        let limiter = PodcastHostRequestLimiter()
        let probe = Probe()
        let host = URL(string: "https://fixture.example.invalid/\(UUID().uuidString)")!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try? await limiter.withPermit(for: host) {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(80))
                        await probe.leave()
                    }
                }
            }
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testPodcastHostRequestLimiterAllowsFourAcrossIndependentOrigins() async {
        actor Probe {
            var active = 0
            var maximum = 0
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave() { active -= 1 }
        }
        let limiter = PodcastHostRequestLimiter()
        let probe = Probe()
        let hosts = [
            URL(string: "https://first.example.invalid/feed")!,
            URL(string: "https://second.example.invalid/feed")!
        ]
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                let host = hosts[index % 2]
                group.addTask {
                    try? await limiter.withPermit(for: host) {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(80))
                        await probe.leave()
                    }
                }
            }
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 4)
    }

    func testPodcastHostRequestLimiterRemovesCancelledWaiter() async throws {
        let limiter = PodcastHostRequestLimiter()
        let host = URL(string: "https://fixture.example.invalid/\(UUID().uuidString)")!
        let first = Task {
            try await limiter.withPermit(for: host) {
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        let second = Task {
            try await limiter.withPermit(for: host) {
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let queued = Task {
            try await limiter.withPermit(for: host) { true }
        }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("A cancelled queued request must not be sent")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await (first.value, second.value)
    }
}
