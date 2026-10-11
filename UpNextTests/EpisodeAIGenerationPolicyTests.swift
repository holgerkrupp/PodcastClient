import XCTest
@testable import UpNext

final class EpisodeAIGenerationPolicyTests: XCTestCase {
    func testActionMatrixRequiresAppleIntelligence() {
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: false, hasUsableChapters: false),
            .transcribeAndGenerateChapters
        )
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: false, hasUsableChapters: true),
            .transcribe
        )
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: true, hasUsableChapters: false),
            .generateChapters
        )
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: true, hasUsableChapters: true))
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: false, hasTranscript: false, hasUsableChapters: false))
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: false, hasTranscript: true, hasUsableChapters: false))
    }

    func testPlayerChapterRowDoesNotTreatPendingAvailabilityAsMissingContent() {
        XCTAssertNil(
            PlayerChapterRowPolicy.generationAction(
                availability: nil, hasPlaybackChapters: false, aiAvailable: true
            )
        )
        XCTAssertNil(
            PlayerChapterRowPolicy.generationAction(
                availability: nil, hasPlaybackChapters: true, aiAvailable: true
            )
        )
    }

    func testPlayerChapterRowDetectsLoadedChaptersWithoutQuery() {
        let url = URL(string: "https://example.com/episode.mp3")!
        XCTAssertTrue(
            PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
                for: url, activeEpisodeURL: url, chapterCount: 3, firstStart: 0
            )
        )
        XCTAssertTrue(
            PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
                for: url, activeEpisodeURL: url, chapterCount: 1, firstStart: 45
            )
        )
        XCTAssertFalse(
            PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
                for: url, activeEpisodeURL: url, chapterCount: 1, firstStart: 0
            )
        )
        XCTAssertFalse(
            PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
                for: url, activeEpisodeURL: url, chapterCount: 0, firstStart: nil
            )
        )
    }

    func testPlayerChapterRowDoesNotUsePreviousEpisodeChapters() {
        let url = URL(string: "https://example.com/episode.mp3")!
        let previous = URL(string: "https://example.com/previous.mp3")!
        XCTAssertFalse(
            PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
                for: url, activeEpisodeURL: previous, chapterCount: 3, firstStart: 0
            )
        )
    }

    func testPlayerChapterRowNeverOffersToRegenerateAlreadyLoadedChapters() {
        let availability = PlayerContentAvailability(
            episodeURL: URL(string: "https://example.com/episode.mp3")!,
            hasTranscript: false,
            hasChapterSelectionUI: false,
            hasUsableChapters: false
        )
        XCTAssertEqual(
            PlayerChapterRowPolicy.generationAction(
                availability: availability, hasPlaybackChapters: true, aiAvailable: true
            ),
            .transcribe
        )
        XCTAssertEqual(
            PlayerChapterRowPolicy.generationAction(
                availability: availability, hasPlaybackChapters: false, aiAvailable: true
            ),
            .transcribeAndGenerateChapters
        )
        XCTAssertNil(
            PlayerChapterRowPolicy.generationAction(
                availability: availability, hasPlaybackChapters: false, aiAvailable: false
            )
        )
    }
}
