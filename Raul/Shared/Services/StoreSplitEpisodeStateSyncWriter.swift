import Foundation
import SwiftData

struct StoreSplitEpisodeStateSnapshot: Codable, Sendable {
    let identity: EpisodeStableIdentity
    let playPosition: Double
    let maxPlayPosition: Double
    let duration: Double?
    let isPlayed: Bool
    let isArchived: Bool
    let wasSkipped: Bool
    let isSavedForLater: Bool
    let isFavorite: Bool
    let completedAt: Date?
    let archivedAt: Date?
    let firstPlayedAt: Date?
    let lastPlayedAt: Date?

    init(
        identity: EpisodeStableIdentity,
        playPosition: Double,
        maxPlayPosition: Double,
        duration: Double?,
        isPlayed: Bool,
        isArchived: Bool,
        wasSkipped: Bool,
        isSavedForLater: Bool = false,
        isFavorite: Bool = false,
        completedAt: Date?,
        archivedAt: Date?,
        firstPlayedAt: Date?,
        lastPlayedAt: Date?
    ) {
        self.identity = identity
        self.playPosition = playPosition
        self.maxPlayPosition = maxPlayPosition
        self.duration = duration
        self.isPlayed = isPlayed
        self.isArchived = isArchived
        self.wasSkipped = wasSkipped
        self.isSavedForLater = isSavedForLater
        self.isFavorite = isFavorite
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
    }

    private enum CodingKeys: String, CodingKey {
        case identity, playPosition, maxPlayPosition, duration, isPlayed, isArchived
        case wasSkipped, isSavedForLater, isFavorite, completedAt, archivedAt
        case firstPlayedAt, lastPlayedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(EpisodeStableIdentity.self, forKey: .identity)
        playPosition = try values.decode(Double.self, forKey: .playPosition)
        maxPlayPosition = try values.decode(Double.self, forKey: .maxPlayPosition)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        isPlayed = try values.decode(Bool.self, forKey: .isPlayed)
        isArchived = try values.decode(Bool.self, forKey: .isArchived)
        wasSkipped = try values.decode(Bool.self, forKey: .wasSkipped)
        isSavedForLater = try values.decodeIfPresent(Bool.self, forKey: .isSavedForLater) ?? false
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        firstPlayedAt = try values.decodeIfPresent(Date.self, forKey: .firstPlayedAt)
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }
}

struct StoreSplitEpisodeStateWriterIO: Sendable {
    var fetch: @Sendable (ModelContext, String) throws -> EpisodeStateSync? = { context, id in
        var descriptor = FetchDescriptor<EpisodeStateSync>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    var save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
}

@ModelActor
actor StoreSplitEpisodeStateSyncWriter {
    /// Returns whether the stored record actually changed, so callers can avoid
    /// dirtying the local row (and forcing a save) on a no-op republish.
    @discardableResult
    func upsert(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        at date: Date = .now,
        io: StoreSplitEpisodeStateWriterIO = .init()
    ) throws -> Bool {
        do {
            let didChange = try upsertWithoutSaving(snapshot, at: date, io: io)
            if modelContext.hasChanges { try io.save(modelContext) }
            return didChange
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func upsert(
        _ snapshots: [StoreSplitEpisodeStateSnapshot],
        at date: Date = .now,
        io: StoreSplitEpisodeStateWriterIO = .init()
    ) throws {
        do {
            for snapshot in snapshots {
                try upsertWithoutSaving(snapshot, at: date, io: io)
            }
            if modelContext.hasChanges { try io.save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    private func upsertWithoutSaving(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        at date: Date,
        io: StoreSplitEpisodeStateWriterIO
    ) throws -> Bool {
        let stateID = snapshot.identity.key
        let deviceID = ListeningDeviceIdentity.current().id
        if let state = try io.fetch(modelContext, stateID) {
            guard date >= state.updatedAt else { return false }
            guard isMaterialChange(snapshot, from: state) else { return false }
            apply(snapshot, to: state, at: date, deviceID: deviceID)
        } else {
            modelContext.insert(
                EpisodeStateSync(
                    feedURL: snapshot.identity.feedURL,
                    episodeID: snapshot.identity.episodeID,
                    playPosition: snapshot.playPosition,
                    maxPlayPosition: snapshot.maxPlayPosition,
                    duration: snapshot.duration,
                    isPlayed: snapshot.isPlayed,
                    isArchived: snapshot.isArchived,
                    wasSkipped: snapshot.wasSkipped,
                    isSavedForLater: snapshot.isSavedForLater,
                    isFavorite: snapshot.isFavorite,
                    completedAt: snapshot.completedAt,
                    archivedAt: snapshot.archivedAt,
                    firstPlayedAt: snapshot.firstPlayedAt,
                    lastPlayedAt: snapshot.lastPlayedAt,
                    updatedAt: date,
                    sourceDeviceID: deviceID
                )
            )
        }
        return true
    }

    /// Whether the snapshot differs from the stored record in a way worth an
    /// export. Playback position moves constantly, so an exact compare would
    /// still churn; anything under a couple of seconds is treated as unchanged.
    private func isMaterialChange(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        from state: EpisodeStateSync
    ) -> Bool {
        if abs(state.playPosition - snapshot.playPosition) >= 2 { return true }
        if abs(state.maxPlayPosition - snapshot.maxPlayPosition) >= 2 { return true }
        return state.isPlayed != snapshot.isPlayed
            || state.isArchived != snapshot.isArchived
            || state.wasSkipped != snapshot.wasSkipped
            || state.isSavedForLater != snapshot.isSavedForLater
            || state.isFavorite != snapshot.isFavorite
            || state.completedAt != snapshot.completedAt
            || state.archivedAt != snapshot.archivedAt
            || state.firstPlayedAt != snapshot.firstPlayedAt
            || state.lastPlayedAt != snapshot.lastPlayedAt
            || state.duration != snapshot.duration
    }

    private func apply(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        to state: EpisodeStateSync,
        at date: Date,
        deviceID: String
    ) {
        state.feedURL = snapshot.identity.feedURL
        state.episodeID = snapshot.identity.episodeID
        state.playPosition = snapshot.playPosition
        state.maxPlayPosition = snapshot.maxPlayPosition
        state.duration = snapshot.duration
        state.isPlayed = snapshot.isPlayed
        state.isArchived = snapshot.isArchived
        state.wasSkipped = snapshot.wasSkipped
        state.isSavedForLater = snapshot.isSavedForLater
        state.isFavorite = snapshot.isFavorite
        state.completedAt = snapshot.completedAt
        state.archivedAt = snapshot.archivedAt
        state.firstPlayedAt = snapshot.firstPlayedAt
        state.lastPlayedAt = snapshot.lastPlayedAt
        state.updatedAt = date
        state.sourceDeviceID = deviceID
    }
}
