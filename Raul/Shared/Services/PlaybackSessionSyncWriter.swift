import Foundation
import SwiftData

/// What one device was last doing with the player. Syncs through UserState so
/// another device can follow along while it is paused.
struct PlaybackSessionSnapshot: Codable, Sendable, Equatable {
    let identity: EpisodeStableIdentity
    let episodeURL: String
    let position: Double
    let isPlaying: Bool
}

struct RemotePlaybackSession: Sendable, Equatable {
    let episodeURL: String
    let position: Double
    let isPlaying: Bool
    let updatedAt: Date
}

enum PlaybackSessionSyncPolicy {
    private static let handledThroughKey = "playbackSession.handledThrough"

    /// Newest session this device published or already followed. Keeping it in
    /// defaults covers a publish still waiting in the outbox, which the store
    /// cannot show yet.
    @MainActor
    static var handledThrough: Date? {
        get { UserDefaults.standard.object(forKey: handledThroughKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: handledThroughKey) }
    }

    static func shouldFollow(_ session: RemotePlaybackSession, handledThrough: Date?) -> Bool {
        guard let handledThrough else { return true }
        return session.updatedAt > handledThrough
    }

    /// Each device owns one row, so devices never compete for the same record.
    static func newestRemoteSession(
        in container: ModelContainer,
        excludingDeviceID deviceID: String
    ) -> RemotePlaybackSession? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PlaybackSessionSync>(
            predicate: #Predicate { $0.id != deviceID },
            sortBy: [SortDescriptor(\PlaybackSessionSync.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return nil }
        return RemotePlaybackSession(
            episodeURL: row.episodeURL,
            position: row.position,
            isPlaying: row.isPlaying,
            updatedAt: row.updatedAt
        )
    }
}

@ModelActor
actor PlaybackSessionSyncWriter {
    func upsert(
        _ snapshot: PlaybackSessionSnapshot,
        at date: Date,
        deviceID: String = ListeningDeviceIdentity.current().id,
        save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        do {
            var descriptor = FetchDescriptor<PlaybackSessionSync>(
                predicate: #Predicate { $0.id == deviceID }
            )
            descriptor.fetchLimit = 1
            if let row = try modelContext.fetch(descriptor).first {
                // A queued snapshot can drain after a newer direct write.
                guard date >= row.updatedAt else { return }
                row.feedURL = snapshot.identity.feedURL
                row.episodeID = snapshot.identity.episodeID
                row.episodeURL = snapshot.episodeURL
                row.position = snapshot.position
                row.isPlaying = snapshot.isPlaying
                row.updatedAt = date
            } else {
                modelContext.insert(PlaybackSessionSync(deviceID: deviceID, snapshot: snapshot, updatedAt: date))
            }
            if modelContext.hasChanges { try save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
