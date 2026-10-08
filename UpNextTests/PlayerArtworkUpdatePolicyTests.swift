import XCTest
@testable import UpNext

final class PlayerArtworkUpdatePolicyTests: XCTestCase {
    func testChapterChangeWithoutChapterArtworkKeepsSameEpisodeCover() {
        let episodeCover = PlayerArtworkIdentity.url("https://example.com/episode.jpg", profileID: nil)

        XCTAssertFalse(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: episodeCover,
            currentIdentity: episodeCover,
            hasImage: true
        ))
    }

    func testDifferentChapterArtworkIsApplied() {
        let first = PlayerArtworkIdentity.url("https://example.com/chapter-1.jpg", profileID: nil)
        let second = PlayerArtworkIdentity.url("https://example.com/chapter-2.jpg", profileID: nil)

        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: second,
            currentIdentity: first,
            hasImage: true
        ))
    }

    func testChapterArtworkToEpisodeFallbackUpdatesWithoutClearingFirst() {
        let chapter = PlayerArtworkIdentity.url("https://example.com/chapter.jpg", profileID: nil)
        let episode = PlayerArtworkIdentity.url("https://example.com/episode.jpg", profileID: nil)

        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: episode,
            currentIdentity: chapter,
            hasImage: true
        ))
    }

    func testEpisodeSwitchAppliesDifferentArtwork() {
        let oldEpisode = PlayerArtworkIdentity.url("https://example.com/old.jpg", profileID: nil)
        let newEpisode = PlayerArtworkIdentity.url("https://example.com/new.jpg", profileID: nil)

        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: newEpisode,
            currentIdentity: oldEpisode,
            hasImage: true
        ))
    }

    func testMissingArtworkClearsOnlyAfterLookupFinishes() {
        let existing = PlayerArtworkIdentity.url("https://example.com/old.jpg", profileID: nil)

        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: nil,
            currentIdentity: existing,
            hasImage: false
        ))
        XCTAssertFalse(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: nil,
            currentIdentity: nil,
            hasImage: false
        ))
    }

    func testIdenticalURLInDifferentCredentialProfilesIsDifferentArtworkSource() {
        let publicSource = PlayerArtworkIdentity.url("https://example.com/cover.jpg", profileID: nil)
        let privateSource = PlayerArtworkIdentity.url("https://example.com/cover.jpg", profileID: "private-feed")

        XCTAssertTrue(PlayerArtworkUpdatePolicy.shouldApply(
            resolvedIdentity: privateSource,
            currentIdentity: publicSource,
            hasImage: true
        ))
    }
}
