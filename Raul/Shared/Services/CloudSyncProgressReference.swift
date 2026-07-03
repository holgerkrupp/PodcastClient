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
