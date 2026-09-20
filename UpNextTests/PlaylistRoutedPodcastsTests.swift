import SwiftData
import XCTest
@testable import UpNext

/// Which podcasts a playlist settings screen lists as "added automatically".
///
/// The rule has to match `EpisodeActor.processAfterCreation`, which is what
/// actually queues a new episode: enabled podcast settings win over the global
/// default, a queue position of `.none` means the podcast is queued nowhere, and
/// a target playlist that no longer exists falls back to the built-in queue.
final class PlaylistRoutedPodcastsTests: XCTestCase {
    func testPodcastsFollowTheGlobalDefaultPlaylist() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.commute.id
        fixture.globalSettings.playnextPosition = .end
        try fixture.context.save()

        let commuteTitles = await titles(routedTo: fixture.commute, fixture: fixture)
        let queueTitles = await titles(routedTo: fixture.defaultQueue, fixture: fixture)

        XCTAssertEqual(commuteTitles, ["Daily News", "Deep Dive"])
        XCTAssertEqual(queueTitles, [])
    }

    func testEnabledPodcastSettingsOverrideTheGlobalDefault() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.defaultQueue.id
        fixture.globalSettings.playnextPosition = .end
        let custom = PodcastSettings(podcast: fixture.deepDive)
        custom.isEnabled = true
        custom.defaultPlaylistID = fixture.commute.id
        custom.playnextPosition = .front
        fixture.context.insert(custom)
        try fixture.context.save()

        let commuteTitles = await titles(routedTo: fixture.commute, fixture: fixture)
        let queueTitles = await titles(routedTo: fixture.defaultQueue, fixture: fixture)

        XCTAssertEqual(commuteTitles, ["Deep Dive"])
        XCTAssertEqual(queueTitles, ["Daily News"])
    }

    /// Custom settings only count while they are switched on, which is the same
    /// condition `fetchPodcastSettings` applies everywhere else.
    func testDisabledPodcastSettingsAreIgnored() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.defaultQueue.id
        fixture.globalSettings.playnextPosition = .end
        let custom = PodcastSettings(podcast: fixture.deepDive)
        custom.isEnabled = false
        custom.defaultPlaylistID = fixture.commute.id
        custom.playnextPosition = .front
        fixture.context.insert(custom)
        try fixture.context.save()

        let commuteTitles = await titles(routedTo: fixture.commute, fixture: fixture)
        let queueTitles = await titles(routedTo: fixture.defaultQueue, fixture: fixture)

        XCTAssertEqual(commuteTitles, [])
        XCTAssertEqual(queueTitles, ["Daily News", "Deep Dive"])
    }

    func testPodcastsQueuedNowhereAreNotListed() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.commute.id
        fixture.globalSettings.playnextPosition = .none
        try fixture.context.save()

        let commuteTitles = await titles(routedTo: fixture.commute, fixture: fixture)

        XCTAssertEqual(commuteTitles, [])
    }

    func testUnsubscribedPodcastsAreNotListed() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.commute.id
        fixture.globalSettings.playnextPosition = .end
        fixture.deepDive.metaData?.isSubscribed = false
        try fixture.context.save()

        let commuteTitles = await titles(routedTo: fixture.commute, fixture: fixture)

        XCTAssertEqual(commuteTitles, ["Daily News"])
    }

    /// A podcast pointing at a deleted playlist still gets its episodes, in the
    /// built-in queue — so that is where the settings screen must show it.
    func testRoutingToAMissingPlaylistFallsBackToTheBuiltInQueue() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.defaultQueue.id
        fixture.globalSettings.playnextPosition = .end
        let custom = PodcastSettings(podcast: fixture.deepDive)
        custom.isEnabled = true
        custom.defaultPlaylistID = UUID()
        custom.playnextPosition = .end
        fixture.context.insert(custom)
        try fixture.context.save()

        let queueTitles = await titles(routedTo: fixture.defaultQueue, fixture: fixture)

        XCTAssertEqual(queueTitles, ["Daily News", "Deep Dive"])
    }

    func testRoutedPodcastReportsWhereItsRoutingComesFrom() async throws {
        let fixture = try makeFixture()
        fixture.globalSettings.defaultPlaylistID = fixture.commute.id
        fixture.globalSettings.playnextPosition = .end
        let custom = PodcastSettings(podcast: fixture.deepDive)
        custom.isEnabled = true
        custom.defaultPlaylistID = fixture.commute.id
        custom.playnextPosition = .front
        fixture.context.insert(custom)
        try fixture.context.save()

        let routed = await PodcastSettingsModelActor(modelContainer: fixture.container)
            .podcastsRouted(toPlaylistID: fixture.commute.id)

        let deepDive = try XCTUnwrap(routed.first { $0.title == "Deep Dive" })
        XCTAssertTrue(deepDive.usesCustomSettings)
        XCTAssertEqual(deepDive.position, .front)

        let dailyNews = try XCTUnwrap(routed.first { $0.title == "Daily News" })
        XCTAssertFalse(dailyNews.usesCustomSettings)
        XCTAssertEqual(dailyNews.position, .end)
    }

    // MARK: - Helpers

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let defaultQueue: Playlist
        let commute: Playlist
        let dailyNews: Podcast
        let deepDive: Podcast
        let globalSettings: PodcastSettings
    }

    private func titles(routedTo playlist: Playlist, fixture: Fixture) async -> [String] {
        await PodcastSettingsModelActor(modelContainer: fixture.container)
            .podcastsRouted(toPlaylistID: playlist.id)
            .map(\.title)
    }

    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            PodcastSettings.self,
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

        let defaultQueue = Playlist.ensureDefaultQueue(in: context)

        let commute = Playlist()
        commute.title = "Commute"
        commute.deleteable = true
        commute.sortIndex = 1
        commute.kind = .manual
        context.insert(commute)

        let dailyNews = Podcast(feed: URL(string: "https://example.com/news.xml")!)
        dailyNews.title = "Daily News"
        context.insert(dailyNews)

        let deepDive = Podcast(feed: URL(string: "https://example.com/deep.xml")!)
        deepDive.title = "Deep Dive"
        context.insert(deepDive)

        let globalSettings = PodcastSettings(defaultSettings: true)
        context.insert(globalSettings)

        try context.save()

        return Fixture(
            container: container,
            context: context,
            defaultQueue: defaultQueue,
            commute: commute,
            dailyNews: dailyNews,
            deepDive: deepDive,
            globalSettings: globalSettings
        )
    }
}
