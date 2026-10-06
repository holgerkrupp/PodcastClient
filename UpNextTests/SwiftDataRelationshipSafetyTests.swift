import SwiftData
import XCTest
@testable import UpNext

#if os(iOS)

final class SwiftDataRelationshipSafetyTests: XCTestCase {
    func testEpisodeFilterFindsTranscriptMatchesThroughDirectLineQuery() async throws {
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            TranscriptLineAndTime.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            title: "Episode",
            url: URL(string: "https://example.com/episode.mp3")!,
            podcast: podcast
        )
        let line = TranscriptLineAndTime(text: "A distinctive transcript phrase", startTime: 10)
        line.episode = episode
        context.insert(podcast)
        context.insert(episode)
        context.insert(line)
        try context.save()

        let request = PodcastEpisodeFilterRequest(
            query: "distinctive",
            searchInTitle: false,
            searchInAuthor: false,
            searchInDescription: false,
            searchInTranscript: true,
            hidePlayedAndArchived: false,
            sort: .newestFirst
        )
        let matches = try await PodcastEpisodeFilterActor(modelContainer: container).episodeIDs(
            podcastID: podcast.persistentModelID,
            request: request
        )

        XCTAssertEqual(matches, [episode.persistentModelID])
    }
}

#endif
