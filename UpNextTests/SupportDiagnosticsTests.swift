import XCTest
@testable import UpNext

@MainActor
final class SupportDiagnosticsTests: XCTestCase {
    func testEmptyThenRestoredQueueProducesTwoSnapshotsAndInterveningTimeline() {
        let recorder = SupportDiagnosticsRecorder()
        let now = Date()

        recorder.recordPlaylistVisibleCount(0, isDefaultQueue: true)
        recorder.append(snapshot(at: now, queueEntries: 0))
        recorder.record("CloudKit User State import", detail: "completed")
        recorder.recordPlaylistVisibleCount(4, isDefaultQueue: true)
        recorder.append(snapshot(at: now.addingTimeInterval(90), queueEntries: 4))

        let report = recorder.reportText

        XCTAssertTrue(report.contains("Snapshot 1"))
        XCTAssertTrue(report.contains("Snapshot 2"))
        XCTAssertTrue(report.contains("entries=0"))
        XCTAssertTrue(report.contains("entries=4"))
        XCTAssertTrue(report.contains("CloudKit User State import · completed"))
        XCTAssertTrue(report.contains("Up Next visible · entries=0"))
        XCTAssertTrue(report.contains("Up Next visible · entries=4"))
        XCTAssertFalse(report.contains("private-record"))
    }

    private func snapshot(at date: Date, queueEntries: Int) -> SupportDiagnosticSnapshot {
        let queueCount = SupportDiagnosticCount.available(queueEntries)
        let zero = SupportDiagnosticCount.available(0)
        return SupportDiagnosticSnapshot(
            capturedAt: date,
            elapsedSeconds: Int(date.timeIntervalSinceNow * -1),
            appVersion: "1.0",
            appBuild: "100",
            osVersion: "iOS test",
            deviceClass: "iPhone",
            bootstrapMode: "legacyUpgrade",
            readAuthority: "Legacy Library",
            runtimeKind: "durable library store",
            runtimeStoreStatus: "open",
            legacyStoreStatus: "open",
            userStateStoreStatus: "open",
            cacheStoreStatus: "open",
            runtimeReadiness: "ready",
            migrationVersion: 1,
            migrationPhase: "not observed",
            migrationProgress: "not observed",
            pendingWork: "none observed",
            runtimeQueuePlaylistCount: .available(1),
            runtimeQueueEntryCount: queueCount,
            legacyPlaylistCount: .available(1),
            legacyPlaylistEntryCount: queueCount,
            userStatePlaylistActiveCount: .available(1),
            userStatePlaylistTombstoneCount: zero,
            userStatePlaylistEntryActiveCount: queueCount,
            userStatePlaylistEntryTombstoneCount: zero,
            userStateQueueActiveCount: queueCount,
            userStateQueueTombstoneCount: zero,
            unresolvedEpisodeReferenceCount: zero,
            networkStatus: "Available",
            accountStatus: "Available",
            aggregateErrorCategories: [],
            cloudStores: []
        )
    }
}
