import SQLite3
import SwiftData
import XCTest
@testable import UpNext

/// Guards the on-disk legacy store against the `#Index` declarations added to
/// its models.
///
/// `generate` writes a store with whatever schema the binary was built with and
/// leaves it on disk; `verify` reopens that same file and checks the rows
/// survived. Running `generate` on one build and `verify` on the next is what
/// actually exercises the schema change — a single run only proves the store
/// round-trips within one schema.
final class LegacyStoreIndexMigrationTests: XCTestCase {

    private static let fixtureDirectory = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    ).appendingPathComponent("LegacyStoreIndexFixture", isDirectory: true)

    private static let storeURL = fixtureDirectory
        .appendingPathComponent("Legacy.sqlite")

    private static let expectedEpisodeCount = 400
    private static let expectedChapterCount = 900
    private static let expectedBookmarkCount = 7
    private static let expectedSessionCount = 300

    @MainActor
    private func makeFixtureContainer() throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: Self.fixtureDirectory,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "LegacyFixture",
            url: Self.storeURL,
            cloudKitDatabase: .none
        )
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

    /// Writes the fixture store. Run this on the build *before* a schema change.
    @MainActor
    func testGenerateLegacyStoreFixture() throws {
        try? FileManager.default.removeItem(at: Self.fixtureDirectory)
        let container = try makeFixtureContainer()
        let context = container.mainContext

        let feedURL = URL(string: "https://example.com/index-fixture.xml")!
        let podcast = Podcast(feed: feedURL)
        podcast.title = "Index Fixture"
        podcast.metaData?.isSubscribed = true
        context.insert(podcast)

        var episodes: [Episode] = []
        for index in 0..<Self.expectedEpisodeCount {
            let episode = Episode(
                guid: "fixture-episode-\(index)",
                title: "Episode \(index)",
                publishDate: Date(timeIntervalSince1970: Double(index) * 3_600),
                url: URL(string: "https://example.com/fixture-\(index).mp3")!,
                podcast: podcast,
                duration: 600
            )
            episode.metaData?.playPosition = Double(index)
            episodes.append(episode)
            context.insert(episode)
        }
        podcast.episodes = episodes

        let first = try XCTUnwrap(episodes.first)
        var chapters: [Marker] = []
        for index in 0..<Self.expectedChapterCount {
            let chapter = Marker(
                start: Double(index) * 10,
                title: "Chapter \(index)",
                type: .podlove
            )
            chapter.creationtime = Date(timeIntervalSince1970: Double(index))
            chapter.episode = first
            chapters.append(chapter)
            context.insert(chapter)
        }
        first.chapters = chapters

        var bookmarks: [Bookmark] = []
        for index in 0..<Self.expectedBookmarkCount {
            let bookmark = Bookmark(
                start: Double(index) * 30,
                title: "Bookmark \(index)",
                type: .bookmark
            )
            bookmark.uuid = UUID()
            bookmark.creationtime = Date(timeIntervalSince1970: Double(50_000 + index))
            bookmark.bookmarkEpisode = first
            bookmarks.append(bookmark)
            context.insert(bookmark)
        }
        first.bookmarks = bookmarks

        for index in 0..<Self.expectedSessionCount {
            let session = PlaySession(
                id: UUID(),
                episode: episodes[index % episodes.count],
                startTime: Date(timeIntervalSince1970: Double(index) * 600),
                endTime: Date(timeIntervalSince1970: Double(index) * 600 + 300),
                startPosition: 0,
                endPosition: 300,
                endedCleanly: true
            )
            context.insert(session)
        }

        let playlist = Playlist()
        playlist.title = Playlist.defaultQueueTitle
        playlist.items = (0..<5).map { index in
            let entry = PlaylistEntry(episode: episodes[index], order: index)
            entry.playlist = playlist
            return entry
        }
        context.insert(playlist)

        try context.save()
        try assertFixtureIsIntact(context)

        print("LEGACY_FIXTURE_STORE_URL=\(Self.storeURL.path)")
    }

    /// Reopens the fixture store. Run this on the build *after* a schema change.
    @MainActor
    func testVerifyLegacyStoreFixtureStillOpens() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.storeURL.path),
            "No fixture store on disk; run testGenerateLegacyStoreFixture on the previous build first."
        )

        // Mirror what `makeLegacyContainer` does: backfill, then open.
        LegacyStoreIndexBackfill.run(storeURL: Self.storeURL)

        let container = try makeFixtureContainer()
        try assertFixtureIsIntact(container.mainContext)

        XCTAssertTrue(
            Self.indexNames.isSubset(of: try Self.indexNamesPresent()),
            "a store written before the #Index declarations must end up indexed"
        )
    }

    /// The backfill is what actually gets the indexes onto a store that already
    /// exists: SwiftData applies `#Index` only when it creates one.
    @MainActor
    func testBackfillCreatesIndexesOnAnExistingStore() throws {
        try? FileManager.default.removeItem(at: Self.fixtureDirectory)
        try FileManager.default.createDirectory(
            at: Self.fixtureDirectory,
            withIntermediateDirectories: true
        )

        // A store SwiftData has already created carries the index declarations,
        // so strip them back off to stand in for a store written before they
        // existed.
        _ = try makeFixtureContainer()
        for index in Self.indexNames {
            try Self.executeSQL("DROP INDEX IF EXISTS \(index)", on: Self.storeURL)
        }
        XCTAssertTrue(
            try Self.indexNamesPresent().isDisjoint(with: Self.indexNames),
            "precondition: the stand-in store must have no declared indexes"
        )

        LegacyStoreIndexBackfill.run(storeURL: Self.storeURL)

        XCTAssertTrue(
            Self.indexNames.isSubset(of: try Self.indexNamesPresent()),
            "the backfill must create every declared index"
        )

        // Idempotent: a second launch must not fail or duplicate anything.
        LegacyStoreIndexBackfill.run(storeURL: Self.storeURL)
        XCTAssertEqual(
            try Self.indexNamesPresent().intersection(Self.indexNames).count,
            Self.indexNames.count
        )
    }

    @MainActor
    func testBackfillIgnoresAMissingStore() {
        let missing = Self.fixtureDirectory.appendingPathComponent("Absent.sqlite")
        try? FileManager.default.removeItem(at: missing)
        LegacyStoreIndexBackfill.run(storeURL: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    @MainActor
    private func assertFixtureIsIntact(_ context: ModelContext) throws {
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Episode>()),
            Self.expectedEpisodeCount
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Marker>()),
            Self.expectedChapterCount + Self.expectedBookmarkCount
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Bookmark>()),
            Self.expectedBookmarkCount
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlaySession>()),
            Self.expectedSessionCount
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaylistEntry>()), 5)

        // The indexed sort paths the migration pages by must still return rows
        // in the right order.
        var descriptor = FetchDescriptor<Episode>(
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let newest = try context.fetch(descriptor).first
        XCTAssertEqual(newest?.title, "Episode \(Self.expectedEpisodeCount - 1)")
    }

    // MARK: - Raw store inspection

    private static let indexNames: Set<String> = [
        "Z_Episode_SwiftDataIndexOnBinarypublishDate",
        "Z_Episode_SwiftDataIndexOnBinarypodcastpublishDate",
        "Z_PlaySession_SwiftDataIndexOnBinarystartTime",
        "Z_PlaylistEntry_SwiftDataIndexOnBinaryorder"
    ]

    private static func indexNamesPresent() throws -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            throw StoreInspectionError.open
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT name FROM sqlite_master WHERE type = 'index'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw StoreInspectionError.query
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: raw))
            }
        }
        return names
    }

    private static func executeSQL(_ sql: String, on url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            throw StoreInspectionError.open
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreInspectionError.query
        }
    }

    private enum StoreInspectionError: Error {
        case open
        case query
    }
}
