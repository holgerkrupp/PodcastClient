import XCTest
@testable import UpNext

final class WatchSyncRemoteControlModelTests: XCTestCase {
    func testLegacyStorageSettingsDefaultToLocalPlayback() throws {
        let data = Data(#"{"maxStorageBytes":1048576,"allowCellularDownloads":true}"#.utf8)

        let settings = try JSONDecoder().decode(WatchStorageSettings.self, from: data)

        XCTAssertEqual(settings.maxStorageBytes, 1_048_576)
        XCTAssertTrue(settings.allowCellularDownloads)
        XCTAssertEqual(settings.playbackMode, .local)
    }

    func testLegacySnapshotDecodesWithoutPhonePlaybackState() throws {
        let json = """
        {
          "generatedAt": "2026-06-02T06:00:00Z",
          "playlist": [],
          "inbox": [],
          "playlists": [],
          "selectedPlaylistTitle": "Up Next",
          "skipBackSeconds": 15,
          "skipForwardSeconds": 30,
          "phoneTransferEpisodeIDs": [],
          "phoneTransferProgressByEpisodeID": {}
        }
        """

        let snapshot = try XCTUnwrap(WatchSyncTransport.decode(WatchSyncSnapshot.self, from: Data(json.utf8)))

        XCTAssertNil(snapshot.phonePlaybackState)
        XCTAssertEqual(snapshot.playbackSettings.playbackSpeed, 1.0)
        XCTAssertEqual(snapshot.selectedPlaylistTitle, "Up Next")
    }

    func testRemoteMoveCommandRoundTripsIndexes() throws {
        let command = WatchCommand(
            kind: .remoteMovePlaylistEpisode,
            playlistID: UUID().uuidString,
            sourceIndex: 1,
            destinationIndex: 2
        )

        let data = try XCTUnwrap(WatchSyncTransport.encode(command))
        let decoded = try XCTUnwrap(WatchSyncTransport.decode(WatchCommand.self, from: data))

        XCTAssertEqual(decoded.kind, .remoteMovePlaylistEpisode)
        XCTAssertEqual(decoded.sourceIndex, 1)
        XCTAssertEqual(decoded.destinationIndex, 2)
    }
}
