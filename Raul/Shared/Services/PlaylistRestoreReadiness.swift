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
    /// The feeds may be fetched but are not right now (never fetched yet,
    /// or in their retry backoff).
    case waiting
    case unavailable
}

/// What a Queue or manual playlist can honestly say about its synced entries.
///
/// Derived from existing state only: effective portable references in
/// UserState (`PlaylistMembershipResolver`), the local playlist, library feed
/// facts and this playlist's own feeds in the hydration monitor. It never
/// decides membership; unresolved references stay authoritative in UserState.
enum PlaylistRestoreReadiness: Sendable, Equatable {
    /// No saved entries anywhere: show the ordinary empty state.
    case empty
    /// The saved references could not be read; say nothing rather than
    /// claim the playlist is empty or restoring.
    case unknown
    /// Another device reported entries, but none have arrived here yet.
    case waitingForICloud
    /// Feeds for this playlist's unresolved entries are being fetched.
    case restoring(resolved: Int, total: Int)
    /// Nothing is fetching them right now and some entries are still missing.
    case partial(resolved: Int, total: Int, blocker: PlaylistRestoreBlocker)
    case complete

    struct Inputs: Sendable, Equatable {
        /// Entries in effect for this playlist: local entries plus effective
        /// references that are not on this device.
        var referenceCount = 0
        /// Entries in the local playlist.
        var resolvedCount = 0
        /// Entry count another device published, if known (default queue only).
        var cloudReferenceCount: Int?
        var awaitingInitialImport = false
        /// Unresolved entries' feeds never fetched here and allowed to fetch now.
        var pendingFeedCount = 0
        /// Unresolved entries' feeds that may fetch later (backoff).
        var waitingFeedCount = 0
        /// Unresolved entries' feeds waiting for a sign-in on this device.
        var loginFeedCount = 0
        /// Unresolved entries' feeds whose fetch failed or did not include them.
        var failedFeedCount = 0
        /// Unresolved entries' feeds being fetched right now.
        var inFlightFeedCount = 0
        /// A hydration run is active (it may pick up pending feeds).
        var isHydrating = false
        var isOffline = false
        var readFailed = false
    }

    static func derive(_ inputs: Inputs) -> PlaylistRestoreReadiness {
        if inputs.readFailed {
            return inputs.awaitingInitialImport || (inputs.cloudReferenceCount ?? 0) > 0
                ? .waitingForICloud
                : .unknown
        }
        let total = max(inputs.referenceCount, inputs.resolvedCount)
        let resolved = min(inputs.resolvedCount, total)
        if total == 0 {
            if inputs.awaitingInitialImport || (inputs.cloudReferenceCount ?? 0) > 0 {
                return .waitingForICloud
            }
            return .empty
        }
        guard resolved < total else { return .complete }
        let networkFeeds = inputs.pendingFeedCount + inputs.waitingFeedCount
            + inputs.failedFeedCount + inputs.inFlightFeedCount
        if inputs.isOffline, networkFeeds > 0 {
            return .partial(resolved: resolved, total: total, blocker: .offline)
        }
        // Only this playlist's own feeds count: other feeds loading says
        // nothing about these entries.
        if inputs.inFlightFeedCount > 0 || (inputs.isHydrating && inputs.pendingFeedCount > 0) {
            return .restoring(resolved: resolved, total: total)
        }
        if inputs.loginFeedCount > 0 {
            return .partial(resolved: resolved, total: total, blocker: .needsLogin)
        }
        if inputs.pendingFeedCount + inputs.waitingFeedCount > 0 {
            return .partial(resolved: resolved, total: total, blocker: .waiting)
        }
        return .partial(resolved: resolved, total: total, blocker: .unavailable)
    }

    /// Whether the status deserves space in the list or empty state.
    var isVisible: Bool {
        switch self {
        case .empty, .unknown, .complete: false
        case .waitingForICloud, .restoring, .partial: true
        }
    }
}

/// Facts about one playlist's effective membership, read off the main actor.
struct PlaylistRestoreFacts: Sendable, Equatable {
    /// The UserState references could not be read (store missing or fetch
    /// failed). Distinct from "no references".
    var readFailed = false
    /// Local entries plus effective references that need a feed here.
    var referenceCount = 0
    /// Entries in the local playlist (shown or awaiting portable export).
    var resolvedCount = 0
    /// Effective references whose episode is already in this library but not
    /// in the playlist (stale completion, pending reconciliation or a local
    /// removal not exported yet). Not counted: no feed work can change them.
    var locallyAvailableCount = 0
    var pendingFeedCount = 0
    var waitingFeedCount = 0
    var loginFeedCount = 0
    var failedFeedCount = 0
    /// Normalized keys (`PodcastFeedIdentity`) of feeds the unresolved
    /// references need; matched against hydration's in-flight feeds.
    var unresolvedFeedKeys: Set<String> = []
    /// First referenced feed that needs a sign-in, for the repair link.
    var loginFeed: URL?
    /// Referenced feeds a targeted Retry should fetch again.
    var retryFeeds: [URL] = []

    /// Bounded reads: this playlist's UserState references, its local
    /// entries, and the library podcasts that unresolved references name (one
    /// episode-count probe per distinct feed).
    static func read(
        playlistSyncID: String,
        includesLegacyQueueEntries: Bool,
        library: ModelContainer,
        userState: ModelContainer?,
        now: Date = .now
    ) -> PlaylistRestoreFacts {
        var facts = PlaylistRestoreFacts()
        guard let userState else {
            facts.readFailed = true
            return facts
        }
        let stateContext = ModelContext(userState)
        let libraryContext = ModelContext(library)

        // Local playlist and its entries, by the same normalized identity.
        let playlists = (try? libraryContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let localPlaylist = playlists.first {
            $0.storeSplitSyncID == playlistSyncID && $0.hidden == false
        } ?? playlists.first { $0.storeSplitSyncID == playlistSyncID }
        var localIdentities = Set<String>()
        var localEpisodeIDs = Set<String>()
        if let localPlaylist {
            let playlistID = localPlaylist.id
            let entries: [PlaylistEntry]
            do {
                entries = try libraryContext.fetch(FetchDescriptor<PlaylistEntry>(
                    predicate: #Predicate<PlaylistEntry> { $0.playlist?.id == playlistID }
                ))
            } catch {
                facts.readFailed = true
                return facts
            }
            for entry in entries {
                guard let episode = entry.episode, episode.url != nil else { continue }
                let key = PlaylistMembershipResolver.identityKey(for: episode)
                localIdentities.insert(key)
                if let episodeID = PlaylistMembershipResolver.episodeID(ofIdentityKey: key) {
                    localEpisodeIDs.insert(episodeID)
                }
            }
        }
        facts.resolvedCount = localIdentities.count

        // Every synced playlist ID the importer maps onto this playlist.
        var aliasIDs: Set<String> = [playlistSyncID]
        let logicalKey = localPlaylist.map {
            PlaylistMembershipResolver.playlistLogicalKey(title: $0.title, kindRawValue: $0.kindRawValue)
        }
        let effective: [String: PlaylistMembershipResolver.Reference]
        do {
            if let logicalKey {
                for header in try stateContext.fetch(FetchDescriptor<PlaylistSync>())
                where PlaylistMembershipResolver.playlistLogicalKey(
                    title: header.title, kindRawValue: header.kindRawValue
                ) == logicalKey {
                    aliasIDs.insert(header.id)
                }
            }
            let aliases = Array(aliasIDs)
            // Tombstones included: they carry the deletion intent.
            let playlistEntries = try stateContext.fetch(FetchDescriptor<PlaylistEntrySync>(
                predicate: #Predicate<PlaylistEntrySync> { aliases.contains($0.playlistID) },
                sortBy: PlaylistMembershipResolver.playlistEntryOrder
            ))
            let queueEntries = includesLegacyQueueEntries
                ? try stateContext.fetch(FetchDescriptor<QueueEntrySync>(
                    sortBy: PlaylistMembershipResolver.queueEntryOrder
                ))
                : nil
            effective = PlaylistMembershipResolver.effectiveMembership(
                playlistEntries: playlistEntries,
                aliasIDs: aliasIDs,
                queueEntries: queueEntries
            )
        } catch {
            facts.readFailed = true
            return facts
        }

        // Set intersection by identity, never row counts. A reference whose
        // feed URL spelling moved still matches its local entry by episode ID.
        var unresolved = effective.values.filter { reference in
            guard localIdentities.contains(reference.identityKey) == false else { return false }
            guard let episodeID = PlaylistMembershipResolver.episodeID(ofIdentityKey: reference.identityKey) else {
                return true
            }
            return localEpisodeIDs.contains(episodeID) == false
        }

        // Episodes already in this library need no feed: either a stale
        // completion (excluded by policy) or pending local reconciliation.
        if unresolved.isEmpty == false {
            let local = locallyAvailableEpisodes(for: unresolved, in: libraryContext)
            unresolved.removeAll { reference in
                guard let episodeID = PlaylistMembershipResolver.episodeID(ofIdentityKey: reference.identityKey),
                      local.contains(episodeID) else { return false }
                facts.locallyAvailableCount += 1
                return true
            }
        }
        facts.referenceCount = facts.resolvedCount + unresolved.count
        guard unresolved.isEmpty == false else { return facts }

        var feedStrings: [String] = []
        var seenFeeds = Set<String>()
        for reference in unresolved.sorted(by: { $0.sortIndex < $1.sortIndex })
        where seenFeeds.insert(reference.feedURL).inserted {
            feedStrings.append(reference.feedURL)
        }

        var podcastByKey: [String: Podcast] = [:]
        for podcast in (try? libraryContext.fetch(FetchDescriptor<Podcast>())) ?? [] {
            guard let feed = podcast.feed else { continue }
            for key in feed.podcastFeedComparisonKeys where podcastByKey[key] == nil {
                podcastByKey[key] = podcast
            }
        }
        var classifiedPodcasts = Set<PersistentIdentifier>()
        for feedString in feedStrings {
            guard let feed = URL(string: feedString) else { continue }
            facts.unresolvedFeedKeys.insert(PodcastFeedIdentity.normalizedFeedURLString(feed))
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
            guard classifiedPodcasts.insert(podcastID).inserted else { continue }
            let podcastFeed = podcast.feed ?? feed
            facts.unresolvedFeedKeys.insert(PodcastFeedIdentity.normalizedFeedURLString(podcastFeed))
            var count = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil && $0.podcast!.persistentModelID == podcastID }
            )
            count.fetchLimit = 1
            let hasEpisodes = ((try? libraryContext.fetchCount(count)) ?? 0) > 0
            let metadata = podcast.metaData
            let credential = metadata?.credentialState ?? .available
            if hasEpisodes {
                // Fetched, but without these episodes: nothing more arrives
                // unless a fetch is running for it (see in-flight) or Retry.
                facts.failedFeedCount += 1
                facts.retryFeeds.append(podcastFeed)
            } else if credential != .available, credential != .unsupported {
                facts.loginFeedCount += 1
                if facts.loginFeed == nil { facts.loginFeed = podcastFeed }
            } else if metadata?.lastFeedFailureDate == nil, metadata?.feedUpdateCheckDate != nil {
                // Fetched successfully but still empty.
                facts.failedFeedCount += 1
                facts.retryFeeds.append(podcastFeed)
            } else if metadata?.lastFeedFailureDate != nil {
                let candidate = SubscriptionHydrationScheduler.Candidate(
                    feed: podcastFeed,
                    isSubscribed: true,
                    credentialState: credential,
                    authenticationRetryAfter: metadata?.authenticationRetryAfter,
                    lastLocalCheck: nil,
                    lastFailure: metadata?.lastFeedFailureDate,
                    consecutiveFailures: metadata?.consecutiveFeedFailureCount ?? 0
                )
                if SubscriptionHydrationScheduler.mayAttempt(candidate, now: now) {
                    // Due again: the next hydration pass picks it up.
                    facts.pendingFeedCount += 1
                } else {
                    facts.waitingFeedCount += 1
                }
                facts.retryFeeds.append(podcastFeed)
            } else {
                facts.pendingFeedCount += 1
                facts.retryFeeds.append(podcastFeed)
            }
        }
        return facts
    }

    /// Episode IDs (`guid:…`, `enclosure:…`, `episode:…`) of the unresolved
    /// references that already exist in this library. Two batched fetches.
    private static func locallyAvailableEpisodes(
        for references: [PlaylistMembershipResolver.Reference],
        in context: ModelContext
    ) -> Set<String> {
        var guids: [String] = []
        var urls: [URL] = []
        var addedAtByEpisodeID: [String: Date] = [:]
        for reference in references {
            guard let episodeID = PlaylistMembershipResolver.episodeID(ofIdentityKey: reference.identityKey) else {
                continue
            }
            addedAtByEpisodeID[episodeID] = reference.addedAt
            if episodeID.hasPrefix("guid:") {
                guids.append(String(episodeID.dropFirst(5)))
            } else if episodeID.hasPrefix("enclosure:") || episodeID.hasPrefix("episode:") {
                let prefix = episodeID.hasPrefix("enclosure:") ? 10 : 8
                if let url = URL(string: String(episodeID.dropFirst(prefix))) { urls.append(url) }
            }
        }
        var episodes: [Episode] = []
        if guids.isEmpty == false {
            episodes += (try? context.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.guid != nil && guids.contains($0.guid!) }
            ))) ?? []
        }
        if urls.isEmpty == false {
            episodes += (try? context.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.url != nil && urls.contains($0.url!) }
            ))) ?? []
        }
        var found = Set<String>()
        for episode in episodes {
            guard let episodeID = PlaylistMembershipResolver.episodeID(
                ofIdentityKey: PlaylistMembershipResolver.identityKey(for: episode)
            ), addedAtByEpisodeID[episodeID] != nil else { continue }
            found.insert(episodeID)
        }
        return found
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
    /// Normalized feed keys being fetched right now, so a playlist reports
    /// "restoring" only for its own feeds (#519).
    private(set) var inFlightFeedKeys: Set<String> = []
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

    func feedStarted(key: String? = nil) {
        inFlightFeeds += 1
        if let key, inFlightFeedKeys.insert(key).inserted { revision &+= 1 }
    }

    func feedFinished(key: String? = nil) {
        inFlightFeeds = max(0, inFlightFeeds - 1)
        completedFeeds += 1
        if let key, inFlightFeedKeys.remove(key) != nil { revision &+= 1 }
    }

    func hydrationFinished() {
        isHydrating = false
        inFlightFeeds = 0
        inFlightFeedKeys.removeAll()
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
