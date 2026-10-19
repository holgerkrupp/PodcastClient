import XCTest
@testable import UpNext

final class PodcastCustomSettingsInheritanceTests: XCTestCase {
    func testCustomSettingsStartWithAllPerPodcastGlobalPreferences() throws {
        let podcast = Podcast(feed: try XCTUnwrap(URL(string: "https://example.com/feed.xml")))
        let global = PodcastSettings()
        global.playbackSpeed = 1.4
        global.reduceSilenceGapsEnabled = true
        global.silenceGapReductionLevel = .high
        global.voiceEnhancementEnabled = true
        global.cutFront = 12
        global.cutEnd = 18
        global.skipForward = .fortyfive
        global.skipBack = .thirty
        global.skipForwardBehavior = .chapter
        global.skipBackBehavior = .chapter
        global.playnextPosition = .front
        global.autoSkipKeywords = [.init(keyWord: "Intro", keyOperator: .Contains)]
        global.autoDownload = true
        global.autoDownloadEpisodeCount = 9
        global.autoDownloadSelection = .oldestUnplayed
        global.autoDownloadNetworkMode = .wifiOnly
        global.autoDownloadIncludesArchivedEpisodes = false
        global.autoDownloadFilterJSON = "{\"duration\":{\"maximum\":3600}}"
        global.defaultPlaylistID = UUID()
        global.archiveFileRetentionDays = 23
        global.enableLiveItemNotifications = false

        let settings = PodcastSettings.makeCustomSettings(for: podcast, inheriting: global)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.playbackSpeed == global.playbackSpeed)
        XCTAssertEqual(settings.reduceSilenceGapsEnabled, global.reduceSilenceGapsEnabled)
        XCTAssertEqual(settings.silenceGapReductionLevel, global.silenceGapReductionLevel)
        XCTAssertEqual(settings.voiceEnhancementEnabled, global.voiceEnhancementEnabled)
        XCTAssertEqual(settings.cutFront, global.cutFront)
        XCTAssertEqual(settings.cutEnd, global.cutEnd)
        XCTAssertEqual(settings.skipForward, global.skipForward)
        XCTAssertEqual(settings.skipBack, global.skipBack)
        XCTAssertEqual(settings.skipForwardBehavior, global.skipForwardBehavior)
        XCTAssertEqual(settings.skipBackBehavior, global.skipBackBehavior)
        XCTAssertEqual(settings.playnextPosition, global.playnextPosition)
        XCTAssertEqual(settings.autoSkipKeywords.first?.keyWord, global.autoSkipKeywords.first?.keyWord)
        XCTAssertEqual(settings.autoSkipKeywords.first?.keyOperator, global.autoSkipKeywords.first?.keyOperator)
        XCTAssertEqual(settings.autoDownload, global.autoDownload)
        XCTAssertEqual(settings.autoDownloadEpisodeCount, global.autoDownloadEpisodeCount)
        XCTAssertEqual(settings.autoDownloadSelection, global.autoDownloadSelection)
        XCTAssertEqual(settings.autoDownloadNetworkMode, global.autoDownloadNetworkMode)
        XCTAssertEqual(settings.autoDownloadIncludesArchivedEpisodes, global.autoDownloadIncludesArchivedEpisodes)
        XCTAssertEqual(settings.autoDownloadFilterJSON, global.autoDownloadFilterJSON)
        XCTAssertEqual(settings.defaultPlaylistID, global.defaultPlaylistID)
        XCTAssertEqual(settings.archiveFileRetentionDays, global.archiveFileRetentionDays)
        XCTAssertEqual(settings.enableLiveItemNotifications, global.enableLiveItemNotifications)
        XCTAssertTrue(settings.podcast === podcast)
    }
}
