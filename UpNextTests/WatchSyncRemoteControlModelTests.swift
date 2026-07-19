import SwiftData
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

    func testPlaylistEntryQueryFiltersAndOrdersInTheStore() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let selectedPlaylist = Playlist()
        selectedPlaylist.title = "Selected"
        let otherPlaylist = Playlist()
        otherPlaylist.title = "Other"
        context.insert(selectedPlaylist)
        context.insert(otherPlaylist)

        let selectedOrders = [7, 1, 4]
        for order in selectedOrders {
            let episode = Episode(
                guid: "selected-\(order)",
                title: "Selected \(order)",
                url: URL(string: "https://example.com/selected-\(order).mp3")!,
                duration: 100
            )
            let entry = PlaylistEntry(episode: episode, order: order)
            context.insert(episode)
            context.insert(entry)
            entry.playlist = selectedPlaylist
        }

        let otherEpisode = Episode(
            guid: "other",
            title: "Other",
            url: URL(string: "https://example.com/other.mp3")!,
            duration: 100
        )
        let otherEntry = PlaylistEntry(episode: otherEpisode, order: 0)
        context.insert(otherEpisode)
        context.insert(otherEntry)
        otherEntry.playlist = otherPlaylist
        try context.save()

        let entries = try WatchSyncPlaylistEntryQuery.fetchOrdered(
            playlistID: selectedPlaylist.id,
            in: context
        )

        XCTAssertEqual(entries.map(\.order), [1, 4, 7])
        XCTAssertTrue(entries.allSatisfy { $0.playlist?.id == selectedPlaylist.id })
    }
}
