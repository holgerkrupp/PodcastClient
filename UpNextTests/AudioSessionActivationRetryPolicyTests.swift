import XCTest
@testable import UpNext

final class AudioSessionActivationRetryPolicyTests: XCTestCase {
    func testRetriesUseShortIncreasingDelays() {
        let delays = (1...3).compactMap {
            AudioSessionActivationRetryPolicy.delay(afterFailedAttempt: $0)
        }

        XCTAssertEqual(delays, [0.15, 0.35, 0.75])
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testRetriesStopAfterThreeRetries() {
        XCTAssertNil(AudioSessionActivationRetryPolicy.delay(afterFailedAttempt: 0))
        XCTAssertNil(AudioSessionActivationRetryPolicy.delay(afterFailedAttempt: 4))
    }
}
