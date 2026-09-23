import XCTest
@testable import UpNext

final class RemoteMP3PlaybackDurationReaderTests: XCTestCase {
    func testConvertsID3TLENMillisecondsToSeconds() {
        XCTAssertEqual(
            RemoteMP3PlaybackDurationReader.duration(fromID3: ["TLEN": " 3600000 "]),
            3_600
        )
    }

    func testRejectsMissingOrInvalidTLEN() {
        let invalidTags: [[String: Any]] = [
            [:],
            ["TLEN": "0"],
            ["TLEN": "-1000"],
            ["TLEN": "not a number"],
            ["TLEN": "inf"],
            ["TLEN": "3,600,000"]
        ]
        for tags in invalidTags {
            XCTAssertNil(RemoteMP3PlaybackDurationReader.duration(fromID3: tags))
        }
    }
}
