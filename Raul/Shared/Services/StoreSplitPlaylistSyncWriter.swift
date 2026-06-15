import Foundation
import SwiftData

struct StoreSplitPlaylistRemoval: Sendable {
    let playlistID: String
    let isDefaultQueue: Bool
    let identity: EpisodeStableIdentity
}

@ModelActor
actor StoreSplitPlaylistSyncWriter {
    func tombstone(_ removals: [StoreSplitPlaylistRemoval], at date: Date = .now) {
        guard removals.isEmpty == false else { return }
        let deviceID = ListeningDeviceIdentity.current().id

        for removal in removals {
            tombstonePlaylistEntry(removal, at: date, deviceID: deviceID)
            if removal.isDefaultQueue {
                tombstoneQueueEntry(removal, at: date, deviceID: deviceID)
            }
        }

        modelContext.saveIfNeeded()
    }

    private func tombstonePlaylistEntry(
        _ removal: StoreSplitPlaylistRemoval,
        at date: Date,
        deviceID: String
    ) {
        let id = StableIdentityKey.make(
            removal.playlistID,
            removal.identity.feedURL,
            removal.identity.episodeID
        )
        let descriptor = FetchDescriptor<PlaylistEntrySync>(
            predicate: #Predicate<PlaylistEntrySync> { $0.id == id }
        )

        if let entry = try? modelContext.fetch(descriptor).first {
            entry.isDeleted = true
            entry.deletedAt = date
            entry.updatedAt = date
            entry.sourceDeviceID = deviceID
        } else {
            let entry = PlaylistEntrySync(
                playlistID: removal.playlistID,
                feedURL: removal.identity.feedURL,
                episodeID: removal.identity.episodeID,
                sortIndex: 0,
                isDeleted: true,
                deletedAt: date,
                updatedAt: date,
                sourceDeviceID: deviceID
            )
            entry.isDeleted = true
            modelContext.insert(entry)
        }
    }

    private func tombstoneQueueEntry(
        _ removal: StoreSplitPlaylistRemoval,
        at date: Date,
        deviceID: String
    ) {
        let id = removal.identity.key
        let descriptor = FetchDescriptor<QueueEntrySync>(
            predicate: #Predicate<QueueEntrySync> { $0.id == id }
        )

        if let entry = try? modelContext.fetch(descriptor).first {
            entry.isDeleted = true
            entry.deletedAt = date
            entry.updatedAt = date
            entry.sourceDeviceID = deviceID
        } else {
            let entry = QueueEntrySync(
                feedURL: removal.identity.feedURL,
                episodeID: removal.identity.episodeID,
                sortIndex: 0,
                isDeleted: true,
                deletedAt: date,
                updatedAt: date,
                sourceDeviceID: deviceID
            )
            entry.isDeleted = true
            modelContext.insert(entry)
        }
    }
}
