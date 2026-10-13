import AVFoundation
import XCTest
@testable import UpNext

final class PlaybackStateReconciliationPolicyTests: XCTestCase {
    private func shouldMarkPaused(
        status: AVPlayer.TimeControlStatus,
        rate: Float = 0,
        isPlaying: Bool = true,
        hasCurrentItem: Bool = true,
        isActivatingPlayback: Bool = false,
        isForeground: Bool = true
    ) -> Bool {
        PlaybackStateReconciliationPolicy.shouldMarkPaused(
            status: status,
            rate: rate,
            isPlaying: isPlaying,
            hasCurrentItem: hasCurrentItem,
            isActivatingPlayback: isActivatingPlayback,
            isForeground: isForeground
        )
    }

    func testSystemPausedPlaybackIsReflectedInForeground() {
        XCTAssertTrue(shouldMarkPaused(status: .paused))
    }

    func testDoNotPauseUIWhileActuallyPlaying() {
        XCTAssertFalse(shouldMarkPaused(status: .playing, rate: 1.5))
    }

    func testDoNotTreatBufferingAsPaused() {
        XCTAssertFalse(shouldMarkPaused(status: .waitingToPlayAtSpecifiedRate))
        XCTAssertFalse(shouldMarkPaused(status: .waitingToPlayAtSpecifiedRate, rate: 1.5))
    }

    func testDoNotCancelPendingAudioSessionActivation() {
        XCTAssertFalse(shouldMarkPaused(status: .paused, isActivatingPlayback: true))
    }

    func testDoNotInferPauseWhileBackgrounded() {
        // Delayed AVAudioSession notifications can still authorize a resume.
        XCTAssertFalse(shouldMarkPaused(status: .paused, isForeground: false))
    }

    func testDoNotTreatMissingItemOrAlreadyPausedPlayerAsUnexpectedPause() {
        XCTAssertFalse(shouldMarkPaused(status: .paused, hasCurrentItem: false))
        XCTAssertFalse(shouldMarkPaused(status: .paused, isPlaying: false))
    }
}
