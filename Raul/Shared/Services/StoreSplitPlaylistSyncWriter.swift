import Foundation
import SwiftData

struct StoreSplitPlaylistRemoval: Sendable {
    let playlistID: String
    let isDefaultQueue: Bool
    let identity: EpisodeStableIdentity
}

struct StoreSplitPlaylistEntrySnapshot: Sendable {
    let identity: EpisodeStableIdentity
    let sortIndex: Int
    let addedAt: Date
}

struct StoreSplitPlaylistSnapshot: Sendable {
    let id: String
    let title: String
    let symbolName: String
    let sortIndex: Int
    let kindRawValue: String
    let smartFilterRawValue: String?
    let isHidden: Bool
    let entries: [StoreSplitPlaylistEntrySnapshot]
}

extension Playlist {
    var storeSplitSnapshot: StoreSplitPlaylistSnapshot {
        let smartFilterRawValue = smartFilter
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return StoreSplitPlaylistSnapshot(
            id: id.uuidString,
            title: title,
            symbolName: symbolName,
            sortIndex: sortIndex,
            kindRawValue: kindRawValue,
            smartFilterRawValue: smartFilterRawValue,
            isHidden: hidden,
            entries: ordered.compactMap { entry in
                guard let episode = entry.episode else { return nil }
                return StoreSplitPlaylistEntrySnapshot(
                    identity: episode.stableEpisodeIdentity,
                    sortIndex: entry.order,
                    addedAt: entry.dateAdded ?? .now
                )
            }
        )
    }
}

@MainActor
enum StoreSplitPlaylistSyncCoordinator {
    static func publish(_ playlist: Playlist) {
        let snapshot = playlist.storeSplitSnapshot
        Task {
            await ModelContainerManager.shared.prepareSplitStores()
            guard let container = ModelContainerManager.shared.preparedUserStateContainer else {
                return
            }
            await StoreSplitPlaylistSyncWriter(modelContainer: container).upsert(snapshot)
        }
    }

    static func tombstone(playlistID: UUID) {
        Task {
            await ModelContainerManager.shared.prepareSplitStores()
            guard let container = ModelContainerManager.shared.preparedUserStateContainer else {
                return
            }
            await StoreSplitPlaylistSyncWriter(modelContainer: container)
                .tombstonePlaylist(id: playlistID.uuidString)
        }
    }
}

@ModelActor
actor StoreSplitPlaylistSyncWriter {
    func upsert(_ snapshot: StoreSplitPlaylistSnapshot, at date: Date = .now) {
        let deviceID = ListeningDeviceIdentity.current().id
        let playlistID = snapshot.id
        let playlistDescriptor = FetchDescriptor<PlaylistSync>(
            predicate: #Predicate<PlaylistSync> { $0.id == playlistID }
        )
        if let playlist = try? modelContext.fetch(playlistDescriptor).first {
            playlist.title = snapshot.title
            playlist.symbolName = snapshot.symbolName
            playlist.sortIndex = snapshot.sortIndex
            playlist.kindRawValue = snapshot.kindRawValue
            playlist.smartFilterRawValue = snapshot.smartFilterRawValue
            playlist.isHidden = snapshot.isHidden
            playlist.isDeleted = false
            playlist.deletedAt = nil
            playlist.updatedAt = date
            playlist.sourceDeviceID = deviceID
        } else {
            modelContext.insert(
                PlaylistSync(
                    id: snapshot.id,
                    title: snapshot.title,
                    symbolName: snapshot.symbolName,
                    sortIndex: snapshot.sortIndex,
                    kindRawValue: snapshot.kindRawValue,
                    smartFilterRawValue: snapshot.smartFilterRawValue,
                    isHidden: snapshot.isHidden,
                    updatedAt: date,
                    sourceDeviceID: deviceID
                )
            )
        }

        let existingEntries = ((try? modelContext.fetch(
            FetchDescriptor<PlaylistEntrySync>()
        )) ?? []).filter { $0.playlistID == snapshot.id }
        let existingQueueEntries = snapshot.title == Playlist.defaultQueueTitle
            ? ((try? modelContext.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
            : []
        for entrySnapshot in snapshot.entries {
            let entryID = StableIdentityKey.make(
                snapshot.id,
                entrySnapshot.identity.feedURL,
                entrySnapshot.identity.episodeID
            )
            if let entry = existingEntries.first(where: { $0.id == entryID }) {
                entry.sortIndex = entrySnapshot.sortIndex
                entry.addedAt = entrySnapshot.addedAt
                entry.isDeleted = false
                entry.deletedAt = nil
                entry.updatedAt = date
                entry.sourceDeviceID = deviceID
            } else {
                modelContext.insert(
                    PlaylistEntrySync(
                        playlistID: snapshot.id,
                        feedURL: entrySnapshot.identity.feedURL,
                        episodeID: entrySnapshot.identity.episodeID,
                        sortIndex: entrySnapshot.sortIndex,
                        addedAt: entrySnapshot.addedAt,
                        updatedAt: date,
                        sourceDeviceID: deviceID
                    )
                )
            }

            if snapshot.title == Playlist.defaultQueueTitle {
                let queueID = entrySnapshot.identity.key
                if let queueEntry = existingQueueEntries.first(where: { $0.id == queueID }) {
                    queueEntry.sortIndex = entrySnapshot.sortIndex
                    queueEntry.addedAt = entrySnapshot.addedAt
                    queueEntry.isDeleted = false
                    queueEntry.deletedAt = nil
                    queueEntry.updatedAt = date
                    queueEntry.sourceDeviceID = deviceID
                } else {
                    modelContext.insert(
                        QueueEntrySync(
                            feedURL: entrySnapshot.identity.feedURL,
                            episodeID: entrySnapshot.identity.episodeID,
                            sortIndex: entrySnapshot.sortIndex,
                            addedAt: entrySnapshot.addedAt,
                            updatedAt: date,
                            sourceDeviceID: deviceID
                        )
                    )
                }
            }
        }

        modelContext.saveIfNeeded()
    }

    func tombstonePlaylist(id: String, at date: Date = .now) {
        let deviceID = ListeningDeviceIdentity.current().id
        let descriptor = FetchDescriptor<PlaylistSync>(
            predicate: #Predicate<PlaylistSync> { $0.id == id }
        )
        if let playlist = try? modelContext.fetch(descriptor).first {
            playlist.isDeleted = true
            playlist.deletedAt = date
            playlist.updatedAt = date
            playlist.sourceDeviceID = deviceID
        }
        let entries = ((try? modelContext.fetch(
            FetchDescriptor<PlaylistEntrySync>()
        )) ?? []).filter { $0.playlistID == id }
        for entry in entries {
            entry.isDeleted = true
            entry.deletedAt = date
            entry.updatedAt = date
            entry.sourceDeviceID = deviceID
        }
        modelContext.saveIfNeeded()
    }

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
