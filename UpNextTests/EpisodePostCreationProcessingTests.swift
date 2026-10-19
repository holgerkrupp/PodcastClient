import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class EpisodePostCreationProcessingTests: XCTestCase {
    func testCommittedNewEpisodeUsesEffectiveRoutingAndInsertionIsIdempotent() async throws {
        let fixture = try makeFixture()
        fixture.settings.playnextPosition = .end
        fixture.settings.defaultPlaylistID = fixture.customPlaylist.id
        try fixture.context.save()

        let episodeURL = URL(string: "https://example.com/new-episode.mp3")!
        let episode = Episode(
            guid: "new-episode",
            title: "New episode",
            publishDate: Date(),
            url: episodeURL,
            podcast: fixture.podcast
        )
        fixture.context.insert(episode)
        try fixture.context.save()

        let actor = EpisodeActor(modelContainer: fixture.container)
        await actor.processAfterCreation(episodeURL: episodeURL, sendNotification: false)
        await actor.processAfterCreation(episodeURL: episodeURL, sendNotification: false)

        let customPlaylistID = fixture.customPlaylist.id
        let defaultQueueID = fixture.defaultQueue.id
        let entries = try fixture.context.fetch(
            FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> {
                    $0.playlist?.id == customPlaylistID && $0.episode?.url == episodeURL
                }
            )
        )
        XCTAssertEqual(entries.count, 1)
        let defaultEntries = try fixture.context.fetch(
            FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> {
                    $0.playlist?.id == defaultQueueID && $0.episode?.url == episodeURL
                }
            )
        )
        XCTAssertTrue(defaultEntries.isEmpty)
    }

    func testNoneRoutingLeavesCommittedEpisodeInboxOnly() async throws {
        let fixture = try makeFixture()
        fixture.settings.playnextPosition = .none
        fixture.settings.defaultPlaylistID = fixture.customPlaylist.id
        try fixture.context.save()

        let episodeURL = URL(string: "https://example.com/inbox-only.mp3")!
        let episode = Episode(
            guid: "inbox-only",
            title: "Inbox only",
            publishDate: Date(),
            url: episodeURL,
            podcast: fixture.podcast
        )
        fixture.context.insert(episode)
        try fixture.context.save()

        await EpisodeActor(modelContainer: fixture.container)
            .processAfterCreation(episodeURL: episodeURL, sendNotification: false)

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<PlaylistEntry>()).isEmpty)
        XCTAssertEqual(episode.metaData?.status, .inbox)
    }

    func testMissingCustomPlaylistFallsBackToBuiltInQueue() async throws {
        let fixture = try makeFixture()
        fixture.settings.playnextPosition = .end
        fixture.settings.defaultPlaylistID = fixture.defaultQueue.id
        let customSettings = PodcastSettings(podcast: fixture.podcast)
        customSettings.isEnabled = true
        customSettings.playnextPosition = .front
        customSettings.defaultPlaylistID = UUID()
        fixture.context.insert(customSettings)
        try fixture.context.save()

        let episodeURL = URL(string: "https://example.com/fallback.mp3")!
        fixture.context.insert(Episode(
            guid: "fallback",
            title: "Fallback",
            publishDate: Date(),
            url: episodeURL,
            podcast: fixture.podcast
        ))
        try fixture.context.save()

        await EpisodeActor(modelContainer: fixture.container)
            .processAfterCreation(episodeURL: episodeURL, sendNotification: false)

        let defaultQueueID = fixture.defaultQueue.id
        let defaultEntries = try fixture.context.fetch(
            FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> {
                    $0.playlist?.id == defaultQueueID && $0.episode?.url == episodeURL
                }
            )
        )
        XCTAssertEqual(defaultEntries.count, 1)
    }

    func testSilentFirstPageClassificationUsesSubscriptionBaseline() {
        let subscriptionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let lastRefresh = subscriptionDate.addingTimeInterval(60)
        let recentlyPublished = subscriptionDate.addingTimeInterval(120)
        let olderEpisode = subscriptionDate.addingTimeInterval(-120)

        XCTAssertEqual(
            PodcastEpisodeImportClassification.classify(
                publishDate: recentlyPublished,
                subscriptionDate: subscriptionDate,
                lastSuccessfulRefresh: lastRefresh,
                knownEpisodeCount: 1
            ),
            .newlyPublished
        )
        XCTAssertEqual(
            PodcastEpisodeImportClassification.classify(
                publishDate: olderEpisode,
                subscriptionDate: subscriptionDate,
                lastSuccessfulRefresh: lastRefresh,
                knownEpisodeCount: 1
            ),
            .backCatalog
        )
        XCTAssertEqual(
            PodcastEpisodeImportClassification.classify(
                publishDate: recentlyPublished,
                subscriptionDate: subscriptionDate,
                lastSuccessfulRefresh: nil,
                knownEpisodeCount: 0
            ),
            .backCatalog,
            "Initial subscription episodes remain back catalog."
        )
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let podcast: Podcast
        let defaultQueue: Playlist
        let customPlaylist: Playlist
        let settings: PodcastSettings
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
        let customPlaylist = Playlist()
        customPlaylist.title = "Custom"
        customPlaylist.deleteable = true
        customPlaylist.sortIndex = 1
        customPlaylist.kind = .manual
        context.insert(customPlaylist)

        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Example"
        context.insert(podcast)
        let settings = PodcastSettings(defaultSettings: true)
        settings.playnextPosition = .end
        settings.defaultPlaylistID = defaultQueue.id
        context.insert(settings)
        try context.save()

        return Fixture(
            container: container,
            context: context,
            podcast: podcast,
            defaultQueue: defaultQueue,
            customPlaylist: customPlaylist,
            settings: settings
        )
    }

}
