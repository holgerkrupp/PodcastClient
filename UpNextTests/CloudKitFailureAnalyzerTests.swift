import CloudKit
import XCTest
@testable import UpNext

final class CloudKitFailureAnalyzerTests: XCTestCase {
    func testActionableFailureAfterOldFirstTwentyFiveWindowIsPrioritized() {
        var failures: [String: NSError] = [:]
        for index in 0..<143 {
            failures[String(format: "%03d", index)] = cloudError(.batchRequestFailed)
        }
        failures["999"] = cloudError(
            .serverRejectedRequest,
            reason: "The server rejected an invalid field."
        )
        let error = cloudError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: failures])

        let report = CloudKitFailureAnalyzer.analyze(error)

        XCTAssertEqual(report.groups.first?.name, "serverRejectedRequest")
        XCTAssertEqual(report.groups.first?.count, 1)
        XCTAssertEqual(report.batchFailureCount, 143)
        XCTAssertEqual(
            report.summary,
            "1 CKError \(CKError.Code.serverRejectedRequest.rawValue) — serverRejectedRequest + 143 collateral batch failures"
        )
        XCTAssertFalse(report.summary.contains("999"))
    }

    func testNestedUnderlyingAndPartialErrorsAreGroupedAndRetryHintIsKept() {
        let primary = cloudError(
            .requestRateLimited,
            reason: "Try again later.",
            userInfo: ["CKErrorRetryAfterKey": 30.0]
        )
        let nested = cloudError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: ["private-record-id": primary]
        ])
        let wrapped = NSError(
            domain: "NSCocoaErrorDomain",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: nested]
        )

        let report = CloudKitFailureAnalyzer.analyze(wrapped)

        XCTAssertEqual(report.groups.first?.name, "requestRateLimited")
        XCTAssertEqual(report.groups.first?.count, 1)
        XCTAssertEqual(report.groups.first?.retryAfterSeconds, 30)
        XCTAssertFalse(report.groups.first?.reason?.contains("private-record-id") ?? true)
    }

    func testPartialFailureWithoutChildrenKeepsSafeDetailAndDropsRecordValues() throws {
        let error = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            "ServerErrorDescription": "Cannot create new type CD_SubscriptionSync in production schema for My Private Show",
            NSLocalizedDescriptionKey: "Partial Failure"
        ])

        let report = CloudKitFailureAnalyzer.analyze(error)
        let detail = try XCTUnwrap(report.groups.first?.detail)
        XCTAssertTrue(detail.contains("schema_not_in_production"))
        XCTAssertTrue(detail.contains("CD_SubscriptionSync"))
        XCTAssertTrue(detail.contains("ServerErrorDescription"))

        let persisted = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(persisted.contains("schema_not_in_production"))
        XCTAssertFalse(persisted.contains("My Private Show"))
    }

    func testMultipleUnderlyingErrorsAreVisited() {
        let child = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue)
        let report = CloudKitFailureAnalyzer.analyze(NSError(
            domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSMultipleUnderlyingErrorsKey: [child]]
        ))
        XCTAssertEqual(report.groups.map(\.code), [CKError.Code.quotaExceeded.rawValue])
    }

    func testPrivateCodesReportThePublicCodeAndTheServerMessageOnEitherLevel() throws {
        func wrapped(_ code: CKError.Code, internalCode: Int, inner: [String: Any] = [:]) -> NSError {
            cloudError(code, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: "CKInternalErrorDomain", code: internalCode, userInfo: inner)
            ])
        }
        var failures: [String: NSError] = [:]
        for index in 0..<253 {
            failures["batch-\(index)"] = wrapped(.batchRequestFailed, internalCode: 2024)
        }
        for index in 0..<2 {
            failures["bad-\(index)"] = wrapped(.invalidArguments, internalCode: 2006, inner: [
                "ServerErrorDescription": "Cannot create new type CD_SubscriptionSync in production schema for My Private Show"
            ])
        }

        let report = CloudKitFailureAnalyzer.analyze(cloudError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: failures
        ]))

        XCTAssertEqual(report.groups.first?.name, "invalidArguments")
        XCTAssertEqual(report.groups.first?.count, 2)
        XCTAssertEqual(report.batchFailureCount, 253)
        let detail = try XCTUnwrap(report.groups.first?.detail)
        XCTAssertTrue(detail.contains("schema_not_in_production"))
        XCTAssertTrue(detail.contains("CD_SubscriptionSync"))
        let persisted = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(persisted.contains("My Private Show"))
    }

    func testBatchOnlyErrorExplainsRootCauseWasNotIncluded() {
        let error = cloudError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: ["record": cloudError(.batchRequestFailed)]
        ])

        let report = CloudKitFailureAnalyzer.analyze(error)

        XCTAssertEqual(report.actionableGroups.count, 0)
        XCTAssertEqual(report.batchFailureCount, 1)
        XCTAssertTrue(report.summary.contains("root cause is not present"))
    }

    func testSharedErrorObjectCountsOnceForEachRecordAndReportOmitsRecordIDs() throws {
        let sharedError = cloudError(.constraintViolation, reason: "Invalid field value.")
        let report = CloudKitFailureAnalyzer.analyze(cloudError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                "private-record-one": sharedError,
                "private-record-two": sharedError
            ]
        ]))

        XCTAssertEqual(report.groups.first?.count, 2)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        XCTAssertFalse(encoded.contains("private-record-one"))
        XCTAssertFalse(encoded.contains("private-record-two"))
        XCTAssertFalse(encoded.contains("Invalid field value"))
    }

    func testNonCloudKitDomainAndCodeRemainActionableAndUnsafeDomainIsRedacted() throws {
        let frameworkError = NSError(
            domain: "NSPersistentStoreErrorDomain",
            code: 134_060
        )
        let frameworkReport = CloudKitFailureAnalyzer.analyze(frameworkError)
        let frameworkJSON = try XCTUnwrap(String(
            data: JSONEncoder().encode(frameworkReport),
            encoding: .utf8
        ))

        XCTAssertEqual(frameworkReport.groups.first?.displayName, "NSPersistentStoreErrorDomain (134060)")
        XCTAssertTrue(frameworkReport.summary.contains("NSPersistentStoreErrorDomain (134060)"))
        XCTAssertTrue(frameworkJSON.contains("NSPersistentStoreErrorDomain"))
        XCTAssertTrue(frameworkJSON.contains("134060"))

        let unsafeDomain = NSError(
            domain: "https://private.example/feed?token=secret",
            code: 42
        )
        let unsafeReport = CloudKitFailureAnalyzer.analyze(unsafeDomain)
        let unsafeJSON = try XCTUnwrap(String(
            data: JSONEncoder().encode(unsafeReport),
            encoding: .utf8
        ))

        XCTAssertEqual(unsafeReport.groups.first?.domain, "custom error domain")
        XCTAssertFalse(unsafeJSON.contains("private.example"))
        XCTAssertFalse(unsafeJSON.contains("secret"))
    }

    func testUnderlyingErrorTraversalStopsAtDepthBudget() {
        var error = cloudError(.serverRejectedRequest)
        for _ in 0..<40 {
            error = NSError(domain: "Wrapped", code: 1, userInfo: [NSUnderlyingErrorKey: error])
        }

        let report = CloudKitFailureAnalyzer.analyze(error)

        XCTAssertTrue(report.wasTruncated)
        XCTAssertLessThanOrEqual(report.visitedErrorCount, 17)
    }

    private func cloudError(
        _ code: CKError.Code,
        reason: String? = nil,
        userInfo: [String: Any] = [:]
    ) -> NSError {
        var info = userInfo
        if let reason {
            info[NSLocalizedFailureReasonErrorKey] = reason
        }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: info)
    }
}
