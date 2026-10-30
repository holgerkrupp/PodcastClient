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
                if index == 2 {
                    episode.url = URL(string: "https://example.com/0.mp3")
                } else if index == 4 {
                    episode.url = nil
                }
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
        XCTAssertEqual(Set(ids.episodeIDs), expectedIDs)
        // Exercise the destination's second-stage visible-model resolution
        // against a reopened SQLite store with one safe URL-membership query.
        let resolvedEpisodes = try reader.episodes(
            forPageIDs: ids.episodeIDs,
            urls: ids.episodeURLs
        )
        let resolvedIDs = Set(resolvedEpisodes.map(\.persistentModelID))
        XCTAssertEqual(resolvedIDs, expectedIDs)
        XCTAssertEqual(resolvedEpisodes.count, 60)
        XCTAssertEqual(resolvedEpisodes.map(\.persistentModelID), ids.episodeIDs)
        XCTAssertTrue(ids.episodeURLs.contains(where: { $0 == nil }))
        let urlOnlyEpisodes = try reader.episodes(forURLs: ids.episodeURLs.compactMap { $0 })
        XCTAssertEqual(urlOnlyEpisodes.count, 59, "the nil-URL row is resolved by ID on the page path")
        let firstPageIDs = Array(ids.episodeIDs.prefix(20))
        let firstPageURLs = Array(ids.episodeURLs.prefix(20))
        let visiblePageURLs = Array(ids.episodeURLs.prefix(20).compactMap { $0 })
        let visiblePageWithDuplicateAndMissingURL = try reader.episodes(
            forURLs: visiblePageURLs + [visiblePageURLs[0], URL(string: "https://example.com/missing.mp3")!]
        )
        let visibleURLIDs = Set(visiblePageWithDuplicateAndMissingURL.map(\.persistentModelID))
        let expectedVisibleURLIDs = Set(zip(firstPageIDs, firstPageURLs).compactMap { id, url in
            url == nil ? nil : id
        })
        XCTAssertTrue(
            expectedVisibleURLIDs.isSubset(of: visibleURLIDs),
            "URL membership should deduplicate input URLs and ignore missing rows without losing matching IDs"
        )
        let emptyID = try XCTUnwrap(podcasts.first {
            $0.feed == URL(string: "https://example.com/empty.xml")
        }).persistentModelID
        let singleID = try XCTUnwrap(podcasts.first {
            $0.feed == URL(string: "https://example.com/single.xml")
        }).persistentModelID
        let emptyIDs = try await filter.episodeIDs(podcastID: emptyID, request: request)
        let singleIDs = try await filter.episodeIDs(podcastID: singleID, request: request)
        XCTAssertTrue(emptyIDs.episodeIDs.isEmpty)
        XCTAssertEqual(singleIDs.episodeIDs.count, 1)
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

        XCTAssertEqual(matches.episodeIDs, [episode.persistentModelID])
    }

    /// Run this regression on a physical iPhone as well as in CI. It covers
    /// empty and large podcast histories, verifies that one visible page is
    /// resolved in a single batched fetch, and exercises the no-transcript
    /// availability path without walking episodes one at a time.
    func testPodcastDetailLargeLibrariesUseOneVisiblePageFetchWithoutTranscripts() async throws {
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            TranscriptLineAndTime.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        var podcasts: [(PersistentIdentifier, String, Int)] = []
        for count in [0, 100, 1_000, 10_000] {
            let podcastContext = ModelContext(container)
            let podcast = Podcast(feed: URL(string: "https://example.com/library-\(count).xml")!)
            podcastContext.insert(podcast)
            try podcastContext.save()
            let podcastID = podcast.persistentModelID
            let podcastIdentity = podcast.stablePodcastIdentityKey
            podcasts.append((podcastID, podcastIdentity, count))

            let feedURL = podcast.feed!
            for lowerBound in stride(from: 0, to: count, by: 500) {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<Podcast>(
                    predicate: #Predicate<Podcast> { $0.feed == feedURL }
                )
                descriptor.fetchLimit = 1
                guard let storedPodcast = try context.fetch(descriptor).first else {
                    XCTFail("Podcast fixture disappeared for count=\(count)")
                    continue
                }
                for index in lowerBound..<min(lowerBound + 500, count) {
                    context.insert(Episode(
                        title: "Episode \(index)",
                        publishDate: Date(timeIntervalSince1970: TimeInterval(index)),
                        url: URL(string: "https://example.com/library-\(count)/episode-\(index).mp3")!,
                        podcast: storedPodcast
                    ))
                }
                try context.save()
            }
        }

        let reader = ModelContext(container)
        let actor = PodcastEpisodeFilterActor(modelContainer: container)
        let transcriptSearch = TranscriptSearchActor(modelContainer: container)
        let request = PodcastEpisodeFilterRequest(
            query: "", searchInTitle: true, searchInAuthor: false,
            searchInDescription: false, searchInTranscript: true,
            hidePlayedAndArchived: false, sort: .newestFirst
        )

        for (podcastID, podcastIdentity, expectedCount) in podcasts {
            let result = try await actor.episodeIDs(
                podcastID: podcastID,
                request: request
            )
            XCTAssertEqual(result.episodeIDs.count, expectedCount, "count=\(expectedCount)")
            XCTAssertEqual(result.episodeURLs.count, expectedCount, "count=\(expectedCount)")
            let hasEpisodes = try await actor.hasEpisodes(podcastID: podcastID)
            XCTAssertEqual(hasEpisodes, expectedCount > 0)
            let hasTranscripts = try await transcriptSearch.hasSearchableTranscripts(
                in: .podcast(podcastIdentity)
            )
            XCTAssertFalse(hasTranscripts, "count=\(expectedCount): fixture intentionally has no transcripts")

            let firstPageURLs = Array(result.episodeURLs.prefix(80).compactMap { $0 })
            let firstPage = try reader.episodes(forURLs: firstPageURLs)
            XCTAssertEqual(firstPage.count, min(expectedCount, 80), "count=\(expectedCount)")
        }
    }
}

#endif
