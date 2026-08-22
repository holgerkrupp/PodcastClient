import SwiftData
import XCTest
@testable import UpNext

/// The synced store exists to be small and to hold nothing that can disagree
/// with itself. The allow-list only constrains which models may live in it, so
/// these tests cover what it does not: that it still matches the container, that
/// nothing aggregate-shaped comes back, and how the rows actually grow.
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

    /// `ListeningSummarySync` was a per-feed, per-period, per-device rollup of
    /// data the store already held as sessions. It was the largest table in the
    /// store, and being derived from rows that also synced is what made every
    /// total reconcilable against itself. It does not come back.
    @MainActor
    func testRetiredAggregatesAreNotBackInTheSyncedSchema() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        XCTAssertEqual(
            UserStateCloudSchemaAudit.reintroducedRetiredModelNames(in: userState.schema), [],
            "a retired aggregate is back in the synced schema"
        )
        XCTAssertTrue(
            UserStateCloudSchemaAudit.retiredModelNames.contains("ListeningSummarySync")
        )
    }

    func testEverySyncedEntityDeclaresHowItGrows() {
        XCTAssertEqual(
            Set(UserStateCloudSchemaAudit.rowGrowthBySyncedModel.keys),
            UserStateCloudSchemaAudit.allowedModelNames
        )
    }

    /// The constraint that would have caught `ListeningSummarySync` on the way
    /// in: nothing in the synced store may multiply along more than one axis.
    func testNoSyncedEntityGrowsMultiplicatively() {
        for (name, growth) in UserStateCloudSchemaAudit.rowGrowthBySyncedModel {
            XCTAssertTrue(
                UserStateCloudSchemaAudit.permitsAggregateGrowth(growth),
                "\(name) grows as \(growth.rawValue), which is the shape the synced store must not carry"
            )
        }
    }

    /// The measurement that justified retiring the aggregate, kept so the next
    /// proposal has to argue against a number.
    func testRetiringTheAggregateIsMostOfThePayload() {
        let feeds = 40
        let days = 5 * 365
        let devices = 2
        let aggregate = UserStateCloudSchemaAudit.estimatedAggregateRowCount(
            feeds: feeds,
            distinctListeningDays: days,
            devices: devices
        )
        let synced = UserStateCloudSchemaAudit.estimatedSyncedRowCount(
            feeds: feeds,
            distinctListeningDays: days,
            devices: devices,
            sessionsPerDayPerDevice: 3,
            touchedEpisodesPerFeedPerYear: 52,
            queueAndPlaylistEntries: 200,
            bookmarks: 100
        )
        XCTAssertGreaterThan(
            aggregate, synced * 5,
            "the retired aggregate alone dwarfed everything the store now carries"
        )
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
