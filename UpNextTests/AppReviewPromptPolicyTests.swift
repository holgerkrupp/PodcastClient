import XCTest
import SwiftData
@testable import UpNext

final class AppReviewPromptPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRequiresStrictlyMoreThanOneHundredHours() {
        XCTAssertFalse(shouldRequest(
            listeningSeconds: AppReviewPromptPolicy.minimumListeningSeconds
        ))
        XCTAssertTrue(shouldRequest(
            listeningSeconds: AppReviewPromptPolicy.minimumListeningSeconds + 0.001
        ))
    }

    func testRequiresFortySecondsInTheForeground() {
        XCTAssertFalse(shouldRequest(foregroundDuration: 39.999))
        XCTAssertTrue(shouldRequest(
            foregroundDuration: AppReviewPromptPolicy.minimumForegroundDuration
        ))
    }

    func testRequiresAnActiveSceneWithoutAnotherPresentation() {
        XCTAssertFalse(shouldRequest(isSceneActive: false))
        XCTAssertFalse(shouldRequest(hasBlockingPresentation: true))
        XCTAssertTrue(shouldRequest())
    }

    func testDoesNotRequestTwiceForTheSameVersion() {
        XCTAssertFalse(shouldRequest(
            state: AppReviewPromptState(
                lastRequestedVersion: "2026.19",
                lastRequestedAt: now.addingTimeInterval(-AppReviewPromptPolicy.requestCooldown)
            )
        ))
    }

    func testNewVersionStillRespectsCooldown() {
        XCTAssertFalse(shouldRequest(
            state: AppReviewPromptState(
                lastRequestedVersion: "2026.18",
                lastRequestedAt: now.addingTimeInterval(-AppReviewPromptPolicy.requestCooldown + 1)
            )
        ))
        XCTAssertTrue(shouldRequest(
            state: AppReviewPromptState(
                lastRequestedVersion: "2026.18",
                lastRequestedAt: now.addingTimeInterval(-AppReviewPromptPolicy.requestCooldown)
            )
        ))
    }

    func testStorePersistsTheAttempt() throws {
        let suiteName = "AppReviewPromptPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppReviewPromptStore(defaults: defaults)

        store.recordRequest(version: "2026.19", at: now)

        XCTAssertEqual(
            store.state,
            AppReviewPromptState(
                lastRequestedVersion: "2026.19",
                lastRequestedAt: now
            )
        )
    }

    @MainActor
    func testLifetimeLoaderUsesBaselinePlusLiveHistoryWithoutDoubleCountingMigration() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let feed = "https://example.com/feed.xml"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        legacy.mainContext.insert(PlaySessionSummary(
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: startedAt,
            podcastFeed: URL(string: feed),
            totalSeconds: 365_000
        ))
        try legacy.mainContext.save()

        userState.mainContext.insert(ListeningBaselineSync(
            feedURL: feed,
            totalSeconds: 300_000
        ))
        userState.mainContext.insert(ListeningHistorySync(
            id: "migrated",
            feedURL: feed,
            episodeID: "old-episode",
            sourceDeviceID: "legacy",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(100_000),
            listenedSeconds: 100_000,
            isLegacyMigrated: true
        ))
        userState.mainContext.insert(ListeningHistorySync(
            id: "live",
            feedURL: feed,
            episodeID: "new-episode",
            sourceDeviceID: "phone",
            startedAt: startedAt.addingTimeInterval(200_000),
            endedAt: startedAt.addingTimeInterval(270_000),
            listenedSeconds: 70_000
        ))
        try userState.mainContext.save()

        let loader = AppReviewLifetimeListeningLoader(
            legacyContainer: legacy,
            userStateContainer: userState,
            useSyncedStore: true
        )

        let totalSeconds = await loader.totalSeconds()
        XCTAssertEqual(totalSeconds, 370_000)
    }

    private func shouldRequest(
        listeningSeconds: TimeInterval = AppReviewPromptPolicy.minimumListeningSeconds + 1,
        foregroundDuration: TimeInterval = AppReviewPromptPolicy.minimumForegroundDuration,
        isSceneActive: Bool = true,
        hasBlockingPresentation: Bool = false,
        currentVersion: String = "2026.19",
        state: AppReviewPromptState = AppReviewPromptState(),
        now: Date? = nil
    ) -> Bool {
        AppReviewPromptPolicy.shouldRequestReview(
            listeningSeconds: listeningSeconds,
            foregroundDuration: foregroundDuration,
            isSceneActive: isSceneActive,
            hasBlockingPresentation: hasBlockingPresentation,
            currentVersion: currentVersion,
            state: state,
            now: now ?? self.now
        )
    }
}
