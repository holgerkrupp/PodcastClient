import SwiftData
import XCTest
@testable import UpNext

#if os(iOS)

final class SwiftDataRelationshipSafetyTests: XCTestCase {
    func testPodcastDetailEpisodeFetchAfterSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastDetailSQLite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Episodes.sqlite")

        func container() throws -> ModelContainer {
            try ModelContainer(
                for: Podcast.self, PodcastMetaData.self, Episode.self,
                EpisodeMetaData.self, TranscriptLineAndTime.self,
                configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
            )
        }

        do {
            let writer = ModelContext(try container())
            let selected = Podcast(feed: URL(string: "https://example.com/selected.xml")!)
            let other = Podcast(feed: URL(string: "https://example.com/other.xml")!)
            let empty = Podcast(feed: URL(string: "https://example.com/empty.xml")!)
            let single = Podcast(feed: URL(string: "https://example.com/single.xml")!)
            writer.insert(selected)
            writer.insert(other)
            writer.insert(empty)
            writer.insert(single)
            writer.insert(Episode(
                title: "Only episode",
                url: URL(string: "https://example.com/only.mp3")!,
                podcast: single
            ))
            for index in 0..<120 {
                let episode = Episode(
                    title: "Episode \(index)",
                    publishDate: index.isMultiple(of: 2) && index < 6
                        ? Date().addingTimeInterval(TimeInterval(index - 6) * 7 * 24 * 60 * 60)
                        : nil,
                    url: URL(string: "https://example.com/\(index).mp3")!,
                    podcast: index.isMultiple(of: 2) ? selected : other
                )
                writer.insert(episode)
                if index == 0 {
                    let line = TranscriptLineAndTime(text: "A stored transcript", startTime: 1)
                    line.episode = episode
                    writer.insert(line)
                }
            }
            try writer.save()
        }

        let reopened = try container()
        let reader = ModelContext(reopened)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<Podcast>()), 4)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<Episode>()), 121)
        let podcasts = try reader.fetch(FetchDescriptor<Podcast>())
        let selectedAfterReopen = try XCTUnwrap(
            podcasts.first {
                $0.feed == URL(string: "https://example.com/selected.xml")
            }
        )
        let podcastID = selectedAfterReopen.persistentModelID
        let expectedIDs = Set(try reader.fetch(FetchDescriptor<Episode>()).compactMap {
            $0.podcast?.persistentModelID == podcastID ? $0.persistentModelID : nil
        })
        XCTAssertEqual(expectedIDs.count, 60)
        let request = PodcastEpisodeFilterRequest(
            query: "", searchInTitle: true, searchInAuthor: false,
            searchInDescription: true, searchInTranscript: false,
            hidePlayedAndArchived: false, sort: .newestFirst
        )
        let filter = PodcastEpisodeFilterActor(modelContainer: reopened)
        let ids = try await filter.episodeIDs(
            podcastID: podcastID, request: request
        )
        XCTAssertEqual(Set(ids), expectedIDs)
        let emptyID = try XCTUnwrap(podcasts.first {
            $0.feed == URL(string: "https://example.com/empty.xml")
        }).persistentModelID
        let singleID = try XCTUnwrap(podcasts.first {
            $0.feed == URL(string: "https://example.com/single.xml")
        }).persistentModelID
        let emptyIDs = try await filter.episodeIDs(podcastID: emptyID, request: request)
        let singleIDs = try await filter.episodeIDs(podcastID: singleID, request: request)
        XCTAssertTrue(emptyIDs.isEmpty)
        XCTAssertEqual(singleIDs.count, 1)
        XCTAssertNotNil(PodcastReleasePredictor.prediction(
            for: selectedAfterReopen, after: Date(), allowRelationshipFallback: false
        ))
        let transcriptSearch = TranscriptSearchActor(modelContainer: reopened)
        let selectedHasTranscript = try await transcriptSearch.hasSearchableTranscripts(
            in: .podcast(selectedAfterReopen.stablePodcastIdentityKey)
        )
        let emptyHasTranscript = try await transcriptSearch.hasSearchableTranscripts(
            in: .podcast("https://example.com/empty.xml")
        )
        XCTAssertTrue(selectedHasTranscript)
        XCTAssertFalse(emptyHasTranscript)
    }

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
