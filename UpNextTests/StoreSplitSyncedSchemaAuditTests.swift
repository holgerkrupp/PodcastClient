import SwiftData
import XCTest
@testable import UpNext

/// The synced store exists to be small. The allow-list only constrains which
/// models may live in it, so these tests cover the two properties it does not:
/// that it still matches the container, and how the rows grow.
final class StoreSplitSyncedSchemaAuditTests: XCTestCase {
    /// The allow-list and the container schema are written independently, so only
    /// comparing them keeps the allow-list from being documentation.
    @MainActor
    func testSyncedSchemaMatchesTheAuditAllowList() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        XCTAssertEqual(
            UserStateCloudSchemaAudit.unlistedModelNames(in: userState.schema), [],
            "a model reached the CloudKit-backed store without being added to the allow-list"
        )
        XCTAssertEqual(
            UserStateCloudSchemaAudit.absentModelNames(in: userState.schema), []
        )
        XCTAssertFalse(UserStateCloudSchemaAudit.containsFeedDerivedData)
    }

    func testEverySyncedEntityDeclaresHowItGrows() {
        XCTAssertEqual(
            Set(UserStateCloudSchemaAudit.rowGrowthBySyncedModel.keys),
            UserStateCloudSchemaAudit.allowedModelNames
        )
    }

    /// The derived aggregate is the largest table in the store the split exists to
    /// keep small. Pinning the arithmetic keeps that from being an opinion.
    func testDerivedSummariesDominateTheSyncedPayload() {
        let summaries = UserStateCloudSchemaAudit.estimatedListeningSummaryRowCount(
            feeds: 40,
            distinctListeningDays: 5 * 365,
            devices: 2
        )
        // Every other entity for the same library, generously counted: one state
        // row per episode of every feed for five years, plus queue, playlists,
        // bookmarks, preferences and subscriptions.
        let episodeStates = 40 * 5 * 52
        XCTAssertGreaterThan(summaries, episodeStates)
    }

    func testFeedDerivedFieldInventoryIsScopedToSyncedModels() {
        for name in UserStateCloudSchemaAudit.feedDerivedFieldsBySyncedModel.keys {
            XCTAssertTrue(UserStateCloudSchemaAudit.allowedModelNames.contains(name))
        }
        XCTAssertEqual(
            UserStateCloudSchemaAudit.feedDerivedFieldsBySyncedModel["EpisodeStateSync"],
            ["duration"]
        )
    }
}
