import XCTest
@testable import UpNext

final class ChapterSkipRecognitionTests: XCTestCase {
    func testFiveDifferentEpisodesTriggerOnePodcastSpecificSuggestion() throws {
        var history = ChapterSkipRecognitionHistory()
        for number in 1...4 {
            XCTAssertNil(history.record(
                podcastKey: "podcast-a", episodeKey: "episode-\(number)",
                title: "Werbung: Jetzt anmelden"
            ))
        }

        let fifth = try XCTUnwrap(history.record(
            podcastKey: "podcast-a", episodeKey: "episode-5",
            title: "Eine kurze Werbung"
        ))
        XCTAssertEqual(fifth.keyword, "werbung")
        XCTAssertEqual(fifth.skipCount, 5)
        XCTAssertNil(history.pendingByPodcast["podcast-b"])
        XCTAssertEqual(history.pendingByPodcast["podcast-a"], fifth)
    }

    func testRepeatedSkipsInSameEpisodeDoNotInflateConfidence() {
        var history = ChapterSkipRecognitionHistory()
        for _ in 0..<20 {
            XCTAssertNil(history.record(
                podcastKey: "one", episodeKey: "same-episode", title: "Sponsor"
            ))
        }
        XCTAssertEqual(history.keywordsByPodcast["one"]?["sponsor"]?.episodeKeys.count, 1)
    }

    func testObservationsDoNotMixBetweenPodcasts() {
        var history = ChapterSkipRecognitionHistory()
        for index in 1...4 {
            _ = history.record(podcastKey: "one", episodeKey: "episode-\(index)", title: "Intro")
            _ = history.record(podcastKey: "two", episodeKey: "episode-\(index)", title: "Intro")
        }
        XCTAssertNotNil(history.record(podcastKey: "one", episodeKey: "episode-5", title: "Intro"))
        XCTAssertNil(history.pendingByPodcast["two"])
    }

    func testSuggestionOnlyFiresOnceAndRemainsDismissedAfterSaving() throws {
        var history = ChapterSkipRecognitionHistory()
        var suggestion: ChapterSkipRuleSuggestion?
        for index in 1...5 {
            suggestion = history.record(
                podcastKey: "podcast", episodeKey: "episode-\(index)", title: "Advertisement"
            ) ?? suggestion
        }
        let accepted = try XCTUnwrap(suggestion)
        history.complete(accepted)
        XCTAssertNil(history.pendingByPodcast["podcast"])
        XCTAssertNil(history.record(
            podcastKey: "podcast", episodeKey: "episode-6", title: "Advertisement"
        ))
    }

    func testGenericWordsAndNumbersAreIgnored() {
        XCTAssertEqual(
            ChapterSkipRecognitionHistory.keywords(in: "Chapter 12 – The Episode Part 2"),
            []
        )
    }

    @MainActor
    func testNextChapterNearBoundaryDoesNotCount() {
        XCTAssertTrue(ChapterSkipRecognition.isDeliberateNextChapterSkip(
            position: 15, chapterStart: 0, chapterEnd: 90
        ))
        XCTAssertFalse(ChapterSkipRecognition.isDeliberateNextChapterSkip(
            position: 85, chapterStart: 0, chapterEnd: 90
        ))
        XCTAssertFalse(ChapterSkipRecognition.isDeliberateNextChapterSkip(
            position: 90, chapterStart: 0, chapterEnd: 90
        ))
    }
}
