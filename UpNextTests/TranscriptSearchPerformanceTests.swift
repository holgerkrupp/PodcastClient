import Foundation
import SwiftData
import XCTest
@testable import UpNext

/// Large-store checks are opt-in because they intentionally allocate a sizeable
/// in-memory canonical store. Run with RUN_TRANSCRIPT_SEARCH_PERFORMANCE=1 when
/// profiling a release or simulator build.
final class TranscriptSearchPerformanceTests: XCTestCase {
    func testSearch100000CanonicalLines() async throws {
        try await runSearchBenchmark(lineCount: 100_000)
    }

    func testSearch500000CanonicalLines() async throws {
        try await runSearchBenchmark(lineCount: 500_000)
    }

    func testSearch1000000CanonicalLines() async throws {
        try await runSearchBenchmark(lineCount: 1_000_000)
    }

    private func runSearchBenchmark(lineCount: Int) async throws {
        guard ProcessInfo.processInfo.environment["RUN_TRANSCRIPT_SEARCH_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set RUN_TRANSCRIPT_SEARCH_PERFORMANCE=1 to run the large canonical-store benchmark.")
        }

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            TranscriptLineAndTime.self,
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
        let context = ModelContext(container)
        let podcast = Podcast(feed: URL(string: "https://example.com/performance.xml")!)
        podcast.title = "Performance fixture"
        context.insert(podcast)

        let episodeCount = max(1, (lineCount + 999) / 1_000)
        var remaining = lineCount
        for episodeIndex in 0..<episodeCount {
            let episode = Episode(
                guid: "performance-(episodeIndex)",
                title: "Performance episode (episodeIndex)",
                url: URL(string: "https://example.com/performance-(episodeIndex).mp3")!,
                podcast: podcast
            )
            context.insert(episode)

            let rowsInEpisode = min(1_000, remaining)
            for lineIndex in 0..<rowsInEpisode {
                let marker = lineIndex.isMultiple(of: 17) ? " performance marker" : ""
                let line = TranscriptLineAndTime(
                    text: "Synthetic transcript line \(lineIndex) in episode \(episodeIndex).\(marker)",
                    startTime: Double(lineIndex)
                )
                line.episode = episode
                context.insert(line)
            }
            remaining -= rowsInEpisode
        }
        try context.save()

        let service = TranscriptSearchActor(modelContainer: container)
        let firstStart = Date()
        let firstPage = try await service.search(
            TranscriptSearchQuery(text: "performance marker", scope: .library, limit: 25)
        )
        let firstPageMilliseconds = Date().timeIntervalSince(firstStart) * 1_000

        let podcastStart = Date()
        let podcastPage = try await service.search(
            TranscriptSearchQuery(text: "performance marker", scope: .podcast(podcast.stablePodcastIdentityKey), limit: 25)
        )
        let podcastMilliseconds = Date().timeIntervalSince(podcastStart) * 1_000

        let repeatStart = Date()
        _ = try await service.search(
            TranscriptSearchQuery(text: "performance marker", scope: .library, limit: 25, offset: 25)
        )
        let repeatMilliseconds = Date().timeIntervalSince(repeatStart) * 1_000

        let cancellationStart = Date()
        let cancelledSearch = Task {
            try await service.search(
                TranscriptSearchQuery(text: "performance marker", scope: .library, limit: 25)
            )
        }
        cancelledSearch.cancel()
        _ = try? await cancelledSearch.value
        let cancellationMilliseconds = Date().timeIntervalSince(cancellationStart) * 1_000

        XCTAssertFalse(firstPage.groups.isEmpty)
        XCTAssertEqual(firstPage.totalMatches, podcastPage.totalMatches)
        XCTAssertGreaterThanOrEqual(firstPage.totalMatches, 1)

        let measurements = "lines=\(lineCount) first_page_ms=\(firstPageMilliseconds) podcast_page_ms=\(podcastMilliseconds) repeat_page_ms=\(repeatMilliseconds) cancellation_ms=\(cancellationMilliseconds)"
        print("Canonical transcript search benchmark: \(measurements)")
    }
}
