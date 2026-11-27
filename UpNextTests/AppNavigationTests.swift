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
    func testParsesSpotlightPodcastLinkToLocalPodcastRoute() throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        var components = URLComponents(string: "upnext://podcast")!
        components.queryItems = [URLQueryItem(name: "feed", value: feedURL.absoluteString)]
        XCTAssertEqual(AppLink.parse(try XCTUnwrap(components.url)), .showPodcast(feedURL))
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

    func testAdaptiveAppLayoutUsesGeometryForShellAndPlayerPresentation() {
        let compact = AdaptiveAppLayout.resolve(
            width: 390,
            horizontalSizeClass: .compact,
            isDesktop: false
        )
        XCTAssertEqual(compact.navigationStyle, .compactTabs)
        XCTAssertEqual(compact.playerPresentation, .sheet)

        let duoInner = AdaptiveAppLayout.resolve(
            width: 626,
            horizontalSizeClass: .regular,
            isDesktop: false
        )
        XCTAssertEqual(duoInner.navigationStyle, .sidebar)
        XCTAssertEqual(duoInner.playerPresentation, .contextPanel)
        XCTAssertEqual(duoInner.playerPanelFraction, 0.6)

        let iPad = AdaptiveAppLayout.resolve(
            width: 1024,
            horizontalSizeClass: .regular,
            isDesktop: false
        )
        XCTAssertEqual(iPad.navigationStyle, .sidebar)
        XCTAssertEqual(iPad.playerPresentation, .contextPanel)
        XCTAssertEqual(iPad.playerPanelFraction, 0.5)
    }

    func testNarrowRegularWindowFallsBackToFullPlayerSheet() {
        let layout = AdaptiveAppLayout.resolve(
            width: 540,
            horizontalSizeClass: .regular,
            isDesktop: false
        )

        XCTAssertEqual(layout.navigationStyle, .sidebar)
        XCTAssertEqual(layout.playerPresentation, .sheet)
    }

    func testPlayerLayoutSwitchesArrangementWithoutUsingDeviceType() {
        XCTAssertEqual(
            PlayerLayoutPolicy.mode(
                fullSize: true,
                size: CGSize(width: 390, height: 844),
                horizontalSizeClass: .compact,
                requestedExpandedLayout: nil,
                isPhone: false
            ),
            .compactFull
        )
        XCTAssertEqual(
            PlayerLayoutPolicy.mode(
                fullSize: true,
                size: CGSize(width: 890, height: 626),
                horizontalSizeClass: .regular,
                requestedExpandedLayout: nil,
                isPhone: false
            ),
            .expandedHorizontal
        )
        XCTAssertEqual(
            PlayerLayoutPolicy.mode(
                fullSize: true,
                size: CGSize(width: 626, height: 890),
                horizontalSizeClass: .regular,
                requestedExpandedLayout: nil,
                isPhone: false
            ),
            .expandedVertical
        )
    }

    func testEveryPhoneLayoutKeepsTheCoverHeroPlayer() {
        // Closed Duo, unfolded Duo (also as a requested context panel), wide
        // landscape iPhone: the player model stays the same; only size adapts.
        let sizes = [
            CGSize(width: 466, height: 678),
            CGSize(width: 517, height: 669),
            CGSize(width: 951, height: 669),
            CGSize(width: 932, height: 430)
        ]
        for size in sizes {
            for requested in [nil, true, false] as [Bool?] {
                XCTAssertEqual(
                    PlayerLayoutPolicy.mode(
                        fullSize: true,
                        size: size,
                        horizontalSizeClass: .regular,
                        requestedExpandedLayout: requested,
                        isPhone: true
                    ),
                    .compactFull,
                    "\(size) requested=\(String(describing: requested))"
                )
            }
        }
        XCTAssertEqual(
            PlayerLayoutPolicy.mode(
                fullSize: false,
                size: CGSize(width: 951, height: 669),
                horizontalSizeClass: .regular,
                requestedExpandedLayout: true,
                isPhone: true
            ),
            .compact,
            "the mini player is unaffected"
        )
    }

    @MainActor
    func testNavigationAndPlayerPresentationStateAreIndependentOfLayout() {
        let navigation = AppNavigationModel(selectedSection: .library)
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        navigation.pathBinding(for: .library).wrappedValue.append(AppRoute.episode(episodeURL))
        navigation.isPlayerPresented = true

        let compact = AdaptiveAppLayout.resolve(
            width: 390,
            horizontalSizeClass: .compact,
            isDesktop: false
        )
        let wide = AdaptiveAppLayout.resolve(
            width: 626,
            horizontalSizeClass: .regular,
            isDesktop: false
        )

        XCTAssertNotEqual(compact.playerPresentation, wide.playerPresentation)
        XCTAssertEqual(navigation.selectedSection, .library)
        XCTAssertEqual(navigation.pathBinding(for: .library).wrappedValue.count, 1)
        XCTAssertTrue(navigation.isPlayerPresented)
    }
}
