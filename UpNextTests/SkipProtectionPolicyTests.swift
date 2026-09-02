import XCTest
@testable import UpNext

final class SkipProtectionPolicyTests: XCTestCase {
    private let firstEpisode = URL(string: "https://example.com/episodes/one.mp3")!
    private let secondEpisode = URL(string: "https://example.com/episodes/two.mp3")!

    func testSmallSeekDoesNotOfferUndo() {
        XCTAssertFalse(
            SkipProtectionPolicy.shouldOfferUndo(
                from: firstEpisode,
                position: 600,
                to: firstEpisode,
                position: 689
            )
        )
    }

    func testSignificantForwardAndBackwardSeeksOfferUndo() {
        XCTAssertTrue(
            SkipProtectionPolicy.shouldOfferUndo(
                from: firstEpisode,
                position: 600,
                to: firstEpisode,
                position: 690
            )
        )
        XCTAssertTrue(
            SkipProtectionPolicy.shouldOfferUndo(
                from: firstEpisode,
                position: 600,
                to: firstEpisode,
                position: 510
            )
        )
    }

    func testEpisodeChangeAlwaysOffersUndo() {
        XCTAssertTrue(
            SkipProtectionPolicy.shouldOfferUndo(
                from: firstEpisode,
                position: 30,
                to: secondEpisode,
                position: 30
            )
        )
    }
}
