import XCTest
@testable import UpNext

@MainActor
final class PlaylistSymbolOptionsTests: XCTestCase {
    func testCuratedOptionsAreDistinctAndManageable() {
        let options = Playlist.symbolOptions

        XCTAssertGreaterThanOrEqual(options.count, 25)
        XCTAssertLessThanOrEqual(options.count, 40)
        XCTAssertEqual(Set(options.map(\.symbolName)).count, options.count)
        XCTAssertEqual(Set(options.map(\.title)).count, options.count)
        XCTAssertTrue(options.contains { $0.title == "Downloaded" })
        XCTAssertTrue(options.contains { $0.title == "News" })
        XCTAssertTrue(options.contains { $0.title == "Science" })
        XCTAssertTrue(options.contains { $0.title == "True Crime" })
    }

    func testDefaultAndSmartPlaylistExampleIconsRemainAvailable() {
        let names = Set(Playlist.symbolOptions.map(\.symbolName))

        XCTAssertTrue(names.contains(Playlist.defaultManualSymbolName))
        XCTAssertTrue(names.contains(Playlist.defaultQueueSymbolName))
        XCTAssertTrue(names.contains(Playlist.smartPlaylistSymbolName))
        for example in SmartPlaylistExample.allCases {
            XCTAssertTrue(names.contains(example.symbol), "Missing preset icon for \(example)")
        }
    }

    func testLegacyIconRemainsSelectableUntilReplaced() {
        let legacySymbol = "tray.and.arrow.down.fill"
        let options = Playlist.symbolOptions(including: legacySymbol)

        XCTAssertEqual(options.first?.symbolName, legacySymbol)
        XCTAssertEqual(options.first?.title, "Current")
        XCTAssertEqual(options.filter { $0.symbolName == legacySymbol }.count, 1)
        XCTAssertEqual(options.count, Playlist.symbolOptions.count + 1)
    }

    func testCuratedOrEmptySelectionDoesNotAddASecondTile() {
        let firstSymbol = Playlist.defaultManualSymbolName

        XCTAssertEqual(Playlist.symbolOptions(including: firstSymbol), Playlist.symbolOptions)
        XCTAssertEqual(Playlist.symbolOptions(including: ""), Playlist.symbolOptions)
    }
}
