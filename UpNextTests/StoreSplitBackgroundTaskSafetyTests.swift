import XCTest
@testable import UpNext

final class StoreSplitBackgroundTaskSafetyTests: XCTestCase {
    func testCancelledBackgroundPassCannotStartAnotherStoreOperation() {
        XCTAssertFalse(StoreSplitTaskCancellation.shouldBeginStoreWork(isCancelled: true))
        XCTAssertTrue(StoreSplitTaskCancellation.shouldBeginStoreWork(isCancelled: false))
    }
}
