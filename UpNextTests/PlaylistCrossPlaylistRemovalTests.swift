import SwiftData
import XCTest
@testable import UpNext

/// Finishing an episode dequeues it from the playlist it was played in. What
/// happens to the *same* episode sitting in other playlists is now each of those
/// playlists' own choice.
final class PlaylistCrossPlaylistRemovalTests: XCTestCase {
    func testFinishingAnEpisodeRemovesItFromOtherPlaylistsByDefault() async throws {
        let fixture = try makeFixture()
        try queue(fixture.episodes[0], in: fixture.playedIn, order: 0, fixture: fixture)
        try queue(fixture.episodes[0], in: fixture.other, order: 0, fixture: fixture)

        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.playedIn.id
        )
        _ = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )

        XCTAssertEqual(try entryCount(in: fixture.playedIn, fixture: fixture), 0)
        XCTAssertEqual(try entryCount(in: fixture.other, fixture: fixture), 0)
    }

    func testOptedOutPlaylistKeepsAnEpisodeFinishedElsewhere() async throws {
        let fixture = try makeFixture()
        fixture.other.removesEpisodesPlayedElsewhere = false
        try fixture.context.save()
        try queue(fixture.episodes[0], in: fixture.playedIn, order: 0, fixture: fixture)
        try queue(fixture.episodes[0], in: fixture.other, order: 0, fixture: fixture)

        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.playedIn.id
        )
        _ = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )

        XCTAssertEqual(try entryCount(in: fixture.playedIn, fixture: fixture), 0)
        XCTAssertEqual(try entryCount(in: fixture.other, fixture: fixture), 1)
    }

    /// Opting out only covers plays that happened somewhere else — the playlist
    /// you actually listened in still advances past the finished episode.
    func testOptedOutPlaylistStillDequeuesAnEpisodeFinishedInIt() async throws {
        let fixture = try makeFixture()
        fixture.playedIn.removesEpisodesPlayedElsewhere = false
        try fixture.context.save()
        try queue(fixture.episodes[0], in: fixture.playedIn, order: 0, fixture: fixture)
        try queue(fixture.episodes[1], in: fixture.playedIn, order: 1, fixture: fixture)

        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.playedIn.id
        )
        let nextURL = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
        XCTAssertEqual(try entryCount(in: fixture.playedIn, fixture: fixture), 1)
    }

    func testNewPlaylistsRemovePlayedEpisodesByDefault() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.playedIn.removesEpisodesPlayedElsewhere)
        XCTAssertTrue(fixture.other.removesEpisodesPlayedElsewhere)
    }

    // MARK: - Helpers

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let playedIn: Playlist
        let other: Playlist
        let episodes: [Episode]
    }

    private func entryCount(in playlist: Playlist, fixture: Fixture) throws -> Int {
        let context = ModelContext(fixture.container)
        let playlistID = playlist.id
        return try context.fetch(
            FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> { entry in
                    entry.playlist?.id == playlistID
                }
            )
        ).count
    }

    private func queue(
        _ episode: Episode,
        in playlist: Playlist,
        order: Int,
        fixture: Fixture
    ) throws {
        let entry = PlaylistEntry(episode: episode, order: order)
        fixture.context.insert(entry)
        entry.playlist = playlist
        try fixture.context.save()
    }

    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
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
        let context = ModelContext(container)

        let playedIn = Playlist()
        playedIn.title = "Up Next"
        playedIn.deleteable = true
        playedIn.sortIndex = 1
        playedIn.kind = .manual
        context.insert(playedIn)

        let other = Playlist()
        other.title = "Favourites"
        other.deleteable = true
        other.sortIndex = 2
        other.kind = .manual
        context.insert(other)

        let episodes = (0..<2).map { index in
            Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                url: URL(string: "https://example.com/episode-\(index).mp3")!,
                duration: 100
            )
        }
        episodes.forEach(context.insert)
        try context.save()

        return Fixture(
            container: container,
            context: context,
            playedIn: playedIn,
            other: other,
            episodes: episodes
        )
    }
}
