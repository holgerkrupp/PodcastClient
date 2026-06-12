import Foundation
import SwiftData

struct CloudSyncProgressReference: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var recordCount: Int

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        recordCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.recordCount = recordCount
    }
}

enum CloudSyncProgressReferenceStore {
    private static let key = "cloudSyncProgressReference.v1"

    static func load() -> CloudSyncProgressReference? {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()

        guard let data = store.data(forKey: key),
              let reference = try? JSONDecoder().decode(CloudSyncProgressReference.self, from: data),
              reference.schemaVersion == CloudSyncProgressReference.currentSchemaVersion,
              reference.recordCount > 0 else {
            return nil
        }

        return reference
    }

    static func publish(modelContainer: ModelContainer) async {
        let recordCount = await CloudSyncRecordCounter(modelContainer: modelContainer)
            .recordCount()
        guard recordCount > 0 else { return }

        let reference = CloudSyncProgressReference(recordCount: recordCount)
        guard let data = try? JSONEncoder().encode(reference) else { return }

        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: key)
        store.synchronize()
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
