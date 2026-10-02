import Foundation

/// Short-lived handoff between playback-time detection and chapter generation.
/// The generated Marker stores the audio-variant identity; raw audio and detector
/// observations are never persisted here.
actor AdDetectionResultsStore {
    static let shared = AdDetectionResultsStore()

    private var snapshots: [String: AdDetectionSnapshot] = [:]
    private let maximumSnapshots = 16

    func store(_ snapshot: AdDetectionSnapshot) {
        snapshots[snapshot.episodeIdentity] = snapshot
        if snapshots.count > maximumSnapshots {
            let oldest = snapshots
                .min { $0.value.updatedAt < $1.value.updatedAt }?.key
            if let oldest { snapshots.removeValue(forKey: oldest) }
        }
    }

    func segments(for episodeIdentity: String) -> [AdSegment] {
        snapshots[episodeIdentity]?.segments ?? []
    }

    func remove(episodeIdentity: String) {
        snapshots.removeValue(forKey: episodeIdentity)
    }
}
