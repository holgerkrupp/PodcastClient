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

    func testFinishingEpisodeAtomicallyDequeuesItAndReturnsSuccessor() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([0, 1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )

        let nextURL = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )
        let orderedURLs = try await actor.orderedEpisodeURLs()
        let containsFinishedEpisode = try await actor.containsEpisodeURL(
            try XCTUnwrap(fixture.episodes[0].url)
        )

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
        XCTAssertEqual(
            orderedURLs,
            [fixture.episodes[1].url, fixture.episodes[2].url].compactMap { $0 }
        )
        XCTAssertFalse(containsFinishedEpisode)
    }

    func testFinishingLastEpisodeDequeuesItAndReturnsNil() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([0], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )

        let nextURL = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )
        let orderedURLs = try await actor.orderedEpisodeURLs()

        XCTAssertNil(nextURL)
        XCTAssertEqual(orderedURLs, [])
    }

    func testFinishingEpisodeRemovesDuplicateEntriesAndNormalizesOrder() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([0, 0, 1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        try queueEpisodes([2, 0, 1], in: fixture.defaultPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )

        let nextURL = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
        let context = ModelContext(fixture.container)
        let playlistID = fixture.selectedPlaylist.id
        let entries = try context.fetch(FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { $0.playlist?.id == playlistID },
            sortBy: [SortDescriptor(\PlaylistEntry.order)]
        ))
        XCTAssertEqual(entries.compactMap { $0.episode?.url }, [
            fixture.episodes[1].url,
            fixture.episodes[2].url
        ].compactMap { $0 })
        XCTAssertEqual(entries.map(\.order), [0, 1])

        let defaultPlaylistID = fixture.defaultPlaylist.id
        let defaultEntries = try context.fetch(FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { $0.playlist?.id == defaultPlaylistID },
            sortBy: [SortDescriptor(\PlaylistEntry.order)]
        ))
        XCTAssertEqual(defaultEntries.compactMap { $0.episode?.url }, [
            fixture.episodes[2].url,
            fixture.episodes[1].url
        ].compactMap { $0 })
        XCTAssertEqual(defaultEntries.map(\.order), [0, 1])
    }

    func testFinishingAlreadyDequeuedEpisodeReturnsFirstQueuedEpisode() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        try queueEpisodes([1, 2], in: fixture.selectedPlaylist, fixture: fixture)
        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )

        let nextURL = try await actor.dequeueFinishedEpisodeAndReturnNext(
            after: try XCTUnwrap(fixture.episodes[0].url)
        )
        let orderedURLs = try await actor.orderedEpisodeURLs()

        XCTAssertEqual(nextURL, fixture.episodes[1].url)
        XCTAssertEqual(
            orderedURLs,
            [fixture.episodes[1].url, fixture.episodes[2].url].compactMap { $0 }
        )
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

    func testAddingToPlaylistRemovesFromInboxAndPreservesArchiveState() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        let episode = fixture.episodes[0]
        episode.metaData?.setArchived(true, at: Date(timeIntervalSince1970: 1_000))
        episode.metaData?.systemSuppressionReason = .manualPlaylistRemoval
        try fixture.context.save()

        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )
        try await actor.add(
            episodeURL: try XCTUnwrap(episode.url),
            to: .end,
            startDownload: false
        )

        let refreshed = try fetchEpisode(
            url: try XCTUnwrap(episode.url),
            container: fixture.container
        )
        XCTAssertEqual(refreshed.metaData?.isInbox, false)
        XCTAssertEqual(refreshed.metaData?.isArchived, true)
        XCTAssertEqual(refreshed.metaData?.status, .archived)
        XCTAssertNil(refreshed.metaData?.systemSuppressionReason)
        let isQueued = try await actor.containsEpisodeURL(try XCTUnwrap(episode.url))
        XCTAssertTrue(isQueued)
    }

    func testUserPlaylistRemovalPreservesEpisodeStateAndPreventsAutomaticRequeue() async throws {
        let fixture = try makeFixture(selectedPlaylistTitle: "Selected")
        let episode = fixture.episodes[0]
        try queueEpisodes([0], in: fixture.selectedPlaylist, fixture: fixture)

        let actor = try PlaylistModelActor(
            modelContainer: fixture.container,
            playlistID: fixture.selectedPlaylist.id
        )
        try await actor.remove(episodeURL: try XCTUnwrap(episode.url))

        let refreshed = try fetchEpisode(
            url: try XCTUnwrap(episode.url),
            container: fixture.container
        )
        XCTAssertEqual(refreshed.metaData?.isInbox, true)
        XCTAssertEqual(refreshed.metaData?.isArchived, false)
        XCTAssertEqual(refreshed.metaData?.status, .inbox)
        XCTAssertEqual(
            refreshed.metaData?.systemSuppressionReason,
            .manualPlaylistRemoval
        )
        let isQueued = try await actor.containsEpisodeURL(try XCTUnwrap(episode.url))
        XCTAssertFalse(isQueued)
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

    func fetchEpisode(url: URL, container: ModelContainer) throws -> Episode {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == url }
        )
        return try XCTUnwrap(context.fetch(descriptor).first)
    }
}
