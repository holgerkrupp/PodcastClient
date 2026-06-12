import XCTest
@testable import UpNext

final class SiriPodcastEpisodeIntentTests: XCTestCase {
    func testParsesPodcastBeforeEpisodeNumber() throws {
        let request = try XCTUnwrap(
            SiriEpisodeRequestEntity(spokenRequest: "Bits und so Episode 900")
        )

        XCTAssertEqual(request.podcastTitle, "Bits und so")
        XCTAssertEqual(request.episodeNumber, 900)
    }

    func testParsesEpisodeNumberBeforePodcast() throws {
        let request = try XCTUnwrap(
            SiriEpisodeRequestEntity(spokenRequest: "Episode 900 of Bits und so")
        )

        XCTAssertEqual(request.podcastTitle, "Bits und so")
        XCTAssertEqual(request.episodeNumber, 900)
    }

    func testParsesGermanEpisodePhrase() throws {
        let request = try XCTUnwrap(
            SiriEpisodeRequestEntity(spokenRequest: "Folge 900 von Bits und so")
        )

        XCTAssertEqual(request.podcastTitle, "Bits und so")
        XCTAssertEqual(request.episodeNumber, 900)
    }

    func testRejectsRequestWithoutEpisodeNumber() {
        XCTAssertNil(SiriEpisodeRequestEntity(spokenRequest: "Play Bits und so"))
    }
}
