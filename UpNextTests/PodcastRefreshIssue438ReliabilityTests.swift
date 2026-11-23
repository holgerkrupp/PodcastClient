import Foundation
import SwiftData
import XCTest
@testable import UpNext

/// Focused #438 checks that sit outside the broader #435 fixture benchmark file.
/// They exercise durable state and resumable cancellation across a simulated
/// process boundary without changing refresh or predictor implementation.
@MainActor
final class PodcastRefreshIssue438ReliabilityTests: XCTestCase {
    func testDiskBackedLibraryRelaunchPreservesEpisodeIdentityAndPlaybackState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastRefreshIssue438-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("SharedDatabase.sqlite")
        let feedURL = URL(string: "https://example.com/fixture-feed.xml")!
        let episodeURL = URL(string: "https://media.example.invalid/fixture-episode.mp3")!

        do {
            let container = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
            let context = ModelContext(container)
            let podcast = Podcast(feed: feedURL)
            podcast.title = "Fixture podcast"
            let episode = Episode(
                guid: "fixture-episode-1",
                title: "Fixture episode",
                url: episodeURL,
                podcast: podcast,
                duration: 900
            )
            episode.metaData?.playPosition = 321
            episode.metaData?.maxPlayposition = 321
            episode.metaData?.setArchived(true, at: Date(timeIntervalSince1970: 1_700_000_000))
            podcast.episodes = [episode]
            context.insert(podcast)
            context.insert(episode)
            try context.save()
        }

        let relaunched = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        let reopenedContext = ModelContext(relaunched)
        let podcasts = try reopenedContext.fetch(FetchDescriptor<Podcast>())
        let episodes = try reopenedContext.fetch(FetchDescriptor<Episode>())

        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(episodes.count, 1)
        let reopenedEpisode = try XCTUnwrap(episodes.first)
        XCTAssertEqual(reopenedEpisode.guid, "fixture-episode-1")
        XCTAssertEqual(reopenedEpisode.podcast?.feed, feedURL)
        XCTAssertEqual(reopenedEpisode.metaData?.playPosition, 321)
        XCTAssertEqual(reopenedEpisode.metaData?.maxPlayposition, 321)
        XCTAssertEqual(reopenedEpisode.metaData?.isArchived, true)
    }

    func testCancelledRetryProcessingLeavesSanitizedCheckpointForRelaunch() async throws {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        let probeURL = try XCTUnwrap(URL(string: baseURL + "/fast/0"))
        var probe = URLRequest(url: probeURL)
        probe.timeoutInterval = 1
        do {
            _ = try await URLSession.shared.data(for: probe)
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py before the cancellation fixture")
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastRefreshIssue438-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("SharedDatabase.sqlite")
        let retryURL = directory.appendingPathComponent("retries.json")
        let feedURL = try XCTUnwrap(URL(string: baseURL + "/slow-get/1?token=fixture-secret"))
        let continuationURL = try XCTUnwrap(URL(string: baseURL + "/slow-get/1?page=2&token=fixture-secret"))
        let expectedContinuation = try XCTUnwrap(URL(string: baseURL + "/slow-get/1?page=2"))

        let container = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        let context = ModelContext(container)
        context.insert(Podcast(feed: feedURL))
        try context.save()

        let queue = PodcastEpisodeImportRetryQueue(storageURL: retryURL)
        await queue.checkpoint(feedURL: feedURL, resumeURL: continuationURL)

        let processing = Task {
            await queue.processDue(modelContainer: container, force: true)
        }
        try await Task.sleep(for: .milliseconds(100))
        processing.cancel()
        await processing.value

        let relaunchedQueue = PodcastEpisodeImportRetryQueue(storageURL: retryURL)
        let savedContinuation = await relaunchedQueue.pendingResumeURL(for: feedURL)
        XCTAssertEqual(savedContinuation, expectedContinuation)
        XCTAssertFalse(
            try String(contentsOf: retryURL, encoding: .utf8).contains("fixture-secret"),
            "Retry checkpoints must remain safe to inspect after relaunch"
        )
    }
}
