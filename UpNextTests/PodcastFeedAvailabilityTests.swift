import Foundation
import XCTest
@testable import UpNext

final class PodcastFeedAvailabilityTests: XCTestCase {
    func testHeadStatusIsAdvisoryAndCannotDeclareFeedDead() {
        for code in [304, 401, 403, 404, 405, 410, 429, 500, 503] {
            let status = URLstatus(
                statusCode: code,
                newURL: nil,
                lastRequest: Date(),
                requestMethod: "HEAD"
            )

            XCTAssertFalse(status.isDeadFeedResponse, "HEAD \(code) must not prove a GET feed is dead")
        }
    }

    func testUnknownStatusIsNotDead() {
        let status = URLstatus(lastRequest: Date())
        XCTAssertFalse(status.isDeadFeedResponse)
        XCTAssertEqual(status.availability, .unknown)
        XCTAssertEqual(status.displayMessage, "Could not check feed")
    }

    func testProbeStatusesKeepFailureClassesDistinct() {
        XCTAssertEqual(makeStatus(401).availability, .authenticationRequired)
        XCTAssertEqual(makeStatus(404).availability, .definitivelyAbsent)
        XCTAssertEqual(makeStatus(405).availability, .headUnsupported)
        XCTAssertEqual(makeStatus(429).availability, .temporarilyUnavailable)
        XCTAssertEqual(makeStatus(503).availability, .temporarilyUnavailable)
        XCTAssertEqual(makeStatus(304).availability, .reachable)
        var getNotFound = makeStatus(404)
        getNotFound.requestMethod = "GET"
        XCTAssertTrue(getNotFound.isDeadFeedResponse)
    }

    private func makeStatus(_ code: Int) -> URLstatus {
        URLstatus(statusCode: code, newURL: nil, lastRequest: Date(), requestMethod: "HEAD")
    }
}
