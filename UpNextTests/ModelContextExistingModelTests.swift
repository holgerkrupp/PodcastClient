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
}
