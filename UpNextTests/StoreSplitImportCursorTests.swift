import XCTest
@testable import UpNext

final class StoreSplitImportCursorTests: XCTestCase {
    func testUnresolvedPlaylistEpisodeKeepsMembershipStreamsPending() {
        let changed: Set<StoreSplitUserStateStream> = [
            .subscriptions,
            .playlistEntries,
            .queueEntries,
            .bookmarks
        ]

        let eligible = StoreSplitImportCursorStore.streamsEligibleForCommit(
            changedStreams: changed,
            hasUnresolvedPlaylistEpisodes: true
        )

        XCTAssertEqual(eligible, [.subscriptions, .bookmarks])
    }

    func testResolvedPlaylistEpisodesAllowMembershipStreamsToCommit() {
        let changed: Set<StoreSplitUserStateStream> = [.playlistEntries, .queueEntries]

        let eligible = StoreSplitImportCursorStore.streamsEligibleForCommit(
            changedStreams: changed,
            hasUnresolvedPlaylistEpisodes: false
        )

        XCTAssertEqual(eligible, changed)
    }
}
