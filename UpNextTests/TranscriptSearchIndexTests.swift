import Foundation
import XCTest
@testable import UpNext

final class TranscriptSearchIndexTests: XCTestCase {
    private var directory: URL!
    private var index: TranscriptSearchIndex!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("search.sqlite")
        index = TranscriptSearchIndex(storeURL: storeURL)
    }

    override func tearDown() async throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testSearchIsUnicodeInsensitiveAndGroupsByPodcastAndEpisode() async throws {
        try await index.upsert(makeEpisode(
            podcastID: "podcast-a",
            podcastTitle: "Der Forschungspodcast",
            episodeID: "episode-a",
            episodeTitle: "Über Wörter",
            revision: "publisher-1",
            lines: [
                TranscriptSearchLine(id: "line-1", speaker: "Anna", text: "Die Straße führt über den Berg.", startTime: 12, endTime: 18),
                TranscriptSearchLine(id: "line-2", speaker: "Ben", text: "This is a phrase about local search.", startTime: 30, endTime: 36)
            ]
        ))
        try await index.upsert(makeEpisode(
            podcastID: "podcast-b",
            podcastTitle: "Second Show",
            episodeID: "episode-b",
            episodeTitle: "Search episode",
            revision: "publisher-1",
            lines: [
                TranscriptSearchLine(id: "line-3", speaker: nil, text: "Local search works here too.", startTime: 4, endTime: 8)
            ]
        ))

        let result = try await index.search(
            TranscriptSearchQuery(text: "strasse", scope: .library)
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].podcastTitle, "Der Forschungspodcast")
        XCTAssertEqual(result.groups[0].episodes[0].episodeTitle, "Über Wörter")
        XCTAssertEqual(result.groups[0].episodes[0].passages[0].startTime, 12)
        XCTAssertTrue(result.groups[0].episodes[0].passages[0].snippet.contains("Straße"))
    }

    func testPhraseAndPodcastScopeDoNotLoadOtherPodcasts() async throws {
        try await index.upsert(makeEpisode(
            podcastID: "podcast-a",
            podcastTitle: "A",
            episodeID: "episode-a",
            episodeTitle: "A episode",
            revision: "v1",
            lines: [TranscriptSearchLine(id: "a", speaker: nil, text: "The exact phrase appears here.", startTime: 10, endTime: 11)]
        ))
        try await index.upsert(makeEpisode(
            podcastID: "podcast-b",
            podcastTitle: "B",
            episodeID: "episode-b",
            episodeTitle: "B episode",
            revision: "v1",
            lines: [TranscriptSearchLine(id: "b", speaker: nil, text: "The phrase is split across unrelated words.", startTime: 20, endTime: 21)]
        ))

        let result = try await index.search(
            TranscriptSearchQuery(text: "exact phrase", scope: .podcast("podcast-a"))
        )

        XCTAssertEqual(result.totalMatches, 1)
        XCTAssertEqual(result.groups.flatMap(\.episodes).map(\.episodeID), ["episode-a"])
        XCTAssertEqual(result.groups[0].episodes[0].passages[0].matchedTerms, ["exact", "phrase"])
    }

    func testReplacementIsIdempotentAndRemovesStaleText() async throws {
        let original = makeEpisode(
            podcastID: "podcast-a",
            podcastTitle: "A",
            episodeID: "episode-a",
            episodeTitle: "Replacement",
            revision: "v1",
            lines: [TranscriptSearchLine(id: "line", speaker: nil, text: "old transcript text", startTime: 1, endTime: 2)]
        )
        let firstInsert = try await index.upsert(original)
        XCTAssertTrue(firstInsert)
        let duplicateInsert = try await index.upsert(original)
        XCTAssertFalse(duplicateInsert)

        let replacement = makeEpisode(
            podcastID: "podcast-a",
            podcastTitle: "A",
            episodeID: "episode-a",
            episodeTitle: "Replacement",
            revision: "v2",
            lines: [TranscriptSearchLine(id: "line", speaker: nil, text: "new transcript text", startTime: 3, endTime: 4)]
        )
        let replacementInsert = try await index.upsert(replacement)
        XCTAssertTrue(replacementInsert)
        let oldResult = try await index.search(TranscriptSearchQuery(text: "old", scope: .library))
        XCTAssertTrue(oldResult.groups.isEmpty)
        let newResult = try await index.search(TranscriptSearchQuery(text: "new", scope: .episode("episode-a")))
        XCTAssertEqual(newResult.groups[0].episodes[0].passages[0].startTime, 3)

        try await index.removeEpisode(episodeID: "episode-a")
        let removed = try await index.search(TranscriptSearchQuery(text: "new", scope: .library))
        XCTAssertTrue(removed.groups.isEmpty)
    }

    private func makeEpisode(
        podcastID: String,
        podcastTitle: String,
        episodeID: String,
        episodeTitle: String,
        revision: String,
        lines: [TranscriptSearchLine]
    ) -> TranscriptSearchEpisodeSnapshot {
        TranscriptSearchEpisodeSnapshot(
            podcastID: podcastID,
            podcastTitle: podcastTitle,
            podcastImageURL: nil,
            episodeID: episodeID,
            episodeTitle: episodeTitle,
            episodeURL: URL(string: "https://example.com/\(episodeID).mp3"),
            episodeImageURL: nil,
            publishDate: Date(timeIntervalSince1970: 1_000),
            revision: revision,
            lines: lines
        )
    }
}
