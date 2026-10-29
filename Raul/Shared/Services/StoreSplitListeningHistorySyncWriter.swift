import Foundation
import SwiftData

struct StoreSplitListeningHistorySnapshot: Codable, Sendable {
    let id: String
    let identity: EpisodeStableIdentity
    let podcastName: String
    let episodeTitle: String
    let sourceDeviceID: String
    let sourceDeviceName: String?
    let deviceModel: String?
    let startedAt: Date
    let endedAt: Date
    let startPosition: Double
    let endPosition: Double
    let listenedSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let endedCleanly: Bool
}

struct StoreSplitListeningHistoryWriterIO: Sendable {
    var fetch: @Sendable (ModelContext, String) throws -> ListeningHistorySync? = { context, id in
        var descriptor = FetchDescriptor<ListeningHistorySync>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    var save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
}

@ModelActor
actor StoreSplitListeningHistorySyncWriter {
    /// Sessions are the only thing this writer publishes.
    ///
    /// It also used to maintain per-device, per-period rollups in the synced
    /// store. Those were derived from exactly these rows, which forced every
    /// reader to reconcile an aggregate against the sessions it came from — and
    /// both double-counting defects lived in that reconciliation. Readers
    /// aggregate the sessions themselves now, so there is nothing to reconcile.
    func upsert(_ snapshot: StoreSplitListeningHistorySnapshot, io: StoreSplitListeningHistoryWriterIO = .init()) throws {
        try upsert([snapshot], io: io)
    }

    func upsert(_ snapshots: [StoreSplitListeningHistorySnapshot], io: StoreSplitListeningHistoryWriterIO = .init()) throws {
        do {
            for snapshot in snapshots {
                try upsertWithoutSaving(snapshot, io: io)
            }
            if modelContext.hasChanges { try io.save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func upsertWithoutSaving(
        _ snapshot: StoreSplitListeningHistorySnapshot,
        io: StoreSplitListeningHistoryWriterIO
    ) throws {
        let historyID = snapshot.id
        if let record = try io.fetch(modelContext, historyID) {
            guard snapshot.endedAt > record.updatedAt else { return }
            apply(snapshot, to: record)
        } else {
            modelContext.insert(
                ListeningHistorySync(
                    id: snapshot.id,
                    feedURL: snapshot.identity.feedURL,
                    episodeID: snapshot.identity.episodeID,
                    podcastName: snapshot.podcastName,
                    episodeTitle: snapshot.episodeTitle,
                    sourceDeviceID: snapshot.sourceDeviceID,
                    sourceDeviceName: snapshot.sourceDeviceName,
                    deviceModel: snapshot.deviceModel,
                    startedAt: snapshot.startedAt,
                    endedAt: snapshot.endedAt,
                    startPosition: snapshot.startPosition,
                    endPosition: snapshot.endPosition,
                    listenedSeconds: snapshot.listenedSeconds,
                    silenceGapTimeSavedSeconds: snapshot.silenceGapTimeSavedSeconds,
                    playbackRateTimeSavedSeconds: snapshot.playbackRateTimeSavedSeconds,
                    endedCleanly: snapshot.endedCleanly,
                    updatedAt: snapshot.endedAt
                )
            )
        }
    }

    private func apply(
        _ snapshot: StoreSplitListeningHistorySnapshot,
        to record: ListeningHistorySync
    ) {
        record.feedURL = snapshot.identity.feedURL
        record.episodeID = snapshot.identity.episodeID
        record.podcastName = snapshot.podcastName
        record.episodeTitle = snapshot.episodeTitle
        record.sourceDeviceID = snapshot.sourceDeviceID
        record.sourceDeviceName = snapshot.sourceDeviceName
        record.deviceModel = snapshot.deviceModel
        record.startedAt = snapshot.startedAt
        record.endedAt = snapshot.endedAt
        record.startPosition = snapshot.startPosition
        record.endPosition = snapshot.endPosition
        record.listenedSeconds = snapshot.listenedSeconds
        record.silenceGapTimeSavedSeconds = snapshot.silenceGapTimeSavedSeconds
        record.playbackRateTimeSavedSeconds = snapshot.playbackRateTimeSavedSeconds
        record.endedCleanly = snapshot.endedCleanly
        // `isLegacyMigrated` is deliberately not reset. A migrated row's seconds
        // are already inside the frozen `ListeningBaselineSync` figure, and
        // nothing ever subtracts from that; clearing the flag here would let the
        // same listening time be counted a second time by every reader that adds
        // the baseline to the live sessions.
        record.updatedAt = snapshot.endedAt
    }
}
