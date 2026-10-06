import SwiftData
import XCTest
@testable import UpNext

#if os(iOS)

final class AppIntentEntityQueryTests: XCTestCase {
    func testUpNextSnapshotsAreLimitedOrderedAndSkipMissingURLs() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let queue = Playlist()
        queue.title = Playlist.defaultQueueTitle
        queue.syncID = Playlist.defaultQueueSyncID
        context.insert(queue)

        for order in 0..<1_025 {
            let episode = Episode(
                guid: "intent-\(order)",
                title: "Episode \(order)",
                url: URL(string: "https://example.com/intent-\(order).mp3")!,
                duration: 60
            )
            let entry = PlaylistEntry(episode: episode, order: order + 1)
            context.insert(episode)
            context.insert(entry)
            entry.playlist = queue
        }

        let missingURL = Episode(
            guid: "missing-url",
            title: "Missing",
            url: URL(string: "https://example.com/missing.mp3")!,
            duration: 60
        )
        missingURL.url = nil
        let missingURLEntry = PlaylistEntry(episode: missingURL, order: 0)
        context.insert(missingURL)
        context.insert(missingURLEntry)
        missingURLEntry.playlist = queue
        try context.save()

        let snapshots = try await AppIntentLibraryQueryActor(modelContainer: container)
            .upNextEpisodes(limit: 25)

        // The query is capped before snapshot extraction. A missing URL in
        // that capped window is omitted rather than faulting the entity later.
        XCTAssertEqual(snapshots.count, 24)
        XCTAssertEqual(snapshots.first?.id, "https://example.com/intent-0.mp3")
        XCTAssertEqual(snapshots.last?.id, "https://example.com/intent-23.mp3")
    }

    func testUpNextSnapshotsAreEmptyWithoutAnExistingQueue() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            configurations: configuration
        )

        let snapshots = try await AppIntentLibraryQueryActor(modelContainer: container)
            .upNextEpisodes(limit: 25)

        XCTAssertTrue(snapshots.isEmpty)
    }
}

#endif
