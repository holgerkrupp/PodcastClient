import Foundation
import SwiftData

struct StoreSplitEpisodeStateSnapshot: Sendable {
    let identity: EpisodeStableIdentity
    let playPosition: Double
    let maxPlayPosition: Double
    let duration: Double?
    let isPlayed: Bool
    let isArchived: Bool
    let wasSkipped: Bool
    let completedAt: Date?
    let archivedAt: Date?
    let firstPlayedAt: Date?
    let lastPlayedAt: Date?
}

@ModelActor
actor StoreSplitEpisodeStateSyncWriter {
    /// Returns whether the stored record actually changed, so callers can avoid
    /// dirtying the local row (and forcing a save) on a no-op republish.
    @discardableResult
    func upsert(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        at date: Date = .now
    ) -> Bool {
        let didChange = upsertWithoutSaving(snapshot, at: date)
        modelContext.saveIfNeeded()
        return didChange
    }

    func upsert(
        _ snapshots: [StoreSplitEpisodeStateSnapshot],
        at date: Date = .now
    ) {
        for snapshot in snapshots {
            upsertWithoutSaving(snapshot, at: date)
        }
        modelContext.saveIfNeeded()
    }

    @discardableResult
    private func upsertWithoutSaving(
        _ snapshot: StoreSplitEpisodeStateSnapshot,
        at date: Date
    ) -> Bool {
        let stateID = snapshot.identity.key
        let descriptor = FetchDescriptor<EpisodeStateSync>(
            predicate: #Predicate<EpisodeStateSync> { $0.id == stateID }
        )
        let deviceID = ListeningDeviceIdentity.current().id
        if let state = try? modelContext.fetch(descriptor).first {
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
        state.completedAt = snapshot.completedAt
        state.archivedAt = snapshot.archivedAt
        state.firstPlayedAt = snapshot.firstPlayedAt
        state.lastPlayedAt = snapshot.lastPlayedAt
        state.updatedAt = date
        state.sourceDeviceID = deviceID
    }
}
