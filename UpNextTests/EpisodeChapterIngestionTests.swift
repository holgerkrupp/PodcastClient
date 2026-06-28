import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class EpisodeChapterIngestionTests: XCTestCase {
    func testLocalMP3ChaptersAreAddedEvenWhenFeedChaptersAlreadyExist() async throws {
        let fixture = try makeFixture()
        let fileURL = try makeEmptyFileURL(extension: "mp3")
        let episode = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: fileURL,
            source: .sideLoaded
        )

        let feedChapter = Marker(start: 0, title: "Feed Intro", type: .podlove, duration: 30)
        feedChapter.episode = episode
        episode.chapters = [feedChapter]
        try fixture.context.save()

        let originalLoader = ChapterExtractionHooks.loadLocalMP3Chapters
        defer { ChapterExtractionHooks.loadLocalMP3Chapters = originalLoader }
        ChapterExtractionHooks.loadLocalMP3Chapters = { _ in
            [Marker(start: 45, title: "Local Chapter", type: .mp3, duration: 120)]
        }

        await EpisodeActor(modelContainer: fixture.container).createChapters(fileURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: fileURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters.contains { $0.type == .podlove && $0.title == "Feed Intro" })
        XCTAssertTrue(chapters.contains { $0.type == .mp3 && $0.title == "Local Chapter" })
    }

    func testLocalM4AChaptersAreAddedWhenTheFileExists() async throws {
        let fixture = try makeFixture()
        let fileURL = try makeEmptyFileURL(extension: "m4a")
        _ = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: fileURL,
            source: .sideLoaded
        )

        let originalLoader = ChapterExtractionHooks.loadM4AChapters
        defer { ChapterExtractionHooks.loadM4AChapters = originalLoader }
        ChapterExtractionHooks.loadM4AChapters = { _ in
            [Marker(start: 10, title: "Audio Intro", type: .mp4, duration: 90)]
        }

        await EpisodeActor(modelContainer: fixture.container).createChapters(fileURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: fileURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.type, .mp4)
        XCTAssertEqual(chapters.first?.title, "Audio Intro")
    }

    func testRemoteMP3ChaptersAreAttemptedForOlderInboxEpisodes() async throws {
        let fixture = try makeFixture()
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let episode = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: episodeURL,
            source: .feedDownload
        )
        episode.publishDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        try fixture.context.save()

        let originalLoader = ChapterExtractionHooks.loadRemoteMP3Chapters
        defer { ChapterExtractionHooks.loadRemoteMP3Chapters = originalLoader }
        ChapterExtractionHooks.loadRemoteMP3Chapters = { _ in
            [Marker(start: 5, title: "Remote Chapter", type: .mp3, duration: 60)]
        }

        await EpisodeActor(modelContainer: fixture.container).getRemoteChapters(episodeURL: episodeURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: episodeURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertTrue(chapters.contains { $0.type == .mp3 && $0.title == "Remote Chapter" })
    }

    func testRemoteMP3ChaptersPreserveFeedChaptersAndExistingChapterState() async throws {
        let fixture = try makeFixture()
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let episode = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: episodeURL,
            source: .feedDownload
        )

        let feedChapter = Marker(start: 0, title: "Feed Intro", type: .podlove, duration: 30)
        feedChapter.episode = episode
        let existingMP3Chapter = Marker(start: 45, title: "Remote Chapter", type: .mp3, duration: 90)
        existingMP3Chapter.shouldPlay = false
        existingMP3Chapter.progress = 0.35
        existingMP3Chapter.episode = episode
        episode.chapters = [feedChapter, existingMP3Chapter]
        episode.metaData?.lastPlayed = Date(timeIntervalSince1970: 1_000)
        try fixture.context.save()

        let originalLoader = ChapterExtractionHooks.loadRemoteMP3Chapters
        defer { ChapterExtractionHooks.loadRemoteMP3Chapters = originalLoader }
        ChapterExtractionHooks.loadRemoteMP3Chapters = { _ in
            [Marker(start: 45, title: "Remote Chapter", type: .mp3, duration: 120)]
        }

        let actor = EpisodeActor(modelContainer: fixture.container)
        await actor.getRemoteChapters(episodeURL: episodeURL)
        await actor.getRemoteChapters(episodeURL: episodeURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: episodeURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters.contains { $0.type == .podlove && $0.title == "Feed Intro" })

        let remoteChapter = try XCTUnwrap(chapters.first { $0.type == .mp3 })
        XCTAssertEqual(remoteChapter.title, "Remote Chapter")
        XCTAssertEqual(remoteChapter.shouldPlay, false)
        XCTAssertEqual(remoteChapter.progress ?? -1, 0.35, accuracy: 0.0001)
    }

    func testRefreshingLocalMP3ChaptersPreservesExistingStateAndDoesNotDuplicateMarkers() async throws {
        let fixture = try makeFixture()
        let fileURL = try makeEmptyFileURL(extension: "mp3")
        let episode = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: fileURL,
            source: .sideLoaded
        )

        let existingChapter = Marker(start: 15, title: "Shared Chapter", type: .mp3, duration: 50)
        existingChapter.shouldPlay = false
        existingChapter.progress = 0.42
        existingChapter.imageData = Data([0x01, 0x02, 0x03])
        existingChapter.episode = episode
        episode.chapters = [existingChapter]
        episode.metaData?.lastPlayed = Date(timeIntervalSince1970: 1_000)
        try fixture.context.save()

        let originalLoader = ChapterExtractionHooks.loadLocalMP3Chapters
        defer { ChapterExtractionHooks.loadLocalMP3Chapters = originalLoader }
        ChapterExtractionHooks.loadLocalMP3Chapters = { _ in
            [Marker(start: 15, title: "Shared Chapter", type: .mp3, duration: 60)]
        }

        let actor = EpisodeActor(modelContainer: fixture.container)
        await actor.createChapters(fileURL)
        await actor.createChapters(fileURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: fileURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.type, .mp3)
        XCTAssertEqual(chapters.first?.title, "Shared Chapter")
        XCTAssertEqual(chapters.first?.shouldPlay, false)
        XCTAssertEqual(chapters.first?.progress ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(chapters.first?.imageData ?? Data(), Data([0x01, 0x02, 0x03]))
    }

    func testInvalidExtractedChaptersAreReplacedFromContentEncodedShownotes() async throws {
        let fixture = try makeFixture()
        let episodeURL = URL(string: "https://example.com/methodisch-inkorrekt.mp3")!
        let episode = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: episodeURL,
            source: .feedDownload
        )
        episode.desc = """
        Du möchtest mehr über unsere Werbepartner erfahren?
        Diesmal mit dem Pilzpaten, metalem Stress im Homeoffice und ganz viel Infraschall.
        """
        episode.content = """
        <p><strong>Inhalt</strong><br>
        00:00:00 Intro<br>
        00:05:19 Lab Rampage Brettspiel<br>
        00:13:11 Radentscheid Essen<br>
        00:14:56 Xteink X4<br>
        00:24:44 FreeTube<br>
        00:28:43 Community Fotokalender<br>
        00:32:23 Thema 1: “Weltweiter Pilzpate”<br>
        00:52:18 Science Snack<br>
        01:11:43 Thema 2: “Stabiles Büro”<br>
        01:42:26 Schwurbel der Woche<br>
        02:05:33 Outro</p>
        """

        let badAdvertisementChapter = Marker(
            start: 0,
            title: "Du möchtest mehr über unsere Werbepartner erfahren?",
            type: .extracted
        )
        badAdvertisementChapter.episode = episode
        let badSummaryChapter = Marker(
            start: 0,
            title: "Diesmal mit dem Pilzpaten, metalem Stress im Homeoffice und ganz viel Infraschall.",
            type: .extracted
        )
        badSummaryChapter.episode = episode
        episode.chapters = [badAdvertisementChapter, badSummaryChapter]
        try fixture.context.save()

        await EpisodeActor(modelContainer: fixture.container).createChapters(episodeURL)

        let reloaded = try fetchEpisode(in: fixture.container, url: episodeURL)
        let chapters = try XCTUnwrap(reloaded.chapters)
        XCTAssertEqual(chapters.count, 11)
        XCTAssertTrue(chapters.contains { $0.start == 0 && $0.title == "Intro" })
        XCTAssertTrue(chapters.contains { $0.start == 7_533 && $0.title == "Outro" })
        XCTAssertFalse(chapters.contains { $0.title.contains("Werbepartner") })
        XCTAssertFalse(chapters.contains { $0.title.contains("Pilzpaten, metalem Stress") })
    }
}

private extension EpisodeChapterIngestionTests {
    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let podcast: Podcast
    }

    func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
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
        let context = ModelContext(container)
        _ = Playlist.ensureDefaultQueue(in: context)

        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Example Podcast"
        context.insert(podcast)
        try context.save()

        return Fixture(container: container, context: context, podcast: podcast)
    }

    func makeEpisode(
        in context: ModelContext,
        podcast: Podcast,
        url: URL,
        source: EpisodeSource
    ) throws -> Episode {
        let episode = Episode(
            guid: UUID().uuidString,
            title: "Episode",
            publishDate: Date(),
            url: url,
            podcast: podcast,
            duration: 600,
            author: "Author",
            source: source
        )
        context.insert(episode)
        try context.save()
        return episode
    }

    func fetchEpisode(in container: ModelContainer, url: URL) throws -> Episode {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.url == url })
        return try XCTUnwrap(context.fetch(descriptor).first)
    }

    func makeEmptyFileURL(extension fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("episode.\(fileExtension)")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        return fileURL
    }
}
