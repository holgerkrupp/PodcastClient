import CloudKit
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

    func test144RecordPartialFailureAppearsInSnapshotWithPrimaryCategoryFirst() {
        var children: [String: NSError] = [:]
        for index in 0..<143 {
            children[String(format: "%03d", index)] = cloudError(.batchRequestFailed)
        }
        children["999-private-id"] = cloudError(
            .serverRejectedRequest,
            userInfo: ["CKErrorRetryAfterKey": 30.0]
        )
        let failure = CloudKitFailureAnalyzer.analyze(cloudError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: children
        ]))
        let eventID = UUID()
        let cloudStore = SupportDiagnosticCloudStore(
            store: "User State",
            setupStatus: "last observed success",
            setupAt: .now,
            importStatus: "last observed success",
            importAt: .now,
            exportStatus: "last observed failure",
            exportEventID: eventID.uuidString,
            exportStartedAt: .now.addingTimeInterval(-4),
            exportAt: .now,
            lastFailedExportEventID: eventID.uuidString,
            lastFailedExportAt: .now,
            lastSuccessfulExportAt: nil,
            failedExportCount: 1,
            retryAfterSeconds: 30,
            failureCategories: failure.groups.map { "\($0.displayName) × \($0.count)" }
        )
        let recorder = SupportDiagnosticsRecorder()
        recorder.append(snapshot(at: .now, queueEntries: 0, cloudStores: [cloudStore]))

        let report = recorder.reportText

        XCTAssertTrue(report.contains("CKError \(CKError.Code.serverRejectedRequest.rawValue) — serverRejectedRequest × 1"))
        XCTAssertTrue(report.contains("CKError \(CKError.Code.batchRequestFailed.rawValue) — batchRequestFailed × 143"))
        XCTAssertTrue(report.contains("retry hint 30 seconds"))
        XCTAssertTrue(report.contains(eventID.uuidString))
        XCTAssertFalse(report.contains("999-private-id"))
    }

    func testUnavailableLocalQueryIsNotReportedAsZero() {
        let recorder = SupportDiagnosticsRecorder()
        recorder.append(snapshot(
            at: .now,
            queueEntries: 0,
            runtimeQueueCount: .unavailable
        ))

        let report = recorder.reportText

        XCTAssertTrue(report.contains("playlists=unavailable (local store query failed)"))
        XCTAssertFalse(report.contains("Runtime-visible Up Next (local snapshot): playlists=0"))
    }

    func testPreCaptureInstructionsPreserveTesterDataAndWaitingWindow() {
        let recorder = SupportDiagnosticsRecorder()

        XCTAssertTrue(recorder.reportText.contains("after waiting at least three minutes"))
        XCTAssertTrue(recorder.reportText.contains("without reinstalling or resetting data"))
    }

    func testLaunchReportIncludesHydrationPhaseWithoutPrivateEventDetails() {
        SupportDiagnosticsRecorder.shared.record(
            "Runtime compatibility hydration started",
            detail: "https://private.example/feed?token=secret"
        )
        let report = SupportDiagnosticsRecorder.launchReport()

        XCTAssertTrue(report.contains("Runtime container:"))
        XCTAssertTrue(report.contains("Runtime readiness:"))
        XCTAssertTrue(report.contains("Runtime compatibility hydration started"))
        XCTAssertFalse(report.contains("private.example"))
        XCTAssertFalse(report.contains("token=secret"))
        XCTAssertFalse(report.contains("unavailable (store did not open)"))
    }

    func testLatestExportResultWinsEvenWhenEventDatesCoincide() {
        let failure = storeDiagnostics(exportSucceeded: false)
        let success = storeDiagnostics(exportSucceeded: true)

        XCTAssertTrue(failure.hasUnresolvedExportFailure)
        XCTAssertFalse(success.hasUnresolvedExportFailure)
    }

    private func snapshot(
        at date: Date,
        queueEntries: Int,
        runtimeQueueCount: SupportDiagnosticCount? = nil,
        cloudStores: [SupportDiagnosticCloudStore] = []
    ) -> SupportDiagnosticSnapshot {
        let queueCount = SupportDiagnosticCount.available(queueEntries)
        let zero = SupportDiagnosticCount.available(0)
        return SupportDiagnosticSnapshot(
            capturedAt: date,
            elapsedSeconds: Int(date.timeIntervalSinceNow * -1),
            appVersion: "1.0",
            appBuild: "100",
            osVersion: "iOS test",
            deviceClass: "iPhone",
            releasePhase: "dualSyncBackfill",
            bootstrapMode: "legacyUpgrade",
            installationClassification: "existing installation",
            onboardingCompleted: true,
            appGroupAvailable: true,
            storeFiles: [],
            legacyCloudAttachmentConfigured: true,
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
            runtimeQueuePlaylistCount: runtimeQueueCount ?? .available(1),
            runtimeQueueEntryCount: queueCount,
            runtimeSubscriptionCount: .available(1),
            legacySubscriptionCount: .available(1),
            userStateSubscriptionActiveCount: .available(1),
            userStateSubscriptionTombstoneCount: zero,
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
            portableRecovery: SupportDiagnosticPortableRecovery(
                state: PortableWriteFailureMonitor.State()
            ),
            cloudStores: cloudStores
        )
    }

    private func storeDiagnostics(exportSucceeded: Bool) -> StoreCloudKitActivityMonitor.StoreDiagnostics {
        let sameInstant = Date(timeIntervalSince1970: 100)
        return StoreCloudKitActivityMonitor.StoreDiagnostics(
            storeKind: .userState,
            storeIdentifier: nil,
            isAttached: true,
            activeSetupCount: 0,
            activeImportCount: 0,
            activeExportCount: 0,
            lastImportStartedAt: nil,
            lastImportEndedAt: nil,
            lastImportSucceeded: nil,
            lastSuccessfulImportAt: nil,
            lastImportErrorCode: nil,
            lastImportCountsBefore: nil,
            lastImportCountsAfter: nil,
            lastExportEndedAt: sameInstant,
            lastExportStartedAt: sameInstant,
            lastExportEventID: UUID(),
            lastExportSucceeded: exportSucceeded,
            lastSuccessfulExportAt: sameInstant,
            lastExportErrorCode: exportSucceeded ? nil : 1,
            lastExportFailureReport: nil,
            failedExportCount: exportSucceeded ? 1 : 2,
            lastReconciliation: nil
        )
    }

    private func cloudError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }
}
