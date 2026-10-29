import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitUserStateImportSafetyTests: XCTestCase {
    @MainActor
    func testOversizedTimestampBoundaryDoesNotProducePartialImportSnapshot() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let timestamp = Date(timeIntervalSince1970: 1234)
        for index in 0..<501 {
            userState.mainContext.insert(EpisodeStateSync(
                feedURL: "https://example.com/feed.xml",
                episodeID: "episode-\(index)",
                updatedAt: timestamp
            ))
        }
        try userState.mainContext.save()
        XCTAssertThrowsError(try ModelContainerManager.shared.latestUserStateChangeStamps(userState))
    }

    func testCommitOfCapturedSnapshotLeavesLaterImportEligible() throws {
        let suite = "StoreSplitUserStateImportSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let captured: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] = [
            .episodeState: .init(date: Date(timeIntervalSince1970: 100), recordIDsAtTimestamp: ["first"])
        ]
        let later: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] = [
            .episodeState: .init(date: Date(timeIntervalSince1970: 200), recordIDsAtTimestamp: ["later"])
        ]
        StoreSplitImportCursorStore.commit(captured, streams: [.episodeState], defaults: defaults)
        XCTAssertEqual(
            StoreSplitImportCursorStore.changedStreams(current: later, force: false, defaults: defaults),
            [.episodeState]
        )
    }

    @MainActor
    func testPreferenceOnlyImportBuildsPodcastIndex() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/preferences.xml")!
        runtime.mainContext.insert(Podcast(feed: feed))
        try runtime.mainContext.save()
        userState.mainContext.insert(PodcastPreferenceSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed), autoDownload: true
        ))
        try userState.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime, userStateContainer: userState,
            projectListeningHistoryToLegacy: false, changedStreams: [.preferences]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.feedsToBootstrap.isEmpty)
        let podcast = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.settings?.autoDownload, true)
    }
}
