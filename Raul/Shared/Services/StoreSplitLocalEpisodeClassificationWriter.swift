import Foundation
import SwiftData

struct StoreSplitLocalEpisodeClassificationSnapshot: Sendable {
    let identity: EpisodeStableIdentity
    let isInbox: Bool
    let statusRawValue: String?
    let systemSuppressionReasonRawValue: String?
}

/// Persists device-local episode classification directly in PodcastCache.
/// None of these fields belongs in UserState or CloudKit.
@ModelActor
actor StoreSplitLocalEpisodeClassificationWriter {
    func upsert(_ snapshots: [StoreSplitLocalEpisodeClassificationSnapshot]) {
        guard snapshots.isEmpty == false else { return }
        for snapshot in snapshots {
            let rowID = snapshot.identity.key
            var descriptor = FetchDescriptor<CachedEpisode>(
                predicate: #Predicate { $0.id == rowID }
            )
            descriptor.fetchLimit = 1
            let cached = (try? modelContext.fetch(descriptor).first)
                ?? matchingEpisode(snapshot.identity)
            guard let cached else { continue }
            cached.localIsInbox = snapshot.isInbox
            cached.localStatusRawValue = snapshot.statusRawValue
            cached.localSystemSuppressionReasonRawValue =
                snapshot.systemSuppressionReasonRawValue
            cached.updatedAt = .now
        }
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                CrashBreadcrumbs.shared.record(
                    "store_split_local_episode_classification_save_failed",
                    details: error.localizedDescription
                )
            }
        }
    }

    private func matchingEpisode(
        _ identity: EpisodeStableIdentity
    ) -> CachedEpisode? {
        let episodeID = identity.episodeID
        let candidates = (try? modelContext.fetch(FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.episodeID == episodeID }
        ))) ?? []
        guard let requestedURL = URL(string: identity.feedURL) else {
            return candidates.count == 1 ? candidates.first : nil
        }
        let requestedKeys = requestedURL.podcastFeedComparisonKeys
        return candidates.first { candidate in
            guard let candidateURL = URL(string: candidate.feedURL) else {
                return false
            }
            return candidateURL.podcastFeedComparisonKeys
                .isDisjoint(with: requestedKeys) == false
        }
    }
}
