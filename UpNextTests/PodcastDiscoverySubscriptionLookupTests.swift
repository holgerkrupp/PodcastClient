import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class PodcastDiscoverySubscriptionLookupTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            PodcastSettings.self,
            Episode.self,
            EpisodeMetaData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    func testCanonicalAndAlternativeFeedURLsMatchFromOneIndex() throws {
        let context = ModelContext(try makeContainer())
        let podcast = Podcast(feed: URL(string: "https://example.com/main.xml")!)
        podcast.title = "Saved Show"
        podcast.alternativeFeeds = [
            PodcastAlternativeFeed(url: URL(string: "https://example.com/alternate.xml")!, title: "Alternate", type: nil)
        ]
        context.insert(podcast)
        try context.save()
        let lookup = PodcastDiscoverySubscriptionLookup(podcasts: [podcast])

        let canonical = PodcastFeed(url: URL(string: "http://EXAMPLE.com/main.xml/")!, fetchMetadataIfNeeded: false)
        let alternate = PodcastFeed(url: URL(string: "https://example.com/alternate.xml")!, fetchMetadataIfNeeded: false)

        XCTAssertTrue(lookup.existingPodcast(for: canonical, context: context) === podcast)
        XCTAssertTrue(lookup.existingPodcast(for: alternate, context: context) === podcast)
    }

    func testAmbiguousTitleKeepsFirstExistingBehavior() throws {
        let context = ModelContext(try makeContainer())
        let first = Podcast(feed: URL(string: "https://first.example/feed.xml")!)
        first.title = "Same Title"
        let second = Podcast(feed: URL(string: "https://second.example/feed.xml")!)
        second.title = "Same Title"
        context.insert(first)
        context.insert(second)
        try context.save()
        let lookup = PodcastDiscoverySubscriptionLookup(podcasts: [first, second])

        let feed = PodcastFeed(url: URL(string: "https://new.example/feed.xml")!, title: "Same Title", fetchMetadataIfNeeded: false)
        XCTAssertTrue(lookup.existingPodcast(for: feed, context: context) === first)
    }

    func testKnownEpisodeFallbackUsesTargetedEpisodeQuery() throws {
        let context = ModelContext(try makeContainer())
        let podcast = Podcast(feed: URL(string: "https://saved.example/feed.xml")!)
        podcast.title = "Saved Podcast"
        let episodeURL = URL(string: "https://saved.example/old-episode.mp3")!
        let episode = Episode(title: "Old Episode", url: episodeURL, podcast: podcast)
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let lookup = PodcastDiscoverySubscriptionLookup(podcasts: [podcast])
        let imported = PodcastFeed(title: "Imported Name", fetchMetadataIfNeeded: false)
        imported.importedLastEpisodeURL = episodeURL

        XCTAssertTrue(lookup.existingPodcast(for: imported, context: context) === podcast)
    }
}
