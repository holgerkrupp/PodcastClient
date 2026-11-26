import Foundation
import SwiftData

/// Chooses which subscribed library podcasts still need their first local feed
/// fetch.
///
/// Eligibility is derived from the durable local `Podcast`/`PodcastMetaData`
/// rows in `SharedDatabase.sqlite`, not from a separate store or in-memory
/// timestamps. A subscription stub that was created from UserState (or the
/// KVS manifest) but whose fetch was cancelled, offline, or interrupted by a
/// relaunch therefore stays eligible until a fetch succeeds. Failure backoff
/// uses the failure fields `PodcastModelActor` already records on the metadata.
///
/// This type only selects feeds; it never fetches, deletes or tombstones.
/// `ModelContainerManager.hydratePendingSubscriptions` owns execution.
enum SubscriptionHydrationScheduler {
    /// A successful fetch that produced no episodes (an empty feed) is not
    /// re-checked through this path more often than this.
    static let emptyFeedRecheckInterval: TimeInterval = 24 * 60 * 60
    static let baseFailureBackoff: TimeInterval = 15 * 60
    static let maximumFailureBackoff: TimeInterval = 6 * 60 * 60

    /// The durable facts the decision needs, copied off a model row.
    struct Candidate: Sendable, Equatable {
        var feed: URL
        var isSubscribed: Bool
        var credentialState: PodcastCredentialState
        var authenticationRetryAfter: Date?
        /// Last local check, successful or not (`feedUpdateCheckDate`).
        var lastLocalCheck: Date?
        var lastFailure: Date?
        var consecutiveFailures: Int
    }

    static func failureBackoff(consecutiveFailures: Int) -> TimeInterval {
        let exponent = min(10, max(0, consecutiveFailures - 1))
        return min(maximumFailureBackoff, baseFailureBackoff * pow(2, Double(exponent)))
    }

    /// Whether the timing and access state allow an attempt now. The episode
    /// count is checked separately because it needs a fetch.
    static func mayAttempt(
        _ candidate: Candidate,
        now: Date,
        ignoresFailureBackoff: Bool = false
    ) -> Bool {
        guard candidate.isSubscribed else { return false }
        switch candidate.credentialState {
        case .available:
            break
        case .needsLogin, .expired:
            // A recorded authentication failure retries only after its own
            // window, so a protected feed does not loop on 401s.
            guard let retryAfter = candidate.authenticationRetryAfter, now >= retryAfter else {
                return false
            }
        case .missing, .storageUnavailable, .revoked, .unsupported:
            // Waits for the credential; the importer re-queues it once present.
            return false
        }
        if let lastFailure = candidate.lastFailure {
            // Connectivity recovery and a user's Retry may skip the timing
            // backoff once; the credential checks above still apply.
            if ignoresFailureBackoff { return true }
            return now.timeIntervalSince(lastFailure)
                >= failureBackoff(consecutiveFailures: candidate.consecutiveFailures)
        }
        if let lastLocalCheck = candidate.lastLocalCheck {
            return now.timeIntervalSince(lastLocalCheck) >= emptyFeedRecheckInterval
        }
        return true
    }

    /// A podcast that has at least one episode has been fetched successfully
    /// at least once on this device (or arrived with the legacy library).
    static func isAwaitingFirstFetch(_ candidate: Candidate, episodeCount: Int, now: Date) -> Bool {
        episodeCount == 0 && mayAttempt(candidate, now: now)
    }

    /// The single selection point for subscription hydration.
    ///
    /// Returns at most `limit` feeds: never-fetched subscribed stubs that are due,
    /// ordered by reference priority (a feed the queue or a playlist needs comes
    /// first) and then by feed URL so repeated passes are deterministic, skipping
    /// any feed in `excluding` (already attempted by the current pass).
    static func dueFeeds(
        in container: ModelContainer,
        excluding: Set<String> = [],
        limit: Int,
        now: Date = .now,
        priorities: ReferencePriorities = ReferencePriorities(),
        ignoresFailureBackoff: Bool = false
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let context = ModelContext(container)
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        var seen = Set<String>()
        var due: [(key: String, feed: URL)] = []
        for podcast in podcasts {
            guard let feed = podcast.feed, let metadata = podcast.metaData else { continue }
            let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
            guard excluding.contains(key) == false, seen.insert(key).inserted else { continue }
            let candidate = Candidate(
                feed: feed,
                isSubscribed: metadata.isSubscribed,
                credentialState: metadata.credentialState,
                authenticationRetryAfter: metadata.authenticationRetryAfter,
                lastLocalCheck: metadata.feedUpdateCheckDate,
                lastFailure: metadata.lastFeedFailureDate,
                consecutiveFailures: metadata.consecutiveFeedFailureCount
            )
            // Cheap timing checks first; most library podcasts stop here.
            guard mayAttempt(candidate, now: now, ignoresFailureBackoff: ignoresFailureBackoff) else {
                continue
            }
            let podcastID = podcast.persistentModelID
            var countDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil && $0.podcast!.persistentModelID == podcastID }
            )
            countDescriptor.fetchLimit = 1
            guard let episodeCount = try? context.fetchCount(countDescriptor),
                  episodeCount == 0 else {
                continue
            }
            due.append((key, feed))
        }
        let rank = { (feed: URL) in priorities.priority(for: feed) ?? .subscriptionStub }
        return due
            .sorted { lhs, rhs in
                let left = rank(lhs.feed), right = rank(rhs.feed)
                return left == right ? lhs.key < rhs.key : left < right
            }
            .prefix(limit)
            .map(\.feed)
    }
}

// MARK: - Restore priority (#483)

extension SubscriptionHydrationScheduler {
    /// Which restore work a feed unblocks. Lower is fetched first.
    enum Priority: Int, Comparable, Sendable, CaseIterable {
        /// The episode another device was last playing (the resume target).
        case currentEpisode = 0
        /// The first few Up Next entries.
        case queueHead
        case queue
        case manualPlaylist
        /// A feed some other import asked for (bookmarks, state, history).
        case otherReference
        /// A subscription with no reference waiting on it.
        case subscriptionStub

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Feeds whose commit should publish queue/playlist membership at once.
        var unblocksPlaylistMembership: Bool { self <= .manualPlaylist }
    }

    static let queueHeadCount = 3

    /// Feed comparison keys mapped to the most urgent work that needs them.
    /// Built from portable identities only; holds no titles and is never logged.
    struct ReferencePriorities: Sendable, Equatable {
        private(set) var rankByKey: [String: Priority] = [:]

        init() {}

        /// - Parameters:
        ///   - currentFeeds: feeds of the resume target(s), newest first.
        ///   - queueFeedsInOrder: Up Next entry feeds in queue order.
        ///   - playlistFeeds: feeds of manual playlist entries.
        init(currentFeeds: [String], queueFeedsInOrder: [String], playlistFeeds: [String],
             queueHeadCount: Int = SubscriptionHydrationScheduler.queueHeadCount) {
            for feed in currentFeeds { insert(feed, .currentEpisode) }
            for (index, feed) in queueFeedsInOrder.enumerated() {
                insert(feed, index < queueHeadCount ? .queueHead : .queue)
            }
            for feed in playlistFeeds { insert(feed, .manualPlaylist) }
        }

        private mutating func insert(_ feed: String, _ priority: Priority) {
            guard let url = URL(string: feed) else { return }
            for key in url.podcastFeedComparisonKeys {
                if let existing = rankByKey[key], existing <= priority { continue }
                rankByKey[key] = priority
            }
        }

        func priority(for feed: URL) -> Priority? {
            feed.podcastFeedComparisonKeys.compactMap { rankByKey[$0] }.min()
        }

        var isEmpty: Bool { rankByKey.isEmpty }
    }

    /// Reads the portable references that decide restore order: the newest
    /// playback session, the default queue in order, then manual playlists.
    /// Bounded reads of UserState only; no network and no library scan.
    static func referencePriorities(userState: ModelContainer) -> ReferencePriorities {
        let context = ModelContext(userState)
        var sessions = FetchDescriptor<PlaybackSessionSync>(
            sortBy: [SortDescriptor(\PlaybackSessionSync.updatedAt, order: .reverse)]
        )
        sessions.fetchLimit = 2
        let currentFeeds = ((try? context.fetch(sessions)) ?? [])
            .map(\.feedURL).filter { $0.isEmpty == false }

        let queueID = Playlist.defaultQueueSyncID
        let queueEntries = ((try? context.fetch(FetchDescriptor<PlaylistEntrySync>(
            predicate: #Predicate<PlaylistEntrySync> {
                $0.playlistID == queueID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\PlaylistEntrySync.sortIndex)]
        ))) ?? []).filter { $0.isDeleted == false }
        let legacyQueueEntries = ((try? context.fetch(FetchDescriptor<QueueEntrySync>(
            predicate: #Predicate<QueueEntrySync> { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\QueueEntrySync.sortIndex)]
        ))) ?? []).filter { $0.isDeleted == false }
        var orderedQueue: [(index: Int, feed: String)] = queueEntries.map { (index: $0.sortIndex, feed: $0.feedURL) }
        orderedQueue.append(contentsOf: legacyQueueEntries.map { (index: $0.sortIndex, feed: $0.feedURL) })
        orderedQueue.sort { $0.index < $1.index }
        let queueFeeds: [String] = orderedQueue.map(\.feed)

        let playlistFeeds = ((try? context.fetch(FetchDescriptor<PlaylistEntrySync>(
            predicate: #Predicate<PlaylistEntrySync> {
                $0.playlistID != queueID && $0.deletedAt == nil
            }
        ))) ?? []).filter { $0.isDeleted == false }.map(\.feedURL)

        return ReferencePriorities(
            currentFeeds: currentFeeds,
            queueFeedsInOrder: queueFeeds,
            playlistFeeds: playlistFeeds
        )
    }

    /// Orders explicitly requested feeds: by priority, then by key. A request
    /// with no portable reference ranks as `otherReference`, ahead of stubs.
    static func orderedRequests(
        _ requests: [(key: String, feed: URL)],
        priorities: ReferencePriorities
    ) -> [(key: String, feed: URL, priority: Priority)] {
        typealias Ranked = (key: String, feed: URL, priority: Priority)
        var ranked: [Ranked] = []
        for request in requests {
            let priority: Priority = priorities.priority(for: request.feed) ?? .otherReference
            ranked.append((key: request.key, feed: request.feed, priority: priority))
        }
        ranked.sort { (lhs: Ranked, rhs: Ranked) -> Bool in
            lhs.priority == rhs.priority ? lhs.key < rhs.key : lhs.priority < rhs.priority
        }
        return ranked
    }
}

// MARK: - Per-request backoff (#483)

extension SubscriptionHydrationScheduler {
    /// In-process backoff for explicitly requested feeds. Stubs use the durable
    /// failure fields instead. Grows for a failed fetch and for a fetch that
    /// succeeded but still did not contain the referenced episode.
    struct RequestBackoff: Sendable, Equatable {
        var failures: Int
        var retryAfter: Date

        static func next(after previous: RequestBackoff?, now: Date) -> RequestBackoff {
            let failures = (previous?.failures ?? 0) + 1
            return RequestBackoff(
                failures: failures,
                retryAfter: now.addingTimeInterval(failureBackoff(consecutiveFailures: failures))
            )
        }

        /// Held while an attempt is in flight or just finished, so a repeated
        /// trigger cannot fetch the same feed again right away.
        static func attempt(previous: RequestBackoff?, now: Date) -> RequestBackoff {
            RequestBackoff(
                failures: previous?.failures ?? 0,
                retryAfter: max(previous?.retryAfter ?? now, now.addingTimeInterval(baseFailureBackoff))
            )
        }
    }
}

// MARK: - Bounded worker pool (#483)

extension SubscriptionHydrationScheduler {
    /// Foreground restore overlaps up to this many feed fetches. SwiftData
    /// writes stay serialized by `PodcastFeedCommitCoordinator`.
    static func foregroundConcurrency() -> Int {
        min(4, max(1, PodcastModelActor.maximumConcurrentRefreshes))
    }

    /// Runs `operation` for items pulled from `next`, at most `maxConcurrent` at
    /// a time. A slot is refilled as soon as any item finishes, so a slow,
    /// unauthorized or malformed feed occupies one slot and never blocks the
    /// others. `next` is consulted on each refill, so higher-priority work that
    /// arrives mid-run is picked up before older, lower-priority work.
    /// Stops pulling once `shouldContinue` is false; in-flight work is cancelled.
    @MainActor
    static func runBounded<Item: Sendable, Outcome: Sendable>(
        maxConcurrent: Int,
        next: () async -> Item?,
        shouldContinue: () -> Bool,
        operation: @escaping @Sendable (Item) async -> Outcome,
        completed: (Item, Outcome) async -> Void
    ) async {
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (Item, Outcome).self) { group in
            var inFlight = 0
            while true {
                while inFlight < limit, shouldContinue(), let item = await next() {
                    group.addTask { (item, await operation(item)) }
                    inFlight += 1
                }
                if shouldContinue() == false { group.cancelAll() }
                guard inFlight > 0, let finished = await group.next() else { break }
                inFlight -= 1
                await completed(finished.0, finished.1)
            }
        }
    }
}
