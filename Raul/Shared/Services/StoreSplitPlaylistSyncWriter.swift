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
    let autoDownloadEnabled: Bool
    let autoDownloadEpisodeLimit: Int?
    let removesEpisodesPlayedElsewhere: Bool
    let entries: [StoreSplitPlaylistEntrySnapshot]
    let capturedAt: Date

    init(
        id: String,
        title: String,
        symbolName: String,
        sortIndex: Int,
        kindRawValue: String,
        smartFilterRawValue: String?,
        isHidden: Bool,
        autoDownloadEnabled: Bool,
        autoDownloadEpisodeLimit: Int?,
        removesEpisodesPlayedElsewhere: Bool,
        entries: [StoreSplitPlaylistEntrySnapshot],
        capturedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.kindRawValue = kindRawValue
        self.smartFilterRawValue = smartFilterRawValue
        self.isHidden = isHidden
        self.autoDownloadEnabled = autoDownloadEnabled
        self.autoDownloadEpisodeLimit = autoDownloadEpisodeLimit
        self.removesEpisodesPlayedElsewhere = removesEpisodesPlayedElsewhere
        self.entries = entries
        self.capturedAt = capturedAt
    }
}

extension Playlist {
    var storeSplitSyncID: String {
        if title == Self.defaultQueueTitle {
            return Self.defaultQueueSyncID
        }
        if let syncID = syncID?.trimmingCharacters(in: .whitespacesAndNewlines),
           syncID.isEmpty == false {
            return syncID
        }
        return id.uuidString
    }

    var storeSplitSnapshot: StoreSplitPlaylistSnapshot {
        let smartFilterRawValue = smartFilter
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        var seenEpisodeIdentities = Set<String>()
        let entries = ordered.compactMap { entry -> StoreSplitPlaylistEntrySnapshot? in
            guard let episode = entry.episode else { return nil }
            let identity = episode.stableEpisodeIdentity
            guard seenEpisodeIdentities.insert(identity.key).inserted else {
                return nil
            }
            return StoreSplitPlaylistEntrySnapshot(
                identity: identity,
                sortIndex: seenEpisodeIdentities.count - 1,
                addedAt: entry.dateAdded ?? .now
            )
        }
        return StoreSplitPlaylistSnapshot(
            id: storeSplitSyncID,
            title: title,
            symbolName: symbolName,
            sortIndex: sortIndex,
            kindRawValue: kindRawValue,
            smartFilterRawValue: smartFilterRawValue,
            isHidden: hidden,
            autoDownloadEnabled: autoDownloadEnabled,
            autoDownloadEpisodeLimit: resolvedAutoDownloadEpisodeLimit,
            removesEpisodesPlayedElsewhere: removesEpisodesPlayedElsewhere,
            entries: entries
        )
    }
}

/// Creates a value-only snapshot from a fresh, context-owned playlist fetch.
/// Entry order comes from SQLite; no `Playlist.items` relationship sorting or
/// model access occurs after this function returns.
enum StoreSplitPlaylistSnapshotBuilder {
    static func build(playlistID: UUID, in context: ModelContext) throws -> StoreSplitPlaylistSnapshot? {
        let playlistDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == playlistID }
        )
        guard let playlist = try context.fetch(playlistDescriptor).first else { return nil }
        let smartFilterRawValue = playlist.smartFilter
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let entryDescriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { $0.playlist?.id == playlistID },
            sortBy: [
                SortDescriptor(\.order, order: .forward),
                SortDescriptor(\.dateAdded, order: .forward)
            ]
        )
        var seen = Set<String>()
        let entries = try context.fetch(entryDescriptor).compactMap { entry -> StoreSplitPlaylistEntrySnapshot? in
            guard let episode = entry.episode else { return nil }
            let identity = episode.stableEpisodeIdentity
            guard seen.insert(identity.key).inserted else { return nil }
            return StoreSplitPlaylistEntrySnapshot(
                identity: identity,
                sortIndex: seen.count - 1,
                addedAt: entry.dateAdded ?? .now
            )
        }
        let configuredSyncID = playlist.syncID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let syncID = playlist.title == Playlist.defaultQueueTitle
            ? Playlist.defaultQueueSyncID
            : ((configuredSyncID?.isEmpty == false ? configuredSyncID : nil) ?? playlist.id.uuidString)
        CrashBreadcrumbs.shared.record(
            "store_split_playlist_snapshot_built",
            details: "entries=\(entries.count)"
        )
        return StoreSplitPlaylistSnapshot(
            id: syncID,
            title: playlist.title,
            symbolName: playlist.symbolName,
            sortIndex: playlist.sortIndex,
            kindRawValue: playlist.kindRawValue,
            smartFilterRawValue: smartFilterRawValue,
            isHidden: playlist.hidden,
            autoDownloadEnabled: playlist.autoDownloadEnabled,
            autoDownloadEpisodeLimit: playlist.resolvedAutoDownloadEpisodeLimit,
            removesEpisodesPlayedElsewhere: playlist.removesEpisodesPlayedElsewhere,
            entries: entries
        )
    }
}

@MainActor
enum StoreSplitPlaylistSyncCoordinator {
    static func publish(_ playlist: Playlist) {
        guard let container = ModelContainerManager.shared.preparedContainer,
              let snapshot = try? StoreSplitPlaylistSnapshotBuilder.build(
                  playlistID: playlist.id,
                  in: ModelContext(container)
              ) else { return }
        Task {
            await ModelContainerManager.shared.prepareSplitStores()
            guard let container = ModelContainerManager.shared.preparedUserStateContainer else {
                return
            }
            await StoreSplitPlaylistSyncWriter(modelContainer: container).upsert(snapshot)
        }
    }

    static func tombstone(playlistID: String) {
        Task {
            await ModelContainerManager.shared.prepareSplitStores()
            guard let container = ModelContainerManager.shared.preparedUserStateContainer else {
                return
            }
            await StoreSplitPlaylistSyncWriter(modelContainer: container)
                .tombstonePlaylist(id: playlistID)
        }
    }
}

@ModelActor
actor StoreSplitPlaylistSyncWriter {
    func upsert(
        _ snapshot: StoreSplitPlaylistSnapshot,
        at requestedDate: Date? = nil,
        authoritative: Bool = false
    ) {
        let date = requestedDate ?? snapshot.capturedAt
        let deviceID = ListeningDeviceIdentity.current().id
        let playlistID = snapshot.id
        let playlistDescriptor = FetchDescriptor<PlaylistSync>(
            predicate: #Predicate<PlaylistSync> { $0.id == playlistID }
        )
        if let playlist = try? modelContext.fetch(playlistDescriptor).first {
            // A suspended older publisher must never replace a newer committed
            // local playlist snapshot when its task resumes later.
            if authoritative == false, playlist.updatedAt > date { return }
            playlist.title = snapshot.title
            playlist.symbolName = snapshot.symbolName
            playlist.sortIndex = snapshot.sortIndex
            playlist.kindRawValue = snapshot.kindRawValue
            playlist.smartFilterRawValue = snapshot.smartFilterRawValue
            playlist.isHidden = snapshot.isHidden
            playlist.autoDownloadEnabled = snapshot.autoDownloadEnabled
            playlist.autoDownloadEpisodeLimit = snapshot.autoDownloadEpisodeLimit
            playlist.removesEpisodesPlayedElsewhere =
                snapshot.removesEpisodesPlayedElsewhere
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
                    autoDownloadEnabled: snapshot.autoDownloadEnabled,
                    autoDownloadEpisodeLimit: snapshot.autoDownloadEpisodeLimit,
                    removesEpisodesPlayedElsewhere:
                        snapshot.removesEpisodesPlayedElsewhere,
                    updatedAt: date,
                    sourceDeviceID: deviceID
                )
            )
        }

        let fetchedEntries = (try? modelContext.fetch(
            FetchDescriptor<PlaylistEntrySync>(
                predicate: #Predicate<PlaylistEntrySync> {
                    $0.playlistID == playlistID
                }
            )
        )) ?? []
        var existingEntries = consolidateEntries(
            fetchedEntries,
            id: \.id
        )
        let fetchedQueueEntries = snapshot.title == Playlist.defaultQueueTitle
            ? ((try? modelContext.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
            : []
        var existingQueueEntries = consolidateEntries(
            fetchedQueueEntries,
            id: \.id
        )
        var activeEntryIDs = Set<String>()
        var activeQueueIDs = Set<String>()
        for entrySnapshot in snapshot.entries {
            let entryID = StableIdentityKey.make(
                snapshot.id,
                entrySnapshot.identity.feedURL,
                entrySnapshot.identity.episodeID
            )
            activeEntryIDs.insert(entryID)
            if let entry = existingEntries[entryID] {
                if shouldPreserveTombstone(
                    isDeleted: entry.isDeleted,
                    deletedAt: entry.deletedAt,
                    snapshotAddedAt: entrySnapshot.addedAt
                ) {
                    continue
                }
                entry.sortIndex = entrySnapshot.sortIndex
                entry.addedAt = entrySnapshot.addedAt
                entry.isDeleted = false
                entry.deletedAt = nil
                entry.updatedAt = date
                entry.sourceDeviceID = deviceID
            } else {
                let entry = PlaylistEntrySync(
                        playlistID: snapshot.id,
                        feedURL: entrySnapshot.identity.feedURL,
                        episodeID: entrySnapshot.identity.episodeID,
                        sortIndex: entrySnapshot.sortIndex,
                        addedAt: entrySnapshot.addedAt,
                        updatedAt: date,
                        sourceDeviceID: deviceID
                    )
                modelContext.insert(entry)
                existingEntries[entryID] = entry
            }

            if snapshot.title == Playlist.defaultQueueTitle {
                let queueID = entrySnapshot.identity.key
                activeQueueIDs.insert(queueID)
                if let queueEntry = existingQueueEntries[queueID] {
                    if shouldPreserveTombstone(
                        isDeleted: queueEntry.isDeleted,
                        deletedAt: queueEntry.deletedAt,
                        snapshotAddedAt: entrySnapshot.addedAt
                    ) {
                        continue
                    }
                    queueEntry.sortIndex = entrySnapshot.sortIndex
                    queueEntry.addedAt = entrySnapshot.addedAt
                    queueEntry.isDeleted = false
                    queueEntry.deletedAt = nil
                    queueEntry.updatedAt = date
                    queueEntry.sourceDeviceID = deviceID
                } else {
                    let queueEntry = QueueEntrySync(
                            feedURL: entrySnapshot.identity.feedURL,
                            episodeID: entrySnapshot.identity.episodeID,
                            sortIndex: entrySnapshot.sortIndex,
                            addedAt: entrySnapshot.addedAt,
                            updatedAt: date,
                            sourceDeviceID: deviceID
                        )
                    modelContext.insert(queueEntry)
                    existingQueueEntries[queueID] = queueEntry
                }
            }
        }

        if authoritative {
            for (id, entry) in existingEntries where activeEntryIDs.contains(id) == false {
                entry.isDeleted = true
                entry.deletedAt = date
                entry.updatedAt = date
                entry.sourceDeviceID = deviceID
            }
            for (id, entry) in existingQueueEntries where activeQueueIDs.contains(id) == false {
                entry.isDeleted = true
                entry.deletedAt = date
                entry.updatedAt = date
                entry.sourceDeviceID = deviceID
            }
        }

        modelContext.saveIfNeeded()
    }

    /// A snapshot is a projection of one device's local playlist, so it can be
    /// older than a removal that already reached this store — from another device
    /// via CloudKit, or from a dequeue whose tombstone landed while this publish
    /// was in flight. Clearing the tombstone in that case is what put finished
    /// episodes back at the top of Up Next, so an entry may only revive a
    /// tombstone when it was demonstrably added *after* the removal.
    private func shouldPreserveTombstone(
        isDeleted: Bool,
        deletedAt: Date?,
        snapshotAddedAt: Date
    ) -> Bool {
        guard isDeleted || deletedAt != nil else { return false }
        guard let deletedAt else { return false }
        return snapshotAddedAt <= deletedAt
    }

    private func consolidateEntries<Model: PersistentModel>(
        _ records: [Model],
        id: KeyPath<Model, String>
    ) -> [String: Model] {
        var result: [String: Model] = [:]
        for record in records {
            let recordID = record[keyPath: id]
            if result[recordID] == nil {
                result[recordID] = record
            } else {
                modelContext.delete(record)
            }
        }
        return result
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

struct StoreSplitPlaylistRepairResult: Sendable, Equatable {
    let playlistCount: Int
    let playlistEntryCount: Int
    let queueEntryCount: Int
    let missingRecordCount: Int

    var isComplete: Bool { missingRecordCount == 0 }
}

/// Repairs installs that were promoted to split-store reads before all of their
/// legacy playlists had been copied to UserState.sqlite. The rollout state is
/// intentionally not consulted: once an install is marked `newStoreReads`, the
/// normal migration no longer runs, which is exactly when this repair is needed.
///
/// Writes are additive/non-authoritative so a stale or empty legacy projection
/// on one device can never delete newer playlist records received from another.
actor StoreSplitPlaylistRepairService {
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
    }

    nonisolated static func repair(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) async -> StoreSplitPlaylistRepairResult {
        let service = StoreSplitPlaylistRepairService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        return await service.run()
    }

    private func run() async -> StoreSplitPlaylistRepairResult {
        let legacyContext = ModelContext(legacyContainer)
        let playlists = (try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? []
        var snapshots: [StoreSplitPlaylistSnapshot] = []
        for playlist in playlists where playlist.isSmartPlaylist == false {
            if let snapshot = try? StoreSplitPlaylistSnapshotBuilder.build(
                playlistID: playlist.id,
                in: legacyContext
            ) {
                snapshots.append(snapshot)
            }
        }

        let expectedPlaylistIDs = Set(snapshots.map(\.id))
        let expectedPlaylistEntryIDs = Set(snapshots.flatMap { snapshot in
            snapshot.entries.map { entry in
                StableIdentityKey.make(
                    snapshot.id,
                    entry.identity.feedURL,
                    entry.identity.episodeID
                )
            }
        })
        let expectedQueueEntryIDs = Set(snapshots
            .filter { $0.title == Playlist.defaultQueueTitle }
            .flatMap { $0.entries.map(\.identity.key) })

        let writer = StoreSplitPlaylistSyncWriter(modelContainer: userStateContainer)
        for snapshot in snapshots {
            await writer.upsert(snapshot, authoritative: false)
        }

        // Verify the persisted result rather than trusting `saveIfNeeded`, which
        // deliberately swallows SwiftData save errors in older call sites.
        let verificationContext = ModelContext(userStateContainer)
        let storedPlaylistIDs = Set(
            ((try? verificationContext.fetch(FetchDescriptor<PlaylistSync>())) ?? [])
                .filter { $0.isDeleted == false }
                .map(\.id)
        )
        let storedPlaylistEntryIDs = Set(
            ((try? verificationContext.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [])
                .filter { $0.isDeleted == false }
                .map(\.id)
        )
        let storedQueueEntryIDs = Set(
            ((try? verificationContext.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
                .filter { $0.isDeleted == false }
                .map(\.id)
        )
        let missingRecordCount = expectedPlaylistIDs.subtracting(storedPlaylistIDs).count
            + expectedPlaylistEntryIDs.subtracting(storedPlaylistEntryIDs).count
            + expectedQueueEntryIDs.subtracting(storedQueueEntryIDs).count

        return StoreSplitPlaylistRepairResult(
            playlistCount: expectedPlaylistIDs.count,
            playlistEntryCount: expectedPlaylistEntryIDs.count,
            queueEntryCount: expectedQueueEntryIDs.count,
            missingRecordCount: missingRecordCount
        )
    }
}
