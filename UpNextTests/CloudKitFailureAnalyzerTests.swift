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
            "1 serverRejectedRequest + 143 collateral batch failures"
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
