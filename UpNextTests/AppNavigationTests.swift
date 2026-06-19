import XCTest
@testable import UpNext

final class AppNavigationTests: XCTestCase {
    func testSectionMetadataIsStableAndComplete() {
        XCTAssertEqual(
            AppSection.allCases,
            [.queue, .inbox, .library, .search, .downloads, .bookmarks, .history]
        )
        XCTAssertEqual(AppSection.compactSections, [.queue, .inbox, .library, .search])
        XCTAssertEqual(AppSection.search.sidebarTitle, "Search")
        XCTAssertEqual(AppSection.history.symbolName, "waveform")
    }

    @MainActor
    func testRestoresKnownSelectionAndFallsBackForUnknownSelection() {
        XCTAssertEqual(AppNavigationModel.restoredSection(from: "bookmarks"), .bookmarks)
        XCTAssertEqual(AppNavigationModel.restoredSection(from: "removed-section"), .queue)
        XCTAssertEqual(AppNavigationModel.restoredSection(from: nil), .queue)
    }

    @MainActor
    func testOpeningPlaylistEpisodeSelectsQueueAndStoresRequest() {
        let navigation = AppNavigationModel(selectedSection: .library)
        let episodeURL = URL(string: "https://example.com/episode.mp3")!

        navigation.openPlaylistEpisode(episodeURL)

        XCTAssertEqual(navigation.selectedSection, .queue)
        XCTAssertEqual(navigation.requestedPlaylistEpisodeURL, episodeURL)
    }

    @MainActor
    func testParsesWidgetEpisodeLinkWithPlaylist() throws {
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let playlistID = UUID()
        var components = URLComponents(string: "upnext://episode")!
        components.queryItems = [
            URLQueryItem(name: "url", value: episodeURL.absoluteString),
            URLQueryItem(name: "playlistID", value: playlistID.uuidString)
        ]
        let url = try XCTUnwrap(components.url)

        XCTAssertEqual(
            AppLink.parse(url),
            .showEpisode(episodeURL, playlistID: playlistID.uuidString)
        )
    }

    @MainActor
    func testParsesPlaybackAndQueueLinks() {
        let episodeURL = URL(string: "https://example.com/audio.mp3")!
        let playbackURL = URL(
            string: "upnext://playEpisode?url=\(episodeURL.absoluteString)"
        )!

        XCTAssertEqual(AppLink.parse(playbackURL), .playEpisode(episodeURL))
        XCTAssertEqual(
            AppLink.parse(URL(string: "upnext://queue")!),
            .selectQueue(playlistID: nil)
        )
    }

    @MainActor
    func testOpenPlayerActionInvokesPresentationHandler() {
        var invocationCount = 0
        let action = OpenPlayerAction {
            invocationCount += 1
        }

        action()

        XCTAssertEqual(invocationCount, 1)
    }
}
