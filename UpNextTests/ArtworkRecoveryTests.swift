import Foundation
import XCTest
@testable import UpNext

private final class VirtualArtworkClock: ArtworkRecoveryCoordinator.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

private actor MockArtworkNetwork {
    private var results: [ImageDataLoadResult]
    private(set) var requestCount = 0

    init(results: [ImageDataLoadResult]) {
        self.results = results
    }

    func next(delay: Duration = .milliseconds(25)) async -> ImageDataLoadResult {
        requestCount += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            return .failure(.cancelled)
        }
        return results.isEmpty ? .failure(.offline) : results.removeFirst()
    }
}

final class ArtworkRecoveryTests: XCTestCase {
    func testTransientRetryCadenceAndServerRetryAfter() {
        XCTAssertEqual((1...5).map { ArtworkRetryPolicy.transientDelay(attempt: $0) }, [15, 60, 300, 900, 3600])
        XCTAssertEqual(
            ArtworkRetryPolicy.delay(after: .server(statusCode: 429, retryAfter: 120), attempt: 1),
            120
        )
        XCTAssertNil(ArtworkRetryPolicy.delay(after: .authentication, attempt: 1))
        XCTAssertNil(ArtworkRetryPolicy.delay(after: .permanentHTTP, attempt: 1))
        XCTAssertNil(ArtworkRetryPolicy.delay(after: .cancelled, attempt: 1))
    }

    func testConnectivityWakeRespectsMinimumGapAndRetryAfter() {
        XCTAssertFalse(ArtworkRetryPolicy.shouldRetryOnConnectivityRecovery(
            failure: .offline,
            elapsedSinceAttempt: 5
        ))
        XCTAssertFalse(ArtworkRetryPolicy.shouldRetryOnConnectivityRecovery(
            failure: .server(statusCode: 503, retryAfter: 120),
            elapsedSinceAttempt: 30,
            retryAfterRemaining: 90
        ))
        XCTAssertTrue(ArtworkRetryPolicy.shouldRetryOnConnectivityRecovery(
            failure: .offline,
            elapsedSinceAttempt: 15
        ))
    }

    func testOfflineToOnlineRecoveryRetriesWithMockedResults() async {
        let clock = VirtualArtworkClock()
        let coordinator = ArtworkRecoveryCoordinator(clock: clock, jitter: { 0 })
        let network = MockArtworkNetwork(results: [.failure(.offline), .success(Data([1, 2, 3]))])
        let key = "https://example.invalid/cover.jpg|profile:public"

        let offline = await coordinator.load(key: key) { await network.next() }
        XCTAssertFalse(awaitValueIsSuccess(offline))
        clock.advance(by: 15)
        let recoveredKeys = await coordinator.connectivityRecovered()
        XCTAssertEqual(recoveredKeys, [key])
        let restored = await coordinator.load(key: key) { await network.next() }
        XCTAssertTrue(awaitValueIsSuccess(restored))
        let requestCount = await network.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testCoordinatorCoalescesAndUsesInjectedClockForCooldown() async {
        let clock = VirtualArtworkClock()
        let coordinator = ArtworkRecoveryCoordinator(clock: clock, jitter: { 0 })
        let network = MockArtworkNetwork(results: [.failure(.offline)])

        async let first = coordinator.load(key: "https://example.invalid/cover.jpg|profile:public") {
            await network.next()
        }
        async let second = coordinator.load(key: "https://example.invalid/cover.jpg|profile:public") {
            await network.next()
        }
        _ = await (first, second)

        let requestCount = await network.requestCount
        let snapshot = await coordinator.snapshot(for: "https://example.invalid/cover.jpg|profile:public")
        let canAttemptBeforeCooldown = await coordinator.mayAttempt("https://example.invalid/cover.jpg|profile:public")
        let retryDelay = await coordinator.retryDelayRemaining(for: "https://example.invalid/cover.jpg|profile:public")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(snapshot.attempts, 1)
        XCTAssertFalse(canAttemptBeforeCooldown)
        XCTAssertEqual(retryDelay, 15)

        clock.advance(by: 15)
        let canAttemptAfterCooldown = await coordinator.mayAttempt("https://example.invalid/cover.jpg|profile:public")
        XCTAssertTrue(canAttemptAfterCooldown)
    }

    func testCoordinatorCancellationStopsInFlightRequest() async {
        let coordinator = ArtworkRecoveryCoordinator(clock: VirtualArtworkClock(), jitter: { 0 })
        let network = MockArtworkNetwork(results: [.success(Data([1]))])
        let key = "https://example.invalid/cancel.jpg|profile:public"
        let request = Task {
            await coordinator.load(key: key) {
                await network.next(delay: .seconds(20))
            }
        }
        for _ in 0..<20 {
            if await network.requestCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.cancel(key)
        let result = await request.value
        guard case .failure(.cancelled) = result else {
            return XCTFail("Cancelling an artwork key should cancel its in-flight request")
        }
    }

    func testAuthenticationFailureCanRetryAfterCredentialsChange() async {
        let coordinator = ArtworkRecoveryCoordinator(clock: VirtualArtworkClock(), jitter: { 0 })
        let key = "https://example.invalid/private.jpg|profile:subscriber"
        await coordinator.recordFailure(key, failure: .authentication)
        let blockedUntilCredentialsChange = await coordinator.mayAttempt(key)
        XCTAssertFalse(blockedUntilCredentialsChange)
        await coordinator.resetAuthenticationFailures(profileID: "subscriber")
        let retryAfterCredentialsChange = await coordinator.mayAttempt(key)
        XCTAssertTrue(retryAfterCredentialsChange)
    }

    func testDownloadedMP3FixtureExtractsArtworkFromID3Prefix() async throws {
        let fixture = fixture(named: "artwork-recovery", extension: "mp3")
        let extracted = await EmbeddedAudioArtworkService.artworkData(from: fixture)
        let data = try XCTUnwrap(extracted)
        XCTAssertNotNil(ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: 128))
    }

    func testDownloadedM4AFixtureUsesContainerArtworkMetadata() async throws {
        let fixture = fixture(named: "artwork-recovery", extension: "m4a")
        let extracted = await EmbeddedAudioArtworkService.artworkData(from: fixture)
        let data = try XCTUnwrap(extracted)
        XCTAssertNotNil(ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: 128))
    }

    func testSparseLongMP3ReadsOnlyBoundedID3Tag() async throws {
        let fixture = fixture(named: "artwork-recovery", extension: "mp3")
        let source = try Data(contentsOf: fixture)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-recovery-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try source.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.truncate(atOffset: 80 * 1024 * 1024)
        try handle.close()

        let extracted = await EmbeddedAudioArtworkService.artworkData(from: temporary)
        XCTAssertNotNil(extracted)
    }

    func testChapterArtworkIdentityStillUpdatesWithoutDuplicateReapplication() {
        let chapter = PlayerArtworkIdentity.chapterData("chapter-image")
        let episode = PlayerArtworkIdentity.url("https://example.invalid/episode.jpg", profileID: nil)
        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: chapter,
            currentIdentity: episode,
            hasImage: true
        ))
        XCTAssertFalse(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: chapter,
            currentIdentity: chapter,
            hasImage: true
        ))
    }

    func testChapterImageURLPrecedesEpisodeAndPodcastFallbacks() {
        let chapter = URL(string: "https://example.invalid/chapter.jpg")!
        let episode = URL(string: "https://example.invalid/episode.jpg")!
        let podcast = URL(string: "https://example.invalid/podcast.jpg")!
        XCTAssertEqual(
            PlayerArtworkUpdatePolicy.orderedImageURLs(
                chapterURL: chapter,
                episodeURL: episode,
                podcastURL: podcast
            ),
            [chapter, episode, podcast]
        )
        XCTAssertEqual(
            PlayerArtworkUpdatePolicy.orderedImageURLs(
                chapterURL: chapter,
                episodeURL: chapter,
                podcastURL: podcast
            ),
            [chapter, podcast]
        )
    }

    private func awaitValueIsSuccess(_ result: ImageDataLoadResult) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func fixture(named name: String, extension fileExtension: String) -> URL {
        if let bundled = Bundle(for: ArtworkRecoveryTests.self).url(forResource: name, withExtension: fileExtension) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).\(fileExtension)")
    }
}
