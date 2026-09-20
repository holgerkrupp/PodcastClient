import SwiftData
import XCTest
@testable import UpNext

final class PlaylistAutoDownloadPolicyTests: XCTestCase {
    func testPolicyOffSelectsNothing() async throws {
        let fixture = try makeFixture()
        try queueEpisodes([0, 1, 2], in: fixture.playlist, fixture: fixture)

        let pending = await service(fixture).pendingDownloadURLs(for: fixture.playlist.id)

        XCTAssertEqual(pending, [])
    }

    func testUnlimitedPolicySelectsEveryQueuedEpisodeInPlaylistOrder() async throws {
        let fixture = try makeFixture()
        try queueEpisodes([2, 0, 1], in: fixture.playlist, fixture: fixture)
        try enableAutoDownload(limit: nil, in: fixture)

        let pending = await service(fixture).pendingDownloadURLs(for: fixture.playlist.id)

        XCTAssertEqual(
            pending,
            [fixture.episodes[2].url, fixture.episodes[0].url, fixture.episodes[1].url]
                .compactMap { $0 }
        )
    }

    func testLimitOnlySelectsTheTopOfThePlaylist() async throws {
        let fixture = try makeFixture()
        try queueEpisodes([0, 1, 2], in: fixture.playlist, fixture: fixture)
        try enableAutoDownload(limit: 2, in: fixture)

        let pending = await service(fixture).pendingDownloadURLs(for: fixture.playlist.id)

        XCTAssertEqual(
            pending,
            [fixture.episodes[0].url, fixture.episodes[1].url].compactMap { $0 }
        )
    }

    /// A downloaded episode still occupies its slot in the limit, so the episode
    /// below it must not be pulled forward just because nothing is left to fetch.
    func testDownloadedEpisodesConsumeTheirSlotInTheLimit() async throws {
        let fixture = try makeFixture()
        try queueEpisodes([0, 1, 2], in: fixture.playlist, fixture: fixture)
        try enableAutoDownload(limit: 2, in: fixture)
        // `calculatedIsAvailableLocally` asks the file system, so the fixture has
        // to put a real file where the episode expects its download.
        let localFile = try XCTUnwrap(fixture.episodes[0].localFile)
        try Data("audio".utf8).write(to: localFile)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: localFile)
        }

        let pending = await service(fixture).pendingDownloadURLs(for: fixture.playlist.id)

        XCTAssertEqual(pending, [fixture.episodes[1].url].compactMap { $0 })
    }

    func testStoredLimitIsClampedIntoTheSupportedRange() throws {
        let fixture = try makeFixture()
        try enableAutoDownload(limit: 0, in: fixture)

        XCTAssertEqual(
            fixture.playlist.resolvedAutoDownloadEpisodeLimit,
            Playlist.autoDownloadEpisodeLimitRange.lowerBound
        )

        try enableAutoDownload(limit: 5_000, in: fixture)

        XCTAssertEqual(
            fixture.playlist.resolvedAutoDownloadEpisodeLimit,
            Playlist.autoDownloadEpisodeLimitRange.upperBound
        )
    }

    func testSnapshotCarriesTheDownloadSettingsForSync() throws {
        let fixture = try makeFixture()
        try enableAutoDownload(limit: 3, in: fixture)

        let snapshot = fixture.playlist.storeSplitSnapshot

        XCTAssertTrue(snapshot.autoDownloadEnabled)
        XCTAssertEqual(snapshot.autoDownloadEpisodeLimit, 3)
    }

    func testSnapshotCarriesTheCrossPlaylistRemovalSetting() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.playlist.storeSplitSnapshot.removesEpisodesPlayedElsewhere)

        fixture.playlist.removesEpisodesPlayedElsewhere = false
        try fixture.context.save()

        XCTAssertFalse(fixture.playlist.storeSplitSnapshot.removesEpisodesPlayedElsewhere)
    }

    func testSnapshotReportsNoLimitAsNil() throws {
        let fixture = try makeFixture()
        try enableAutoDownload(limit: nil, in: fixture)

        let snapshot = fixture.playlist.storeSplitSnapshot

        XCTAssertTrue(snapshot.autoDownloadEnabled)
        XCTAssertNil(snapshot.autoDownloadEpisodeLimit)
    }

    // MARK: - Helpers

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let playlist: Playlist
        let episodes: [Episode]
    }

    private func service(_ fixture: Fixture) -> PlaylistAutoDownloadService {
        PlaylistAutoDownloadService(modelContainer: fixture.container)
    }

    private func enableAutoDownload(limit: Int?, in fixture: Fixture) throws {
        fixture.playlist.autoDownloadEnabled = true
        fixture.playlist.autoDownloadEpisodeLimit = limit
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

        let playlist = Playlist()
        playlist.title = "Commute"
        playlist.deleteable = true
        playlist.hidden = false
        playlist.sortIndex = 1
        playlist.kind = .manual
        context.insert(playlist)

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
            playlist: playlist,
            episodes: episodes
        )
    }

    private func queueEpisodes(
        _ episodeIndexes: [Int],
        in playlist: Playlist,
        fixture: Fixture
    ) throws {
        for (order, episodeIndex) in episodeIndexes.enumerated() {
            let entry = PlaylistEntry(episode: fixture.episodes[episodeIndex], order: order)
            fixture.context.insert(entry)
            entry.playlist = playlist
        }
        try fixture.context.save()
    }
}
