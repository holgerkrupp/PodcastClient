import SwiftData
import XCTest
@testable import UpNext

final class EpisodePlaybackDisplayStateTests: XCTestCase {
    func testFreshEpisodeDoesNotDisplayStoredProgressWithoutPlaybackHistory() {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            title: "Fresh",
            url: URL(string: "https://example.com/fresh.mp3")!,
            podcast: podcast,
            duration: 100
        )

        episode.metaData?.playPosition = 20
        episode.metaData?.maxPlayposition = 40

        XCTAssertFalse(episode.hasPlaybackHistory)
        XCTAssertEqual(episode.displayProgress, 0)
        XCTAssertEqual(episode.displayRemainingTime, 100)
    }

    func testEpisodeDisplaysStoredProgressOncePlaybackHistoryExists() {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            title: "Played",
            url: URL(string: "https://example.com/played.mp3")!,
            podcast: podcast,
            duration: 100
        )

        episode.metaData?.playPosition = 20
        episode.metaData?.maxPlayposition = 40
        episode.metaData?.lastPlayed = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(episode.hasPlaybackHistory)
        XCTAssertEqual(episode.displayProgress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(episode.displayRemainingTime, 80)
    }

    func testApplyingRecoveredPlaybackProgressCreatesPlaybackHistory() async throws {
        let fixture = try makeFixture()
        let episodeURL = URL(string: "https://example.com/recovered.mp3")!
        _ = try makeEpisode(
            in: fixture.context,
            podcast: fixture.podcast,
            url: episodeURL
        )

        let actor = EpisodeActor(modelContainer: fixture.container)
        let didPersist = await actor.applyCachedPlaybackProgress(
            episodeURL: episodeURL,
            playPosition: 25,
            maxPlayPosition: 30,
            chapterProgresses: [:]
        )

        XCTAssertTrue(didPersist)

        let refreshed = try fetchEpisode(in: fixture.container, url: episodeURL)
        XCTAssertEqual(refreshed.metaData?.playPosition, 25)
        XCTAssertEqual(refreshed.metaData?.maxPlayposition, 30)
        XCTAssertNotNil(refreshed.metaData?.lastPlayed)
        XCTAssertNotNil(refreshed.metaData?.firstListenDate)
        XCTAssertTrue(refreshed.hasPlaybackHistory)
        XCTAssertEqual(refreshed.displayProgress, 0.05, accuracy: 0.0001)
    }
}

private extension EpisodePlaybackDisplayStateTests {
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
        source: EpisodeSource = .feedDownload
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
}
