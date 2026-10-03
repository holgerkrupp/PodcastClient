import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class TranscriptSearchServiceTests: XCTestCase {
    func testSearchReadsCanonicalLinesAndGroupsLibraryResults() async throws {
        let fixture = try makeFixture()
        let first = insertEpisode(
            title: "First episode",
            guid: "first",
            podcast: fixture.firstPodcast,
            lines: [
                TranscriptLineAndTime(
                    speaker: "Anna",
                    text: "The local archive is searchable.",
                    startTime: 12,
                    endTime: 18
                )
            ],
            in: fixture.context
        )
        _ = insertEpisode(
            title: "Second episode",
            guid: "second",
            podcast: fixture.secondPodcast,
            lines: [
                TranscriptLineAndTime(
                    text: "A different subject.",
                    startTime: 4,
                    endTime: 8
                )
            ],
            in: fixture.context
        )
        try fixture.context.save()

        let service = TranscriptSearchActor(modelContainer: fixture.container)
        let result = try await service.search(
            TranscriptSearchQuery(text: "local", scope: .library, limit: 10)
        )

        XCTAssertEqual(result.totalMatches, 1)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].episodes[0].episodeID, first.stableEpisodeIdentity.key)
        XCTAssertEqual(result.groups[0].episodes[0].passages[0].startTime, 12)
        XCTAssertTrue(result.groups[0].episodes[0].passages[0].snippet.contains("local"))
    }

    func testPodcastAndEpisodeScopesUseCanonicalRelationships() async throws {
        let fixture = try makeFixture()
        let episode = insertEpisode(
            title: "Scoped episode",
            guid: "scoped",
            podcast: fixture.firstPodcast,
            lines: [
                TranscriptLineAndTime(text: "scope phrase", startTime: 20),
                TranscriptLineAndTime(text: "another phrase", startTime: 40)
            ],
            in: fixture.context
        )
        _ = insertEpisode(
            title: "Other podcast episode",
            guid: "other",
            podcast: fixture.secondPodcast,
            lines: [TranscriptLineAndTime(text: "scope phrase", startTime: 2)],
            in: fixture.context
        )
        try fixture.context.save()

        let service = TranscriptSearchActor(modelContainer: fixture.container)
        let podcastResult = try await service.search(
            TranscriptSearchQuery(
                text: "scope",
                scope: .podcast(fixture.firstPodcast.stablePodcastIdentityKey),
                limit: 10
            )
        )
        let episodeResult = try await service.search(
            TranscriptSearchQuery(
                text: "phrase",
                scope: .episode(episode.stableEpisodeIdentity.key),
                limit: 10
            )
        )

        XCTAssertEqual(podcastResult.totalMatches, 1)
        XCTAssertEqual(podcastResult.groups.flatMap(\.episodes).map(\.episodeID), [episode.stableEpisodeIdentity.key])
        XCTAssertEqual(episodeResult.totalMatches, 2)
        XCTAssertEqual(episodeResult.groups.flatMap(\.episodes).map(\.episodeID), [episode.stableEpisodeIdentity.key])
    }

    func testReplacementIsImmediatelyVisibleWithoutIndexLifecycle() async throws {
        let fixture = try makeFixture()
        let episode = insertEpisode(
            title: "Replacement",
            guid: "replacement",
            podcast: fixture.firstPodcast,
            lines: [TranscriptLineAndTime(text: "old text", startTime: 1)],
            in: fixture.context
        )
        try fixture.context.save()

        let service = TranscriptSearchActor(modelContainer: fixture.container)
        let oldResult = try await service.search(
            TranscriptSearchQuery(text: "old", scope: .episode(episode.stableEpisodeIdentity.key))
        )
        XCTAssertEqual(oldResult.totalMatches, 1)

        let oldLine = try XCTUnwrap(episode.transcriptLines?.first)
        fixture.context.delete(oldLine)
        let replacement = TranscriptLineAndTime(text: "new text", startTime: 3)
        replacement.episode = episode
        fixture.context.insert(replacement)
        try fixture.context.save()

        let newResult = try await service.search(
            TranscriptSearchQuery(text: "new", scope: .episode(episode.stableEpisodeIdentity.key))
        )
        XCTAssertEqual(newResult.totalMatches, 1)
        XCTAssertEqual(newResult.groups[0].episodes[0].passages[0].startTime, 3)
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let firstPodcast: Podcast
        let secondPodcast: Podcast
    }

    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            TranscriptLineAndTime.self,
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
        let firstPodcast = Podcast(feed: URL(string: "https://example.com/first.xml")!)
        firstPodcast.title = "First podcast"
        let secondPodcast = Podcast(feed: URL(string: "https://example.com/second.xml")!)
        secondPodcast.title = "Second podcast"
        context.insert(firstPodcast)
        context.insert(secondPodcast)
        return Fixture(
            container: container,
            context: context,
            firstPodcast: firstPodcast,
            secondPodcast: secondPodcast
        )
    }

    @discardableResult
    private func insertEpisode(
        title: String,
        guid: String,
        podcast: Podcast,
        lines: [TranscriptLineAndTime],
        in context: ModelContext
    ) -> Episode {
        let episode = Episode(
            guid: guid,
            title: title,
            url: URL(string: "https://example.com/\(guid).mp3")!,
            podcast: podcast
        )
        context.insert(episode)
        for line in lines {
            line.episode = episode
            context.insert(line)
        }
        return episode
    }
}
