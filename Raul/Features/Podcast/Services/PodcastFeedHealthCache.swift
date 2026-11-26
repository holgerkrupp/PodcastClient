import Foundation
import SwiftData

/// The metadata fields that can change a release-pattern based "possibly
/// cancelled" verdict. A feed refresh or a newly committed episode advances
/// `lastRefresh`/`feedUpdateCheckDate`, so an unchanged revision means the
/// cached verdict is still valid (apart from time passing, which
/// `PodcastFeedHealthCache.maximumEntryAge` bounds).
struct PodcastFeedHealthRevision: Hashable, Sendable {
    let lastRefresh: Date?
    let feedUpdateCheckDate: Date?
    let feedUpdated: Bool?
    let isSubscribed: Bool

    init(lastRefresh: Date?, feedUpdateCheckDate: Date?, feedUpdated: Bool?, isSubscribed: Bool) {
        self.lastRefresh = lastRefresh
        self.feedUpdateCheckDate = feedUpdateCheckDate
        self.feedUpdated = feedUpdated
        self.isSubscribed = isSubscribed
    }

    init(metadata: PodcastMetaData) {
        self.init(
            lastRefresh: metadata.lastRefresh,
            feedUpdateCheckDate: metadata.feedUpdateCheckDate,
            feedUpdated: metadata.feedUpdated,
            isSubscribed: metadata.isSubscribed
        )
    }
}

struct PodcastFeedHealthEntry: Equatable, Sendable {
    let revision: PodcastFeedHealthRevision
    let evaluatedAt: Date
    /// Only the release-pattern based verdict is cached. Stored-failure
    /// verdicts are cheap scalar checks the row performs itself.
    let likelyCancelled: PodcastFeedAbandonmentAssessment?

    func isReusable(for revision: PodcastFeedHealthRevision, now: Date) -> Bool {
        self.revision == revision
            && evaluatedAt <= now
            && now.timeIntervalSince(evaluatedAt) < PodcastFeedHealthCache.maximumEntryAge
    }
}

/// Non-persisted cache of release-pattern feed health for Library rows.
///
/// Rows must never run `PodcastReleasePredictor.releasePattern` (an Episode
/// fetch) while SwiftUI builds them. The Library list asks this cache to
/// evaluate once per load/refresh on a background `ModelContext`; rows then
/// read the small value result. Nothing here is written to SharedDatabase or
/// UserState.
@MainActor
final class PodcastFeedHealthCache {
    static let shared = PodcastFeedHealthCache()
    /// Bounds how long time passing alone can go unnoticed for the
    /// "possibly cancelled" verdict.
    nonisolated static let maximumEntryAge: TimeInterval = 6 * 60 * 60

    private(set) var entries: [PersistentIdentifier: PodcastFeedHealthEntry] = [:]
    private var runningTask: Task<Void, Never>?
    private var rerunRequested = false

    var likelyCancelledAssessments: [PersistentIdentifier: PodcastFeedAbandonmentAssessment] {
        entries.compactMapValues(\.likelyCancelled)
    }

    func likelyCancelledAssessment(for podcastID: PersistentIdentifier) -> PodcastFeedAbandonmentAssessment? {
        entries[podcastID]?.likelyCancelled
    }

    /// Re-evaluates podcasts whose revision changed (or whose entry aged out)
    /// off the main actor. Concurrent calls coalesce into at most one extra
    /// pass. Returns the current likely-cancelled verdicts.
    @discardableResult
    func refresh(modelContainer: ModelContainer) async -> [PersistentIdentifier: PodcastFeedAbandonmentAssessment] {
        if let runningTask {
            rerunRequested = true
            await runningTask.value
            return likelyCancelledAssessments
        }

        let task = Task { @MainActor in
            repeat {
                rerunRequested = false
                let previous = entries
                let updated = await Task.detached(priority: .utility) {
                    let context = ModelContext(modelContainer)
                    return Self.evaluateEntries(in: context, previous: previous, now: Date())
                }.value
                if let updated {
                    entries = updated
                }
            } while rerunRequested
        }
        runningTask = task
        await task.value
        runningTask = nil
        return likelyCancelledAssessments
    }

    /// Evaluates every podcast in `context`, reusing unchanged entries.
    /// `assess` is injectable for tests; by default it runs the bounded
    /// release-pattern fetch on `context` (never the UI context).
    nonisolated static func evaluateEntries(
        in context: ModelContext,
        previous: [PersistentIdentifier: PodcastFeedHealthEntry],
        now: Date,
        assess: (Podcast, PodcastMetaData, Date) -> PodcastFeedAbandonmentAssessment? = defaultAssessment
    ) -> [PersistentIdentifier: PodcastFeedHealthEntry]? {
        var descriptor = FetchDescriptor<Podcast>()
        descriptor.relationshipKeyPathsForPrefetching = [\Podcast.metaData]
        guard let podcasts = try? context.fetch(descriptor) else { return nil }

        var result: [PersistentIdentifier: PodcastFeedHealthEntry] = [:]
        result.reserveCapacity(podcasts.count)
        for podcast in podcasts {
            guard let metadata = podcast.metaData else { continue }
            let id = podcast.persistentModelID
            let revision = PodcastFeedHealthRevision(metadata: metadata)
            if let existing = previous[id], existing.isReusable(for: revision, now: now) {
                result[id] = existing
                continue
            }
            result[id] = PodcastFeedHealthEntry(
                revision: revision,
                evaluatedAt: now,
                likelyCancelled: revision.isSubscribed ? assess(podcast, metadata, now) : nil
            )
        }
        return result
    }

    nonisolated static func defaultAssessment(
        podcast: Podcast,
        metadata: PodcastMetaData,
        now: Date
    ) -> PodcastFeedAbandonmentAssessment? {
        // A sustained terminal failure is shown by the row's own scalar check.
        guard PodcastFeedAbandonmentAssessment.unavailableFeedAssessment(metadata: metadata, now: now) == nil,
              let pattern = PodcastReleasePredictor.releasePattern(
                for: podcast,
                before: now,
                allowRelationshipFallback: true
              ) else {
            return nil
        }
        return PodcastFeedAbandonmentAssessment.likelyCancelledAssessment(
            metadata: metadata,
            pattern: pattern,
            now: now
        )
    }
}
