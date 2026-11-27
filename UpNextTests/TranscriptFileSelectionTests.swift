import XCTest
@testable import UpNext

/// Which advertised publisher transcript file is fetched (#520 follow-up).
final class TranscriptFileSelectionTests: XCTestCase {
    private func file(_ name: String, _ type: String?) -> ExternalFile {
        ExternalFile(url: "https://example.com/\(name)", category: .transcript, source: "feed", fileType: type)
    }

    func testTimedFormatWinsOverEarlierPlainText() {
        // Real feed order: plain text and HTML are listed before the VTT.
        let files = [
            file("episode.transcript.txt", "text/plain"),
            file("episode.transcript.html", "text/html"),
            file("episode.vtt", "text/vtt")
        ]
        XCTAssertEqual(EpisodeActor.bestExternalFile(in: files)?.url, "https://example.com/episode.vtt")
    }

    func testPreferenceOrderIsVTTThenSRTThenJSONThenPlainText() {
        let files = [
            file("a.txt", "text/plain"),
            file("a.json", "application/json"),
            file("a.srt", "application/x-subrip")
        ]
        XCTAssertEqual(EpisodeActor.bestExternalFile(in: files)?.url, "https://example.com/a.srt")
        XCTAssertEqual(
            EpisodeActor.bestExternalFile(in: [files[0], files[1]])?.url,
            "https://example.com/a.json"
        )
        XCTAssertEqual(EpisodeActor.bestExternalFile(in: [files[0]])?.url, "https://example.com/a.txt")
    }

    func testUndeclaredTypeFallsBackToExtension() {
        let files = [file("a.html", nil), file("a.vtt", nil)]
        XCTAssertEqual(EpisodeActor.bestExternalFile(in: files)?.url, "https://example.com/a.vtt")
    }

    func testNoVerticalBarByDefault() {
        XCTAssertNil(VerticalBarPlacement.none.edge)
        XCTAssertGreaterThan(VerticalBarPlacement.reservedStatusHeight, 0)
    }
}
