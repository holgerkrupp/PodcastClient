import XCTest
@testable import UpNext

/// #520: the player shell derives its button state from prepared values only.
final class PlayerPresentationSnapshotTests: XCTestCase {
    private let episodeURL = URL(string: "https://example.com/episode.mp3")!
    private let otherURL = URL(string: "https://example.com/other.mp3")!
    private let localFile = URL(fileURLWithPath: "/tmp/caches/abc_episode.mp3")

    private func availability(
        for url: URL,
        hasTranscript: Bool = false,
        hasChapterSelectionUI: Bool = false,
        hasSavedLiveTranscript: Bool = false
    ) -> PlayerContentAvailability {
        PlayerContentAvailability(
            episodeURL: url,
            hasTranscript: hasTranscript,
            hasChapterSelectionUI: hasChapterSelectionUI,
            hasUsableChapters: hasChapterSelectionUI,
            hasSavedLiveTranscript: hasSavedLiveTranscript
        )
    }

    func testLocalMediaComesFromDownloadInventory() {
        XCTAssertTrue(PlayerPresentationSnapshot.hasLocalMedia(
            isSideLoaded: false, localFile: localFile, downloadedFiles: [localFile.standardizedFileURL]
        ))
        XCTAssertFalse(PlayerPresentationSnapshot.hasLocalMedia(
            isSideLoaded: false, localFile: localFile, downloadedFiles: []
        ))
        XCTAssertFalse(PlayerPresentationSnapshot.hasLocalMedia(
            isSideLoaded: false, localFile: nil, downloadedFiles: [localFile]
        ))
    }

    func testSideLoadedFileCountsAsLocalMedia() {
        XCTAssertTrue(PlayerPresentationSnapshot.hasLocalMedia(
            isSideLoaded: true, localFile: localFile, downloadedFiles: []
        ))
        XCTAssertFalse(PlayerPresentationSnapshot.hasLocalMedia(
            isSideLoaded: true, localFile: episodeURL, downloadedFiles: []
        ))
    }

    func testUnknownOrStaleAvailabilityIsNotATranscript() {
        XCTAssertFalse(PlayerPresentationSnapshot.availabilityHasTranscript(nil, episodeURL: episodeURL))
        XCTAssertFalse(PlayerPresentationSnapshot.availabilityHasTranscript(
            availability(for: otherURL, hasTranscript: true), episodeURL: episodeURL
        ))
        XCTAssertTrue(PlayerPresentationSnapshot.availabilityHasTranscript(
            availability(for: episodeURL, hasTranscript: true), episodeURL: episodeURL
        ))
        XCTAssertTrue(PlayerPresentationSnapshot.availabilityHasTranscript(
            availability(for: episodeURL, hasSavedLiveTranscript: true), episodeURL: episodeURL
        ))
    }

    func testTranscriptToggleShowsForTranscriptLiveSessionOrLocalFile() {
        func snapshot(
            availability: PlayerContentAvailability? = nil,
            downloaded: Set<URL> = [],
            live: Bool = false
        ) -> PlayerPresentationSnapshot {
            PlayerPresentationSnapshot.make(
                episodeURL: episodeURL,
                isSideLoaded: false,
                localFile: localFile,
                downloadedFiles: downloaded,
                availability: availability,
                isLiveTranscriptActive: live
            )
        }

        XCTAssertFalse(snapshot().showsTranscriptToggle)
        XCTAssertTrue(snapshot(live: true).showsTranscriptToggle)
        XCTAssertTrue(snapshot(downloaded: [localFile]).showsTranscriptToggle)
        XCTAssertTrue(snapshot(availability: availability(for: episodeURL, hasTranscript: true)).showsTranscriptToggle)
        XCTAssertFalse(snapshot(availability: availability(for: otherURL, hasTranscript: true)).showsTranscriptToggle)
    }

    func testChapterSelectionUsesSnapshotOrPlaybackChaptersOnly() {
        XCTAssertFalse(PlayerChapterRowPolicy.hasChapterSelectionUI(
            availability: nil, episodeURL: episodeURL, hasPlaybackChapters: false
        ))
        XCTAssertTrue(PlayerChapterRowPolicy.hasChapterSelectionUI(
            availability: nil, episodeURL: episodeURL, hasPlaybackChapters: true
        ))
        XCTAssertTrue(PlayerChapterRowPolicy.hasChapterSelectionUI(
            availability: availability(for: episodeURL, hasChapterSelectionUI: true),
            episodeURL: episodeURL,
            hasPlaybackChapters: false
        ))
        XCTAssertFalse(PlayerChapterRowPolicy.hasChapterSelectionUI(
            availability: availability(for: otherURL, hasChapterSelectionUI: true),
            episodeURL: episodeURL,
            hasPlaybackChapters: false
        ))
    }

    func testReferenceNotificationsInvalidateOnlyTheMatchingEpisode() {
        XCTAssertTrue(PlayerReferenceNotificationPolicy.matches(changedURL: episodeURL, episodeURL: episodeURL))
        XCTAssertFalse(PlayerReferenceNotificationPolicy.matches(changedURL: otherURL, episodeURL: episodeURL))
        // Broad notifications without a URL still apply.
        XCTAssertTrue(PlayerReferenceNotificationPolicy.matches(changedURL: nil, episodeURL: episodeURL))
    }
}
