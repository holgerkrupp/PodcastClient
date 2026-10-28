import SwiftData
import XCTest
@testable import UpNext

@MainActor
final class PlaylistLibraryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var directory: URL!
    private var container: ModelContainer?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "PlaylistLibraryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        container = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testCreateAppendsAManualPlaylistWithADistinctName() throws {
        let context = try makeContext()
        _ = Playlist.ensureDefaultQueue(in: context)

        let first = try PlaylistLibrary.create(name: "Commute", symbolName: "car", in: context)
        let second = try PlaylistLibrary.create(name: "Commute", symbolName: "", in: context)

        XCTAssertEqual(first.title, "Commute")
        XCTAssertEqual(first.symbolName, "car")
        XCTAssertEqual(second.title, "Commute 2")
        XCTAssertEqual(second.symbolName, Playlist.defaultManualSymbolName)
        XCTAssertTrue(second.deleteable)
        XCTAssertEqual(second.kind, .manual)
        XCTAssertGreaterThan(second.sortIndex, first.sortIndex)
    }

    func testDeleteRemovesThePlaylistAndItsEntriesButKeepsTheEpisodes() throws {
        let context = try makeContext()
        _ = Playlist.ensureDefaultQueue(in: context)
        let playlist = try PlaylistLibrary.create(name: "Commute", symbolName: "car", in: context)
        let episode = Episode(
            title: "Episode",
            url: URL(string: "https://example.com/episode.mp3")!
        )
        context.insert(episode)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        entry.playlist = playlist
        try context.save()

        try PlaylistLibrary.delete(playlist, in: context, defaults: defaults)

        let remainingTitles = try context.fetch(FetchDescriptor<Playlist>()).map(\.title)
        XCTAssertFalse(remainingTitles.contains("Commute"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaylistEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
    }

    func testDeletingTheSelectedPlaylistSelectsTheBuiltInQueue() throws {
        let context = try makeContext()
        let queue = Playlist.ensureDefaultQueue(in: context)
        let playlist = try PlaylistLibrary.create(name: "Commute", symbolName: "car", in: context)
        defaults.set(playlist.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)

        try PlaylistLibrary.delete(playlist, in: context, defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID),
            queue.id.uuidString
        )
    }

    func testDeletingAnotherPlaylistLeavesTheSelectionAlone() throws {
        let context = try makeContext()
        _ = Playlist.ensureDefaultQueue(in: context)
        let selected = try PlaylistLibrary.create(name: "Selected", symbolName: "car", in: context)
        let other = try PlaylistLibrary.create(name: "Other", symbolName: "car", in: context)
        defaults.set(selected.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)

        try PlaylistLibrary.delete(other, in: context, defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID),
            selected.id.uuidString
        )
    }

    func testTheBuiltInQueueCannotBeDeleted() throws {
        let context = try makeContext()
        let queue = Playlist.ensureDefaultQueue(in: context)
        // Even if the flag were flipped by a bad import, the reserved title
        // still protects it.
        queue.deleteable = true

        try PlaylistLibrary.delete(queue, in: context, defaults: defaults)

        let titles = try context.fetch(FetchDescriptor<Playlist>()).map(\.title)
        XCTAssertTrue(titles.contains(Playlist.defaultQueueTitle))
    }

    func testExistingDefaultQueueLookupDoesNotRepairTheQueue() throws {
        let context = try makeContext()
        let queue = Playlist()
        queue.title = Playlist.defaultQueueTitle
        queue.syncID = "legacy-local-id"
        queue.deleteable = true
        queue.hidden = true
        context.insert(queue)
        try context.save()

        let found = try XCTUnwrap(Playlist.existingDefaultQueue(in: context))

        XCTAssertEqual(found.id, queue.id)
        XCTAssertEqual(queue.syncID, "legacy-local-id")
        XCTAssertTrue(queue.deleteable)
        XCTAssertTrue(queue.hidden)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("Library.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
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
        self.container = container
        return ModelContext(container)
    }
}
