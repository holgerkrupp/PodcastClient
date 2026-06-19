import Foundation
import SwiftData

struct StoreSplitListeningHistorySnapshot: Sendable {
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

@ModelActor
actor StoreSplitListeningHistorySyncWriter {
    func upsert(_ snapshot: StoreSplitListeningHistorySnapshot) {
        let historyID = snapshot.id
        let descriptor = FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate<ListeningHistorySync> { $0.id == historyID }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            guard snapshot.endedAt >= record.updatedAt else { return }
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
        modelContext.saveIfNeeded()
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
        record.updatedAt = snapshot.endedAt
    }
}
