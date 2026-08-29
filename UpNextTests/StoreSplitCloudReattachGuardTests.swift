import SwiftData
import XCTest
@testable import UpNext

/// The legacy store's CloudKit mirror is switched by a compile-time constant, so
/// the only thing that can tell a re-attach from a store that was always mirrored
/// is the decision recorded on the previous launch.
final class StoreSplitCloudReattachGuardTests: XCTestCase {
    private let lastStateKey = StoreDevelopmentConfiguration.legacyCloudSyncLastStateKey
    private let approvedKey = StoreDevelopmentConfiguration.legacyCloudReattachApprovedKey

    override func setUp() {
        super.setUp()
        clearGuardDefaults()
    }

    override func tearDown() {
        clearGuardDefaults()
        super.tearDown()
    }

    func testReattachIsBlockedAfterASpellWithMirroringOff() {
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(true)
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudReattachBlocked)

        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(false)
        XCTAssertTrue(
            StoreDevelopmentConfiguration.legacyCloudReattachBlocked,
            "rows written while detached carry no CloudKit identity; re-attaching merges them alongside the zone"
        )
    }

    func testApprovalUnblocksExactlyOneReattach() {
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(false)
        StoreDevelopmentConfiguration.approveLegacyCloudReattach()
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudReattachBlocked)

        // The re-attach the approval covered.
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(true)
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudReattachBlocked)
    }

    /// The cutover detaches every install's legacy store and a rollback re-attaches
    /// it — the population-scale version of the sequence that duplicated the
    /// development device. An approval granted before the cutover must not carry
    /// through it, or the guard fires once per install and never again.
    func testApprovalDoesNotSurviveALaterDetach() {
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(false)
        StoreDevelopmentConfiguration.approveLegacyCloudReattach()
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(true)

        // Cutover to `.userStateAuthority`: mirroring off again.
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(false)
        XCTAssertTrue(
            StoreDevelopmentConfiguration.legacyCloudReattachBlocked,
            "a rollback after the cutover must be blocked even on a device that approved an earlier re-attach"
        )
    }

    func testAStoreThatWasNeverDetachedIsNeverBlocked() {
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudReattachBlocked)
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(true)
        StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(true)
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudReattachBlocked)
    }

    /// The release phase is the only thing allowed to decide what the legacy store
    /// is attached to.
    ///
    /// Between `989ac881` (2026-06-24) and `9c7ddeae` (2026-08-17) the store mode
    /// decided it too: `effectiveLegacyCloudSyncEnabled` was gated on
    /// `cloudSyncSettingsAvailable`, which is false for `.legacyOnly`, and the
    /// remote kill switch resolved the mode to `.legacyOnly`. Publishing a kill
    /// therefore detached every affected device's library store from CloudKit, and
    /// clearing it re-attached them — the duplication mechanism, on a remote
    /// trigger, for whoever ran a build from that window.
    func testNoStoreModeCanDetachTheLegacyStore() {
        for mode in DevelopmentStoreMode.allCases {
            for enabled in [true, false] {
                let configuration = StoreDevelopmentConfiguration(
                    mode: mode,
                    legacyCloudSyncEnabled: enabled,
                    userStateCloudSyncEnabled: true,
                    splitStoreWorkEnabled: true
                )
                XCTAssertEqual(
                    configuration.effectiveLegacyCloudSyncEnabled, enabled,
                    "mode \(mode.rawValue) must not change the legacy store's CloudKit attachment"
                )
            }
        }
    }

    func testTheRolloutNeverResolvesToLegacyOnly() {
        XCTAssertNotEqual(
            StoreSplitRollout.resolvedMode, .legacyOnly,
            "a resolved mode of .legacyOnly is what let the remote kill switch detach the library store"
        )
    }

    private func clearGuardDefaults() {
        UserDefaults.standard.removeObject(forKey: lastStateKey)
        UserDefaults.standard.removeObject(forKey: approvedKey)
    }
}
