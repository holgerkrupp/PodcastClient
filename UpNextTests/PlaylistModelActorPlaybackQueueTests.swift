import SwiftData
import XCTest
@testable import UpNext

final class PlaylistModelActorPlaybackQueueTests: XCTestCase {
    func testNextEpisodeAfterCurrentWhenCurrentIsFirst() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([0, 1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: fixture.selectedPlaylist.id)

        let nextURL = try await actor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[0].url))

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
    }

    func testNextEpisodeAfterCurrentWhenCurrentIsInMiddle() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([0, 1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: fixture.selectedPlaylist.id)

        let nextURL = try await actor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[1].url))

        XCTAssertEqual(nextURL, fixture.episodes[2].url)
    }

    func testNextEpisodeFallsBackToFirstWhenCurrentIsAbsent() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: fixture.selectedPlaylist.id)

        let nextURL = try await actor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[0].url))

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
    }

    func testNextEpisodeReturnsNilForEmptySelectedPlaylist() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        let actor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: fixture.selectedPlaylist.id)

        let nextURL = try await actor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[0].url))

        XCTAssertNil(nextURL)
    }

    func testActivePlaybackPlaylistFallsBackToDefaultWhenStoredSelectionIsStale() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        let defaults = makeDefaults()
        defaults.set(UUID().uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        try queueEpisodes([1], in: fixture.defaultPlaylist, fixture: fixture)

        let selectedPlaylistID = Playlist.resolvedSelectedManualPlaylistID(
            in: fixture.context,
            defaults: defaults
        )
        let activeActor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: selectedPlaylistID)
        let nextURL = try await activeActor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[0].url))

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
        XCTAssertEqual(defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID), fixture.defaultPlaylist.id.uuidString)
    }

    func testActivePlaybackPlaylistUsesStoredSelectedPlaylist() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        let defaults = makeDefaults()
        defaults.set(fixture.selectedPlaylist.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        try queueEpisodes([2], in: fixture.selectedPlaylist, fixture: fixture)

        let selectedPlaylistID = Playlist.resolvedSelectedManualPlaylistID(
            in: fixture.context,
            defaults: defaults
        )
        let activeActor = try PlaylistModelActor(modelContainer: fixture.container, playlistID: selectedPlaylistID)
        let nextURL = try await activeActor.nextEpisodeURL(after: try XCTUnwrap(fixture.episodes[0].url))

        XCTAssertEqual(nextURL, fixture.episodes[2].url)
    }
}

private extension PlaylistModelActorPlaybackQueueTests {
    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let defaultPlaylist: Playlist
        let selectedPlaylist: Playlist
        let episodes: [Episode]
    }

    func makeDefaults() -> UserDefaults {
        let suiteName = "PlaylistModelActorPlaybackQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func makeFixture(selectedPlaylistTitle: String) throws -> Fixture {
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
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: context)
        let selectedPlaylist = Playlist()
        selectedPlaylist.title = selectedPlaylistTitle
        selectedPlaylist.deleteable = true
        selectedPlaylist.hidden = false
        selectedPlaylist.sortIndex = 1
        selectedPlaylist.kind = .manual
        context.insert(selectedPlaylist)

        let episodes = (0..<3).map { index in
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
            defaultPlaylist: defaultPlaylist,
            selectedPlaylist: selectedPlaylist,
            episodes: episodes
        )
    }

    func queueEpisodes(_ episodeIndexes: [Int], in playlist: Playlist, fixture: Fixture) throws {
        for (order, episodeIndex) in episodeIndexes.enumerated() {
            let entry = PlaylistEntry(episode: fixture.episodes[episodeIndex], order: order)
            fixture.context.insert(entry)
            entry.playlist = playlist
        }
        try fixture.context.save()
    }
}
