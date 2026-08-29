import Foundation
import SwiftData
import CloudDataPresence

typealias CloudSyncProgressReference = CloudDataPresenceReference

enum CloudSyncProgressReferenceStore {
    private static let key = "cloudSyncProgressReference.v1"

    static func load() -> CloudSyncProgressReference? {
        CloudDataPresenceStore.loadReference(forKey: key)
    }

    static func publish(modelContainer: ModelContainer) async {
        let recordCount = await CloudSyncRecordCounter(modelContainer: modelContainer)
            .recordCount()
        CloudDataPresenceStore.publish(recordCount: recordCount, forKey: key)
    }

    static func localRecordCount(modelContainer: ModelContainer) async -> Int {
        await CloudSyncRecordCounter(modelContainer: modelContainer).recordCount()
    }
}

struct StoreSplitPlaylistRecordCounts: Sendable, Equatable {
    var queueEntries: Int
    var playlistEntries: Int
}

enum StoreSplitPlaylistPresenceStore {
    private static let queueEntriesKey = "cloudPresence.userState.queueEntries.v1"
    private static let playlistEntriesKey = "cloudPresence.userState.playlistEntries.v1"

    static func publish(modelContainer: ModelContainer) async {
        let counts = await localRecordCounts(modelContainer: modelContainer)
        CloudDataPresenceStore.publish(
            recordCountsByKey: [
                queueEntriesKey: counts.queueEntries,
                playlistEntriesKey: counts.playlistEntries
            ]
        )
    }

    static func cloudReferenceCount(forDefaultQueue: Bool) -> Int? {
        guard forDefaultQueue else { return nil }
        return CloudDataPresenceStore.loadReference(forKey: queueEntriesKey)?.recordCount
    }

    static func localRecordCounts(
        modelContainer: ModelContainer
    ) async -> StoreSplitPlaylistRecordCounts {
        await StoreSplitPlaylistRecordCounter(modelContainer: modelContainer).counts()
    }

    static func localPlaylistEntryCount(
        playlistID: UUID,
        modelContainer: ModelContainer
    ) async -> Int {
        await StoreSplitPlaylistRecordCounter(modelContainer: modelContainer)
            .playlistEntryCount(playlistID: playlistID.uuidString)
    }
}

@ModelActor
private actor StoreSplitPlaylistRecordCounter {
    func counts() -> StoreSplitPlaylistRecordCounts {
        let queueEntries = (try? modelContext.fetchCount(
            FetchDescriptor<QueueEntrySync>(
                predicate: #Predicate<QueueEntrySync> { $0.deletedAt == nil }
            )
        )) ?? 0
        let playlistEntries = (try? modelContext.fetchCount(
            FetchDescriptor<PlaylistEntrySync>(
                predicate: #Predicate<PlaylistEntrySync> { $0.deletedAt == nil }
            )
        )) ?? 0
        return StoreSplitPlaylistRecordCounts(
            queueEntries: queueEntries,
            playlistEntries: playlistEntries
        )
    }

    func playlistEntryCount(playlistID: String) -> Int {
        (try? modelContext.fetchCount(
            FetchDescriptor<PlaylistEntrySync>(
                predicate: #Predicate<PlaylistEntrySync> {
                    $0.playlistID == playlistID && $0.deletedAt == nil
                }
            )
        )) ?? 0
    }
}

@ModelActor
private actor CloudSyncRecordCounter {
    func recordCount() -> Int {
        count(Podcast.self)
            + count(PodcastMetaData.self)
            + count(Episode.self)
            + count(EpisodeMetaData.self)
            + count(Playlist.self)
            + count(PlaylistEntry.self)
            + count(Marker.self)
            + count(Bookmark.self)
            + count(RateSegment.self)
            + count(PlaySession.self)
            + count(ListeningStat.self)
            + count(PlaySessionSummary.self)
            + count(TranscriptionRecord.self)
    }

    private func count<Model: PersistentModel>(_ model: Model.Type) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<Model>())) ?? 0
    }
}
