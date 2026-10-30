import Foundation
import SwiftData

/// Tracks the one-time copy of an upgraded device's user data into UserState.
/// The app runs from its existing local library throughout, so this never holds
/// up startup; it only decides what may be imported back.
enum StoreCutoverState {
    private static let startedKey = "storeSplit.localLibraryMigrationStarted.v1"
    // v3: corrects baselines counted from duplicate summary rows and removes
    // finished episodes from playlists on devices that already ran earlier builds.
    static let deferredCompleteKey = "storeSplit.deferredMigrationComplete.v3"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    nonisolated static var isDeferredMigrationPending: Bool {
        defaults.bool(forKey: startedKey) && defaults.bool(forKey: deferredCompleteKey) == false
    }

    /// Called when an upgraded device opens its library with CloudKit off.
    static func beginLocalLibrary() {
        StoreDevelopmentConfiguration.markLegacyCloudCutoverCompleted()
        defaults.set(true, forKey: startedKey)
        var expected = UserDefaults.standard.stringArray(forKey: StoreLineage.key) ?? []
        if expected.contains("SharedDatabase.sqlite") == false {
            expected.append("SharedDatabase.sqlite")
            UserDefaults.standard.set(expected, forKey: StoreLineage.key)
        }
    }

    static func markDeferredComplete() {
        defaults.set(true, forKey: deferredCompleteKey)
        CrashBreadcrumbs.shared.record("store_cutover_deferred_complete")
    }
}

/// Categories and hours only, no feeds or titles: what the listening total is
/// made of, so a wrong figure can be explained from a support report.
enum ListeningTotalsDiagnostics {
    private static let key = "storeSplit.listeningTotalsDiagnostics.v1"

    nonisolated static var latest: String {
        (UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard)
            .string(forKey: key) ?? "not captured"
    }

    nonisolated static func capture(userState: ModelContainer, library: ModelContainer?) {
        func hours(_ seconds: Double) -> String { "\(Int(seconds / 3_600))h" }
        var parts: [String] = []
        let account = ModelContext(userState)
        if let baselines = try? account.fetch(FetchDescriptor<ListeningBaselineSync>()) {
            let perFeed = baselines.filter { $0.feedURL != ListeningBaselineSync.allPodcastsFeedURL }
            parts.append("baseline rows=\(baselines.count) sum=\(hours(perFeed.reduce(0) { $0 + $1.totalSeconds }))")
        }
        if let history = try? account.fetch(FetchDescriptor<ListeningHistorySync>()) {
            let migrated = history.filter(\.isLegacyMigrated)
            func total(_ rows: [ListeningHistorySync]) -> Double {
                rows.reduce(0) { $0 + max(0, $1.listenedSeconds) }
            }
            parts.append("history migrated=\(migrated.count)/\(hours(total(migrated))) live=\(history.count - migrated.count)/\(hours(total(history) - total(migrated)))")
        }
        if let library,
           let summaries = try? ModelContext(library).fetch(FetchDescriptor<PlaySessionSummary>()) {
            for (kind, rows) in Dictionary(grouping: summaries, by: { $0.periodKind ?? "?" }).sorted(by: { $0.key < $1.key }) {
                var best: [String: Double] = [:]
                for row in rows {
                    guard let start = row.periodStart else { continue }
                    let id = "\(row.podcastFeed?.absoluteString ?? "-")|"
                        + StoreSplitMigrationService.baselinePeriodIdentity(start, kind: kind)
                    best[id] = max(best[id] ?? 0, row.totalSeconds ?? 0)
                }
                parts.append("legacy \(kind) rows=\(rows.count) unique=\(best.count) all=\(hours(rows.reduce(0) { $0 + ($1.totalSeconds ?? 0) })) deduped=\(hours(best.values.reduce(0, +)))")
            }
        }
        (UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard)
            .set(parts.joined(separator: "; "), forKey: key)
    }
}

/// The queryable library the UI binds to, kept on disk so it is built once
/// instead of at every launch. It is derived and holds no authority: every write
/// also goes to UserState or PodcastCache, and this file can be rebuilt from them.
enum StoreRuntimeProjection {
    /// Bump when the projection's contents must be rebuilt.
    static let version = 1
    private static let readyVersionKey = "storeSplit.runtimeProjectionReadyVersion"
    private static let fileVersionKey = "storeSplit.runtimeProjectionFileVersion"
    private static let cursorKey = "storeSplit.runtimeProjectionCursor"
    private static let feedFillDoneKey = "storeSplit.runtimeFeedFillDone"
    private static let feedFillPassesKey = "storeSplit.runtimeFeedFillPasses"
    private static let transcriptBackfillPendingKey = "storeSplit.runtimeTranscriptBackfillPending"
    private static let libraryBackfillCursorKey = "storeSplit.runtimeTranscriptBackfillCursor"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    nonisolated static var url: URL? {
        ModelContainerManager.sharedContainerURL?.appendingPathComponent("LibraryRuntime.sqlite")
    }

    nonisolated static var isReady: Bool {
        defaults.integer(forKey: readyVersionKey) == version
    }

    /// False only when the file was built for another version. An unfinished
    /// build of this version is kept, so it can resume.
    nonisolated static var isFileCurrent: Bool {
        defaults.integer(forKey: fileVersionKey) == version
    }

    /// The last feed the build finished.
    nonisolated static var cursor: String? {
        get { defaults.string(forKey: cursorKey) }
        set { defaults.set(newValue, forKey: cursorKey) }
    }

    /// True while the first build's graph is still incomplete. A missing episode
    /// or transcript then says nothing about the library: nothing may
    /// re-transcribe, prune, or treat a feed's episode as newly published.
    nonisolated static var isLibraryBackfillPending: Bool {
        get { defaults.bool(forKey: transcriptBackfillPendingKey) }
        set { defaults.set(newValue, forKey: transcriptBackfillPendingKey) }
    }

    nonisolated static var libraryBackfillCursor: String? {
        get { defaults.string(forKey: libraryBackfillCursorKey) }
        set { defaults.set(newValue, forKey: libraryBackfillCursorKey) }
    }

    /// For episodes a feed fill creates: their synced state has to be on them
    /// from the start, or their next write would publish "unplayed" as the truth.
    nonisolated(unsafe) static var fillUserStateContainer: ModelContainer?

    /// Fetches each subscribed feed once in full, which writes its episodes to the
    /// runtime graph and PodcastCache. A feed that fails, for example offline, is
    /// tried again next launch, three passes at most; after that ordinary refresh
    /// takes over.
    /// Returns false while another pass is still due.
    static func fillFromFeeds(runtime: ModelContainer) async -> Bool {
        let feeds = ((try? ModelContext(runtime).fetch(FetchDescriptor<Podcast>())) ?? [])
            .filter { $0.metaData?.isSubscribed == true }
            .compactMap(\.feed)
            .sorted { $0.absoluteString < $1.absoluteString }
        let actor = PodcastModelActor(modelContainer: runtime)
        var done = Set(defaults.stringArray(forKey: feedFillDoneKey) ?? [])
        var anyFailed = false
        for feed in feeds where done.contains(feed.absoluteString) == false {
            guard Task.isCancelled == false else { return false }
            do {
                _ = try await actor.updatePodcast(
                    feed,
                    policy: .forceFullFetch,
                    silent: true,
                    resolveExistingMissingDurations: false
                )
                done.insert(feed.absoluteString)
                defaults.set(Array(done), forKey: feedFillDoneKey)
            } catch {
                anyFailed = true
            }
        }
        guard Task.isCancelled == false else { return false }
        guard anyFailed else { return true }
        let passes = defaults.integer(forKey: feedFillPassesKey) + 1
        defaults.set(passes, forKey: feedFillPassesKey)
        return passes >= 3
    }

    /// An upgraded device reads its own library, so a projection from an earlier
    /// build is unused. This file is derived; nothing else is removed here.
    nonisolated static func discardUnused() {
        guard let url else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        isLibraryBackfillPending = false
        libraryBackfillCursor = nil
    }

    static func markReady() {
        defaults.set(version, forKey: readyVersionKey)
        cursor = nil
    }

    private static func discard(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        defaults.removeObject(forKey: readyVersionKey)
        cursor = nil
    }

    /// A projection of the wrong version, or one that won't open, is discarded:
    /// only this derived file is ever removed here.
    nonisolated static func open(at url: URL, isCurrent: Bool) throws -> ModelContainer {
        if isCurrent == false { discard(url) }
        defaults.set(version, forKey: fileVersionKey)
        do {
            return try ModelContainerManager.makeLegacyContainer(storageURL: url)
        } catch {
            discard(url)
            return try ModelContainerManager.makeLegacyContainer(storageURL: url)
        }
    }
}

struct StoreCutoverProgress: Sendable, Equatable {
    /// Real progress of the one-time library build on a fresh-install device.
    var fraction: Double
    /// Something that visibly moves during a long step.
    var detail: String?
}

enum StoreCutoverOutcome: Equatable, Sendable {
    case committed
    case interrupted
    case failed(phase: String)

    var diagnosticSummary: String {
        switch self {
        case .committed: "completed"
        case .interrupted: "interrupted"
        case .failed(let phase): "failed phase=\(phase)"
        }
    }
}

/// Copies an upgraded device's user data into UserState while the app is in use.
/// Every phase merges by stable identity and date, is checkpointed, and reads a
/// library that may change between slices. Failing here never affects the running
/// app: it stops, and the next launch continues.
enum StoreCutoverCoordinator {
    private static let maximumConsecutiveFailures = 3
    /// Local AI content stays in the library store, so one bad row must not hold
    /// the rest of the copy hostage.
    private static let skippablePhases: Set<String> = [
        StoreSplitMigrationService.Phase.aiTranscripts,
        StoreSplitMigrationService.Phase.aiChapters
    ]

    static func runDeferred(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        shouldContinue: @escaping @Sendable () -> Bool = { Task.isCancelled == false },
        idle: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    ) async -> StoreCutoverOutcome {
        var failures = 0
        var failingPhase: String?
        while true {
            guard shouldContinue() else { return .interrupted }
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer,
                shouldContinue: shouldContinue
            )
            switch report.status {
            case .completed:
                do {
                    try StoreSplitMigrationService.tombstonePlayedMemberships(
                        userStateContainer: userStateContainer
                    )
                } catch {
                    return .failed(phase: "played_memberships")
                }
                StoreCutoverState.markDeferredComplete()
                return .committed
            case .cancelled:
                return .interrupted
            case .failed:
                let phase = report.phase ?? "unknown"
                failures = failingPhase == phase ? failures + 1 : 1
                failingPhase = phase
                guard failures >= maximumConsecutiveFailures else { break }
                guard skippablePhases.contains(phase),
                      StoreSplitMigrationService.completePhaseAfterFailure(
                          phase,
                          cacheContainer: cacheContainer
                      ) else {
                    return .failed(phase: phase)
                }
                failures = 0
                failingPhase = nil
            default:
                failures = 0
                failingPhase = nil
            }
            await idle()
        }
    }
}
