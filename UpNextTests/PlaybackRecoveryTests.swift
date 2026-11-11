import XCTest
import AVFoundation
@testable import UpNext

final class PlaybackRecoveryCoordinatorTests: XCTestCase {
    func testRepeatedActivationFailureCanStartOneRecoveryPerSettledAttempt() {
        var coordinator = PlaybackRecoveryCoordinator()

        XCTAssertEqual(coordinator.begin(), 1)
        XCTAssertNil(coordinator.begin())
        coordinator.finish()
        XCTAssertEqual(coordinator.begin(), 2)
    }

    func testMediaServicesResetRequestCoalescesWithActivationRecovery() {
        var coordinator = PlaybackRecoveryCoordinator()

        XCTAssertEqual(coordinator.begin(), 1)
        // The recovery gate is reason-independent, so a reset arriving during
        // activation recovery cannot launch a second player rebuild.
        XCTAssertNil(coordinator.begin())
        XCTAssertEqual(coordinator.attemptNumber, 1)
        coordinator.finish()
    }

    func testNearSimultaneousRequestsStartOnlyOneRecovery() {
        var coordinator = PlaybackRecoveryCoordinator()

        let requests = (0..<2).map { _ in coordinator.begin() }

        XCTAssertEqual(requests.compactMap { $0 }, [1])
        XCTAssertTrue(coordinator.isRecovering)
    }

    func testRecoveryIdentityRejectsEpisodeOrGenerationChange() {
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        let player = AVPlayer(playerItem: item)
        let identity = PlaybackRecoveryIdentity(
            generation: 4,
            episodeURL: episodeURL,
            itemID: ObjectIdentifier(item),
            playerID: ObjectIdentifier(player)
        )

        XCTAssertTrue(identity.matches(generation: 4, episodeURL: episodeURL, item: item, player: player))
        XCTAssertFalse(identity.matches(
            generation: 5,
            episodeURL: episodeURL,
            item: item,
            player: player
        ))
        XCTAssertFalse(identity.matches(
            generation: 4,
            episodeURL: URL(string: "https://example.com/new-episode.mp3"),
            item: item,
            player: player
        ))
    }

    func testRecoveryKeepsCachedPositionWhenResetEngineReportsZero() {
        XCTAssertEqual(
            PlaybackRecoveryPositionPolicy.preservedPosition(enginePosition: 0, savedPosition: 42),
            42
        )
        XCTAssertEqual(
            PlaybackRecoveryPositionPolicy.preservedPosition(enginePosition: .nan, savedPosition: 42),
            42
        )
    }
}

@MainActor
final class PlayerEngineRecoveryTests: XCTestCase {
    func testRebuildInstallsNewItemAndDetachesOldPlayerItem() async {
        let engine = PlayerEngine()
        let oldItem = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        engine.replaceCurrentItem(with: oldItem)
        let oldPlayer = engine.avPlayer
        let replacementItem = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))

        let recovered = await engine.rebuildPlayer(with: replacementItem, at: 0)

        XCTAssertTrue(recovered)
        XCTAssertNil(oldPlayer.currentItem)
        XCTAssertTrue(engine.avPlayer.currentItem === replacementItem)
        XCTAssertFalse(engine.avPlayer.currentItem === oldItem)
    }

    func testMediaServicesResetIsForwardedToRecoveryHandler() async {
        let engine = PlayerEngine()
        let didReceiveReset = expectation(description: "media services reset forwarded")
        engine.setInterruptionHandler { event in
            if case .mediaServicesReset = event {
                didReceiveReset.fulfill()
            }
        }
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )

        await fulfillment(of: [didReceiveReset], timeout: 1)
    }
}
