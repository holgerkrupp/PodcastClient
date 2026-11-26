import CoreGraphics
import SwiftData
import XCTest
@testable import UpNext

/// Issue #497: Library rows must not run release-prediction SQL, and deferred
/// artwork must not start disk/decode work before its delay window passes.
final class LibraryRowPerformanceTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - Feed health cache

    func testFeedHealthEvaluationReusesUnchangedRevisionsAndRecomputesChangedOnes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = Podcast(feed: URL(string: "https://example.com/health.xml")!)
        context.insert(podcast)
        try context.save()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var assessCount = 0
        let assess: (Podcast, PodcastMetaData, Date) -> PodcastFeedAbandonmentAssessment? = { _, _, _ in
            assessCount += 1
            return nil
        }

        let first = try XCTUnwrap(
            PodcastFeedHealthCache.evaluateEntries(in: context, previous: [:], now: now, assess: assess)
        )
        XCTAssertEqual(assessCount, 1)

        _ = PodcastFeedHealthCache.evaluateEntries(
            in: context,
            previous: first,
            now: now.addingTimeInterval(60),
            assess: assess
        )
        XCTAssertEqual(assessCount, 1, "An unchanged revision must not run another release-pattern fetch")

        podcast.metaData?.lastRefresh = now
        _ = PodcastFeedHealthCache.evaluateEntries(
            in: context,
            previous: first,
            now: now.addingTimeInterval(120),
            assess: assess
        )
        XCTAssertEqual(assessCount, 2, "A refresh advances the revision and re-evaluates")

        _ = PodcastFeedHealthCache.evaluateEntries(
            in: context,
            previous: first,
            now: now.addingTimeInterval(PodcastFeedHealthCache.maximumEntryAge + 1),
            assess: assess
        )
        XCTAssertEqual(assessCount, 3, "Aged entries are re-evaluated so time passing is noticed")
    }

    func testFeedHealthEvaluationSkipsUnsubscribedPodcasts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = Podcast(feed: URL(string: "https://example.com/paused.xml")!)
        podcast.metaData?.isSubscribed = false
        context.insert(podcast)
        try context.save()

        var assessCount = 0
        let entries = try XCTUnwrap(
            PodcastFeedHealthCache.evaluateEntries(in: context, previous: [:], now: Date()) { _, _, _ in
                assessCount += 1
                return nil
            }
        )
        XCTAssertEqual(assessCount, 0)
        XCTAssertNil(entries[podcast.persistentModelID]?.likelyCancelled)
    }

    func testDefaultFeedHealthEvaluationFlagsMissedWeeklyReleasesOffTheRowPath() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let podcast = Podcast(feed: URL(string: "https://example.com/cancelled.xml")!)
        context.insert(podcast)
        let lastRelease = Date(timeIntervalSince1970: 1_775_462_400) // a Monday
        for index in 0..<8 {
            let episode = Episode(
                guid: "cancelled-\(index)",
                title: "Cancelled \(index)",
                publishDate: lastRelease.addingTimeInterval(-Double(index) * 7 * day),
                url: URL(string: "https://example.com/cancelled-\(index).mp3")!,
                podcast: podcast
            )
            context.insert(episode)
        }
        let now = lastRelease.addingTimeInterval(77 * day)
        podcast.metaData?.lastRefresh = now.addingTimeInterval(-day)
        podcast.metaData?.feedUpdateCheckDate = now.addingTimeInterval(-3600)
        podcast.metaData?.feedUpdated = false
        try context.save()

        let entries = try XCTUnwrap(
            PodcastFeedHealthCache.evaluateEntries(in: context, previous: [:], now: now)
        )
        XCTAssertEqual(entries[podcast.persistentModelID]?.likelyCancelled?.kind, .likelyCancelled)
    }

    // MARK: - Row diagnostics (no episode access)

    @MainActor
    func testRowDiagnosticUsesCachedVerdictAndStoredFailuresOnly() {
        let metadata = PodcastMetaData()
        let likelyCancelled = PodcastFeedAbandonmentAssessment(
            kind: .likelyCancelled,
            title: "Podcast may be cancelled",
            detail: "No new episode.",
            evidenceDate: nil,
            predictedCadenceLabel: nil,
            missedReleaseCount: 3
        )

        XCTAssertNil(PodcastRowView.rowDiagnostic(from: metadata, likelyCancelled: nil)?.badge)
        XCTAssertEqual(
            PodcastRowView.rowDiagnostic(from: metadata, likelyCancelled: likelyCancelled)?.badge,
            "POSSIBLY CANCELLED"
        )

        let now = Date()
        metadata.consecutiveFeedFailureCount = 4
        metadata.firstConsecutiveFeedFailureDate = now.addingTimeInterval(-8 * day)
        metadata.lastFeedFailureDate = now.addingTimeInterval(-3600)
        metadata.lastFeedFailureStatusCode = 410
        XCTAssertEqual(
            PodcastRowView.rowDiagnostic(from: metadata, likelyCancelled: likelyCancelled, now: now)?.badge,
            "FEED UNAVAILABLE",
            "A sustained terminal failure keeps precedence over the cached verdict"
        )
    }

    // MARK: - Artwork pipeline ordering

    func testDeferredArtworkCancelledInsideDelayWindowNeverStartsWork() async {
        let started = expectation(description: "load started")
        started.isInverted = true
        let task = Task {
            guard await ArtworkLoadDeferral.waitForDeferWindow(.milliseconds(300)) else { return }
            started.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await fulfillment(of: [started], timeout: 0.5)
    }

    func testDeferredArtworkProceedsAfterDelayWindow() async {
        let proceeded = await ArtworkLoadDeferral.waitForDeferWindow(.milliseconds(10))
        XCTAssertTrue(proceeded)
        let immediate = await ArtworkLoadDeferral.waitForDeferWindow(.zero)
        XCTAssertTrue(immediate)
    }

    func testBlurReusesLargerDecodedForegroundBitmap() throws {
        let url = URL(string: "https://example.com/reuse-\(UUID().uuidString).jpg")!
        let image = try makeImage(pixels: 384)
        SharedImageRepository.store(image, for: url, maxPixelSize: 384)

        XCTAssertTrue(SharedImageRepository.reusableDecodedImage(for: url, atLeast: 256) === image)
        XCTAssertNil(SharedImageRepository.reusableDecodedImage(for: url, atLeast: 512))
        XCTAssertNil(
            SharedImageRepository.reusableDecodedImage(for: url, atLeast: 256, profileID: "private"),
            "Credentialed artwork never reuses a public bitmap"
        )
    }

    func testNotificationScopeOnlyRetriesUnresolvedArtwork() {
        XCTAssertFalse(ArtworkNotificationScope.needsRetry(lastAppliedKey: "a", imageKey: "a"))
        XCTAssertTrue(ArtworkNotificationScope.needsRetry(lastAppliedKey: "", imageKey: "a"))
    }

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            configurations: configuration
        )
    }

    private func makeImage(pixels: Int) throws -> UIImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let cgImage = try XCTUnwrap(context.makeImage())
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
