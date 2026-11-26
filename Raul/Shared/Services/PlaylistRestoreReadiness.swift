import Foundation
import Network
import Observation
import os
import SwiftData

// MARK: - Readiness value (#443, #483)

/// Why some saved playlist entries are not on this device yet, when nothing is
/// actively restoring them.
enum PlaylistRestoreBlocker: Sendable, Equatable {
    case offline
    case needsLogin
    case unavailable
}

/// What a Queue or manual playlist can honestly say about its synced entries.
///
/// Derived from existing state only: portable references in UserState, the
/// local projection, library feed facts and the hydration monitor. It never
/// decides membership; unresolved references stay authoritative in UserState.
enum PlaylistRestoreReadiness: Sendable, Equatable {
    /// No saved entries anywhere: show the ordinary empty state.
    case empty
    /// Another device reported entries, but none have arrived here yet.
    case waitingForICloud
    /// Feeds for unresolved entries are being fetched or are about to be.
    case restoring(resolved: Int, total: Int)
    /// Nothing is fetching right now and some entries are still missing.
    case partial(resolved: Int, total: Int, blocker: PlaylistRestoreBlocker)
    case complete

    struct Inputs: Sendable, Equatable {
        /// Active portable references for this playlist (deduplicated).
        var referenceCount = 0
        /// Entries shown by the local projection.
        var resolvedCount = 0
        /// Entry count another device published, if known (default queue only).
        var cloudReferenceCount: Int?
        var awaitingInitialImport = false
        /// Referenced feeds not fetched yet and allowed to fetch.
        var pendingFeedCount = 0
        /// Referenced feeds waiting for a sign-in on this device.
        var loginFeedCount = 0
        /// Referenced feeds whose fetch failed and has not succeeded since.
        var failedFeedCount = 0
        var isHydrating = false
        var isOffline = false
    }

    static func derive(_ inputs: Inputs) -> PlaylistRestoreReadiness {
        let total = inputs.referenceCount
        let resolved = min(inputs.resolvedCount, total)
        if total == 0 {
            if inputs.resolvedCount > 0 { return .complete }
            if inputs.awaitingInitialImport || (inputs.cloudReferenceCount ?? 0) > 0 {
                return .waitingForICloud
            }
            return .empty
        }
        guard resolved < total else { return .complete }
        if inputs.isOffline, inputs.pendingFeedCount + inputs.failedFeedCount > 0 {
            return .partial(resolved: resolved, total: total, blocker: .offline)
        }
        if inputs.isHydrating || inputs.pendingFeedCount > 0 {
            return .restoring(resolved: resolved, total: total)
        }
        if inputs.loginFeedCount > 0 {
            return .partial(resolved: resolved, total: total, blocker: .needsLogin)
        }
        return .partial(resolved: resolved, total: total, blocker: .unavailable)
    }

    /// Whether the status deserves space in the list or empty state.
    var isVisible: Bool {
        switch self {
        case .empty, .complete: false
        case .waitingForICloud, .restoring, .partial: true
        }
    }
}

/// Facts about one playlist's referenced feeds, read off the main actor.
struct PlaylistRestoreFacts: Sendable, Equatable {
    var referenceCount = 0
    var pendingFeedCount = 0
    var loginFeedCount = 0
    var failedFeedCount = 0
    /// First referenced feed that needs a sign-in, for the repair link.
    var loginFeed: URL?
    /// Referenced feeds a targeted Retry should fetch again.
    var retryFeeds: [URL] = []

    /// Bounded reads: this playlist's UserState references and the library
    /// podcasts they name (one episode-count probe per distinct feed).
    static func read(
        playlistSyncID: String,
        includesLegacyQueueEntries: Bool,
        library: ModelContainer,
        userState: ModelContainer?
    ) -> PlaylistRestoreFacts {
        var facts = PlaylistRestoreFacts()
        guard let userState else { return facts }
        let stateContext = ModelContext(userState)
        var identities = Set<String>()
        var feedStrings: [String] = []
        var seenFeeds = Set<String>()
        func add(feedURL: String, episodeID: String) {
            guard identities.insert(StableIdentityKey.make(feedURL, episodeID)).inserted else { return }
            if seenFeeds.insert(feedURL).inserted { feedStrings.append(feedURL) }
        }
        let entries = (try? stateContext.fetch(FetchDescriptor<PlaylistEntrySync>(
            predicate: #Predicate<PlaylistEntrySync> {
                $0.playlistID == playlistSyncID && $0.deletedAt == nil
            }
        ))) ?? []
        for entry in entries where entry.isDeleted == false {
            add(feedURL: entry.feedURL, episodeID: entry.episodeID)
        }
        if includesLegacyQueueEntries {
            let queue = (try? stateContext.fetch(FetchDescriptor<QueueEntrySync>(
                predicate: #Predicate<QueueEntrySync> { $0.deletedAt == nil }
            ))) ?? []
            for entry in queue where entry.isDeleted == false {
                add(feedURL: entry.feedURL, episodeID: entry.episodeID)
            }
        }
        facts.referenceCount = identities.count
        guard feedStrings.isEmpty == false else { return facts }

        let libraryContext = ModelContext(library)
        let podcasts = (try? libraryContext.fetch(FetchDescriptor<Podcast>())) ?? []
        var podcastByKey: [String: Podcast] = [:]
        for podcast in podcasts {
            guard let feed = podcast.feed else { continue }
            for key in feed.podcastFeedComparisonKeys where podcastByKey[key] == nil {
                podcastByKey[key] = podcast
            }
        }
        for feedString in feedStrings {
            guard let feed = URL(string: feedString) else { continue }
            guard let podcast = feed.podcastFeedComparisonKeys.lazy
                .compactMap({ podcastByKey[$0] }).first else {
                // No local podcast: a subscribed feed gets its stub from the
                // importer, so this is usually an unsubscribed feed that only a
                // playlist references. Hydration fetches it on request; while
                // nothing runs, count it as not loaded (with Retry) rather than
                // as an indefinite "restoring".
                facts.failedFeedCount += 1
                facts.retryFeeds.append(feed)
                continue
            }
            let podcastID = podcast.persistentModelID
            var count = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil && $0.podcast!.persistentModelID == podcastID }
            )
            count.fetchLimit = 1
            let hasEpisodes = ((try? libraryContext.fetchCount(count)) ?? 0) > 0
            let metadata = podcast.metaData
            let credential = metadata?.credentialState ?? .available
            if hasEpisodes {
                // Fetched; a still-missing episode may appear on a re-fetch.
                facts.retryFeeds.append(podcast.feed ?? feed)
            } else if credential != .available, credential != .unsupported {
                facts.loginFeedCount += 1
                if facts.loginFeed == nil { facts.loginFeed = podcast.feed ?? feed }
            } else if metadata?.lastFeedFailureDate != nil || metadata?.feedUpdateCheckDate != nil {
                // Failed, or fetched successfully but still empty: nothing is
                // coming without another fetch, so never report "restoring".
                facts.failedFeedCount += 1
                facts.retryFeeds.append(podcast.feed ?? feed)
            } else {
                facts.pendingFeedCount += 1
                facts.retryFeeds.append(podcast.feed ?? feed)
            }
        }
        return facts
    }
}

/// Library-wide counts for Settings → iCloud Sync: how far this device's local
/// podcast library has filled from the synced subscription list.
struct LibraryFillSnapshot: Sendable, Equatable {
    var subscribed = 0
    var waitingForFirstFetch = 0
    var needsLogin = 0
    var failed = 0

    var filled: Int { max(0, subscribed - waitingForFirstFetch - needsLogin - failed) }
    var isComplete: Bool { waitingForFirstFetch + needsLogin + failed == 0 }

    /// Reads metadata only; the episode-count probe runs just for podcasts
    /// whose metadata does not already show a successful fetch.
    static func read(library: ModelContainer) -> LibraryFillSnapshot {
        let context = ModelContext(library)
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        var snapshot = LibraryFillSnapshot()
        for podcast in podcasts {
            guard let metadata = podcast.metaData, metadata.isSubscribed else { continue }
            snapshot.subscribed += 1
            if metadata.feedUpdateCheckDate != nil, metadata.lastFeedFailureDate == nil { continue }
            let podcastID = podcast.persistentModelID
            var count = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil && $0.podcast!.persistentModelID == podcastID }
            )
            count.fetchLimit = 1
            guard ((try? context.fetchCount(count)) ?? 0) == 0 else { continue }
            let credential = metadata.credentialState
            if credential != .available, credential != .unsupported {
                snapshot.needsLogin += 1
            } else if metadata.lastFeedFailureDate != nil {
                snapshot.failed += 1
            } else {
                snapshot.waitingForFirstFetch += 1
            }
        }
        return snapshot
    }
}

// MARK: - Monitor

/// Live, observation-scoped hydration status. Kept apart from
/// `ModelContainerManager`'s `@Published` state so per-feed progress only
/// re-renders the views that show restore status.
@MainActor
@Observable
final class LibraryRestoreMonitor {
    static let shared = LibraryRestoreMonitor()

    private(set) var isHydrating = false
    private(set) var inFlightFeeds = 0
    private(set) var completedFeeds = 0
    /// Bumped after each relevant feed commit and incremental publish, so
    /// status views re-read their counts without polling.
    private(set) var revision = 0
    private(set) var isOffline = false

    private init() {}

    func hydrationStarted() {
        isHydrating = true
        completedFeeds = 0
        revision &+= 1
    }

    func feedStarted() { inFlightFeeds += 1 }

    func feedFinished() {
        inFlightFeeds = max(0, inFlightFeeds - 1)
        completedFeeds += 1
    }

    func hydrationFinished() {
        isHydrating = false
        inFlightFeeds = 0
        revision &+= 1
    }

    func membershipPublished() { revision &+= 1 }

    func connectivityChanged(isOffline: Bool) {
        guard self.isOffline != isOffline else { return }
        self.isOffline = isOffline
        revision &+= 1
    }
}

/// One process-wide path monitor. Reports transitions to the main actor so
/// offline status shows honestly and hydration resumes when the device is
/// back online.
final class LibraryConnectivityMonitor: @unchecked Sendable {
    static let shared = LibraryConnectivityMonitor()
    private let queue = DispatchQueue(label: "LibraryConnectivityMonitor")
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var started = false
    private var lastAvailable: Bool?

    func startIfNeeded(onRecovered: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard started == false else { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied
            self.lock.lock()
            let previous = self.lastAvailable
            self.lastAvailable = available
            self.lock.unlock()
            guard previous != available else { return }
            Task { @MainActor in
                LibraryRestoreMonitor.shared.connectivityChanged(isOffline: available == false)
                if available, previous == false { onRecovered() }
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Milestones

/// Privacy-safe milestones for second-device restore: counts, priorities and
/// durations only. No feed URLs, titles, identifiers or listening details.
enum LibraryRestoreSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "UpNext",
        category: .pointsOfInterest
    )

    static func referencesReceived(queue: Int, playlists: Int, current: Int) {
        os_signpost(.event, log: log, name: "Restore refs received",
                    "queue_feeds=%{public}d playlist_feeds=%{public}d current_feeds=%{public}d",
                    queue, playlists, current)
    }

    static func runStarted(requested: Int, priorityBacklog: Int, concurrency: Int) {
        os_signpost(.event, log: log, name: "Restore hydration started",
                    "requested=%{public}d priority_backlog=%{public}d concurrency=%{public}d",
                    requested, priorityBacklog, concurrency)
    }

    static func feedFinished(priority: Int, succeeded: Bool, milliseconds: Int64) {
        os_signpost(.event, log: log, name: "Restore feed finished",
                    "priority=%{public}d succeeded=%{public}d duration_ms=%{public}lld",
                    priority, succeeded ? 1 : 0, milliseconds)
    }

    static func membershipPublished(applied: Int, unresolvedFeeds: Int, milliseconds: Int64) {
        os_signpost(.event, log: log, name: "Restore membership published",
                    "entries_applied=%{public}d unresolved_feeds=%{public}d duration_ms=%{public}lld",
                    applied, unresolvedFeeds, milliseconds)
    }

    static func firstPlayable(millisecondsSinceRunStart: Int64) {
        os_signpost(.event, log: log, name: "Restore first playable entry",
                    "since_run_start_ms=%{public}lld", millisecondsSinceRunStart)
    }

    static func runFinished(attempted: Int, succeeded: Int, failed: Int, milliseconds: Int64) {
        os_signpost(.event, log: log, name: "Restore hydration finished",
                    "attempted=%{public}d succeeded=%{public}d failed=%{public}d duration_ms=%{public}lld",
                    attempted, succeeded, failed, milliseconds)
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}
