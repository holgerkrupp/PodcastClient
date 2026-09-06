import XCTest
@testable import UpNext

final class PlaybackTrimPolicyTests: XCTestCase {
    func testNewEpisodeStartsAfterConfiguredIntro() {
        XCTAssertEqual(
            PlaybackTrimPolicy.initialPosition(
                resumePosition: 0,
                introSkipSeconds: 45,
                duration: 1_800
            ),
            45
        )
    }

    func testResumePositionBeyondIntroIsPreserved() {
        XCTAssertEqual(
            PlaybackTrimPolicy.initialPosition(
                resumePosition: 300,
                introSkipSeconds: 45,
                duration: 1_800
            ),
            300
        )
    }

    func testIntroSkipCannotSeekBeyondEpisodeDuration() {
        XCTAssertEqual(
            PlaybackTrimPolicy.initialPosition(
                resumePosition: 0,
                introSkipSeconds: 120,
                duration: 60
            ),
            60
        )
    }

    func testOutroBoundaryIsMeasuredBackFromEpisodeEnd() {
        XCTAssertEqual(
            PlaybackTrimPolicy.outroBoundary(
                duration: 1_800,
                outroSkipSeconds: 90
            ),
            1_710
        )
        XCTAssertFalse(
            PlaybackTrimPolicy.hasReachedOutro(
                position: 1_709.9,
                duration: 1_800,
                outroSkipSeconds: 90
            )
        )
        XCTAssertTrue(
            PlaybackTrimPolicy.hasReachedOutro(
                position: 1_710,
                duration: 1_800,
                outroSkipSeconds: 90
            )
        )
    }

    func testZeroAndInvalidSkipsAreDisabled() {
        XCTAssertNil(
            PlaybackTrimPolicy.outroBoundary(
                duration: 1_800,
                outroSkipSeconds: 0
            )
        )
        XCTAssertEqual(
            PlaybackTrimPolicy.initialPosition(
                resumePosition: 0,
                introSkipSeconds: .nan,
                duration: 1_800
            ),
            0
        )
    }

    func testPodcastSettingsDefaultBothSkipsToZero() {
        let settings = PodcastSettings()

        XCTAssertEqual(settings.cutFront, 0)
        XCTAssertEqual(settings.cutEnd, 0)
    }
}
