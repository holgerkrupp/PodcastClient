import Foundation
import SwiftData

enum StoreSplitMigrationSchedulePolicy {
    static let nightStartHour = 22
    static let nightEndHour = 7

    static func isEligibleNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= nightStartHour || hour < nightEndHour
    }

    static func nextEligibleNightStart(after date: Date, calendar: Calendar = .current) -> Date? {
        if isEligibleNight(date, calendar: calendar) { return date }
        let todayStart = calendar.startOfDay(for: date)
        let startHour = calendar.date(bySettingHour: nightStartHour, minute: 0, second: 0, of: todayStart)
        if let startHour, date < startHour { return startHour }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        return calendar.date(bySettingHour: nightStartHour, minute: 0, second: 0, of: tomorrow)
    }
}

/// Synchronous, thread-safe signal read inside migration row loops. Playback
/// remains owned by `Player`; this gate only publishes its active state so a
/// background worker can preempt without crossing actor isolation.
final class StoreSplitPlaybackGate: @unchecked Sendable {
    static let shared = StoreSplitPlaybackGate()
    private let lock = NSLock()
    private var active = false

    private init() {}

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }
}

/// Thread-safe export signal for bounded maintenance loops that must not cross
/// CloudKit admission gates after they have started.
final class StoreSplitCloudKitExportGate: @unchecked Sendable {
    static let shared = StoreSplitCloudKitExportGate()
    private let lock = NSLock()
    private var active = false

    private init() {}

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        lock.unlock()
    }
}

final class StoreSplitAdaptiveBatchSizer: @unchecked Sendable {
    static let shared = StoreSplitAdaptiveBatchSizer()
    private let lock = NSLock()
    private var lastPageDurations: [String: TimeInterval] = [:]

    private init() {}

    func pageSize(for phase: String, base: Int, footprint: UInt64) -> Int {
        lock.lock()
        let priorDuration = lastPageDurations[phase]
        lock.unlock()

        if footprint >= 700 * 1024 * 1024 { return max(10, base / 2) }
        if footprint >= 550 * 1024 * 1024 { return max(10, base * 3 / 4) }
        guard let priorDuration else { return base }
        if priorDuration > 4 { return max(10, base / 2) }
        if priorDuration < 1.5, footprint < 400 * 1024 * 1024 {
            return min(1_000, base * 3 / 2)
        }
        return base
    }

    func recordPage(_ phase: String, duration: TimeInterval) {
        lock.lock()
        lastPageDurations[phase] = duration
        lock.unlock()
    }
}

struct StoreSplitMigrationResult: Sendable {
    var subscriptions = StoreSplitMigrationPhaseResult()
    var episodeStates = StoreSplitMigrationPhaseResult()
    var playlists = StoreSplitMigrationPhaseResult()
    var playlistEntries = StoreSplitMigrationPhaseResult()
    var queueEntries = StoreSplitMigrationPhaseResult()
    var bookmarks = StoreSplitMigrationPhaseResult()
    var preferences = StoreSplitMigrationPhaseResult()
    var listeningHistory = StoreSplitMigrationPhaseResult()
    var listeningSummaries = StoreSplitMigrationPhaseResult()
    var listeningBaselinePreparation = StoreSplitMigrationPhaseResult()
    var listeningBaselinePublication = StoreSplitMigrationPhaseResult()
    var aiTranscripts = StoreSplitMigrationPhaseResult()
    var aiChapters = StoreSplitMigrationPhaseResult()
    var listeningHistoryVerification = StoreSplitMigrationPhaseResult()
    var listeningBaselineVerificationScan = StoreSplitMigrationPhaseResult()
    var listeningBaselineVerification = StoreSplitMigrationPhaseResult()
    var listeningBaselineVerificationComparison = StoreSplitMigrationPhaseResult()

    var failedCount: Int {
        subscriptions.failed
            + episodeStates.failed
            + playlists.failed
            + playlistEntries.failed
            + queueEntries.failed
            + bookmarks.failed
            + preferences.failed
            + listeningHistory.failed
            + listeningHistoryVerification.failed
            + listeningBaselineVerificationScan.failed
            + listeningBaselineVerification.failed
            + listeningBaselineVerificationComparison.failed
            + listeningSummaries.failed
            + listeningBaselinePreparation.failed
            + listeningBaselinePublication.failed
            + aiTranscripts.failed
            + aiChapters.failed
    }
}

struct StoreSplitMigrationPhaseResult: Sendable {
    var scanned = 0
    var inserted = 0
    var updated = 0
    var skipped = 0
    var failed = 0

    static func + (
        lhs: StoreSplitMigrationPhaseResult,
        rhs: StoreSplitMigrationPhaseResult
    ) -> StoreSplitMigrationPhaseResult {
        StoreSplitMigrationPhaseResult(
            scanned: lhs.scanned + rhs.scanned,
            inserted: lhs.inserted + rhs.inserted,
            updated: lhs.updated + rhs.updated,
            skipped: lhs.skipped + rhs.skipped,
            failed: lhs.failed + rhs.failed
        )
    }
}

/// The outcome of executing a single bounded migration slice.
///
/// The engine processes at most one page of one phase per slice and reports what
/// the caller should do next, so the driving loop can interleave cancellation,
/// playback, and CloudKit-export backpressure checks between slices.
struct StoreSplitSliceReport: Sendable {
    enum Status: String, Sendable {
        /// More work remains in the current phase.
        case advanced
        /// The current phase finished; another phase may still be pending.
        case phaseCompleted
        /// Every backfill phase and the bounded listening-history check completed.
        case completed
        /// The slice was cancelled before doing work.
        case cancelled
        /// A fetch/save error stopped the current phase.
        case failed
    }

    var status: Status
    var phase: String?
    var processed: Int = 0
    var mutations: Int = 0
    var saveCount: Int = 0
    var saveDuration: TimeInterval = 0
    var footprintBefore: UInt64 = 0
    var footprintAfter: UInt64 = 0
    var error: String?

    var footprintDeltaDescription: String {
        MemoryFootprint.formattedDelta(before: footprintBefore, after: footprintAfter)
    }
}

struct StoreWorkBudget: Sendable, Equatable {
    let maximumMutations: Int
    let maximumSaves: Int
    let maximumWallTime: Duration

    static let migrationSlice = StoreWorkBudget(
        maximumMutations: 160,
        maximumSaves: 2,
        maximumWallTime: .seconds(4)
    )
}

/// Run-level limits are deliberately separate from the wall-clock window that
/// iOS grants a `BGProcessingTask`. The latter is an upper bound, not a CPU
/// budget: a process that works continuously can still be killed long before
/// that window expires.
struct StoreSplitMigrationRunPolicy: Sendable, Equatable {
    let maximumWallTime: TimeInterval
    let maximumActiveWorkTime: TimeInterval
    let maximumSlices: Int
    let minimumIdleTime: TimeInterval
    let idleToWorkRatio: Double
    let maximumMemoryGrowth: UInt64
    let maximumFootprint: UInt64

    static let foreground = StoreSplitMigrationRunPolicy(
        maximumWallTime: 15,
        maximumActiveWorkTime: 10,
        maximumSlices: 6,
        minimumIdleTime: 1,
        idleToWorkRatio: 0.5,
        maximumMemoryGrowth: 96 * 1024 * 1024,
        maximumFootprint: 900 * 1024 * 1024
    )

    static let background = StoreSplitMigrationRunPolicy(
        maximumWallTime: 120,
        maximumActiveWorkTime: 25,
        maximumSlices: 20,
        minimumIdleTime: 2,
        idleToWorkRatio: 2.0,
        maximumMemoryGrowth: 64 * 1024 * 1024,
        maximumFootprint: 900 * 1024 * 1024
    )

    /// Enforces a proportional idle period while retaining a floor for very
    /// short slices. Background slices therefore spend at least twice as long
    /// idle as they spend doing migration work.
    func idleDuration(after activeDuration: TimeInterval) -> TimeInterval {
        max(minimumIdleTime, activeDuration * idleToWorkRatio)
    }

    func memorySafetyReason(
        runStart: UInt64,
        sliceBefore: UInt64,
        sliceAfter: UInt64
    ) -> String? {
        guard sliceAfter > 0 else { return nil }
        if sliceAfter >= maximumFootprint {
            return "memory footprint reached \(MemoryFootprint.formatted(sliceAfter))"
        }
        let runGrowth = sliceAfter > runStart ? sliceAfter - runStart : 0
        if runStart > 0, runGrowth >= maximumMemoryGrowth {
            return "memory grew by \(MemoryFootprint.formatted(runGrowth)) in one run"
        }
        let sliceGrowth = sliceAfter > sliceBefore ? sliceAfter - sliceBefore : 0
        if sliceBefore > 0, sliceGrowth >= maximumMemoryGrowth {
            return "memory grew by \(MemoryFootprint.formatted(sliceGrowth)) in one slice"
        }
        return nil
    }
}

actor StoreSplitMigrationService {
    // v6 marks migrated compact history and backfills raw analytics into the
    // local cache. This separates the shared historical baseline from later
    // live per-device summaries and prevents double counting after cutover.
    //
    // v8 re-publishes local user state after the runtime graph returned to the
    // durable on-disk library store. A device that spent time reading the
    // in-memory projection — or that was rolled back to local-only reads — can
    // hold user state that never reached UserState.sqlite. Every phase merges by
    // `updatedAt`, so the re-run only fills gaps and never overwrites a newer
    // record from another device.
    nonisolated static let migrationVersion = 8

    /// Per-phase paging revision. Bumping one restarts just that phase on the
    /// next run, leaving the phases whose paging did not change on their
    /// existing checkpoints — much cheaper than bumping `migrationVersion`,
    /// which restarts everything.
    ///
    /// `bookmarks` is at revision 1 because its cursor used to count rows in the
    /// `Marker` base table (every chapter of every episode) and now counts
    /// bookmarks, so the old offsets mean nothing in the new coordinate space.
    private static let phaseRevisions: [String: Int] = [
        Phase.bookmarks: 1,
        Phase.listeningSummaries: 3,
        Phase.listeningBaselinePrepareAggregates: 1,
        Phase.listeningBaselinePrepareSources: 1,
        Phase.listeningBaselinePublication: 2,
        Phase.listeningHistory: 1,
        Phase.listeningHistoryVerification: 2,
        Phase.listeningBaselineVerificationScan: 1,
        Phase.listeningBaselineVerification: 1,
        Phase.listeningBaselineVerificationComparison: 1
    ]

    /// The checkpoint row identity for a phase at its current revision. Rows
    /// left behind by an older revision keep a different id and are ignored.
    ///
    /// The single place this format is spelled out — build ids from here rather
    /// than interpolating the format again.
    nonisolated static func checkpointID(for phase: String) -> String {
        guard let revision = phaseRevisions[phase] else {
            return "v\(migrationVersion).\(phase)"
        }
        return "v\(migrationVersion).\(phase).r\(revision)"
    }

    private static var baselineAggregateNamespace: String {
        "listening-baseline-\(checkpointID(for: Phase.listeningSummaries))"
    }

    private static var baselineSourceNamespace: String {
        "listening-baseline-source-\(checkpointID(for: Phase.listeningSummaries))"
    }

    /// Per-slice record budget for the light phases. Heavier phases override this
    /// with smaller pages because each record faults a larger object graph.
    // The page size is derived from the mutation budget rather than being an
    // independent row-only throttle. A page can therefore never enqueue more
    // than the configured mutation budget before it saves and yields to the
    // exporter. Playlist entries may update both UserState streams, so their
    // logical row count remains deliberately conservative.
    private static let defaultPageSize = StoreWorkBudget.migrationSlice.maximumMutations
    private static let episodePageSize = 100
    private static let listeningSummaryPageSize = 60
    private static let listeningHistoryPageSize = 40
    private static let listeningHistoryVerificationPageSize = 40
    private static let aiContentPageSize = 10
    private static let maximumFailedItemKeys = 100

    /// Ordered, memory-prioritised migration phases. Legacy AI content is copied
    /// to the local-only cache in bounded stages after user-owned state; the
    /// final phase re-reads completed history and verifies its portable copy.
    nonisolated static let slicePhaseOrder = [
        Phase.subscriptions,
        Phase.playlists,
        Phase.playlistEntries,
        Phase.bookmarks,
        Phase.preferences,
        Phase.listeningHistory,
        Phase.episodeStates,
        Phase.aiTranscripts,
        Phase.aiChapters,
        Phase.listeningHistoryVerification,
        Phase.listeningBaselinePrepareAggregates,
        Phase.listeningBaselinePrepareSources,
        Phase.listeningSummaries,
        Phase.listeningBaselinePublication,
        Phase.listeningBaselineVerificationScan,
        Phase.listeningBaselineVerification,
        Phase.listeningBaselineVerificationComparison
    ]

    enum Phase {
        static let subscriptions = "subscriptions"
        static let playlists = "playlists"
        static let playlistEntries = "playlist_entries"
        static let queueEntries = "queue_entries"
        static let bookmarks = "bookmarks"
        static let preferences = "preferences"
        static let episodeStates = "episode_states"
        static let listeningBaselinePrepareAggregates = "baseline_prepare_aggregates"
        static let listeningBaselinePrepareSources = "baseline_prepare_sources"
        static let listeningSummaries = "listening_summaries"
        static let listeningBaselinePublication = "baseline_publish"
        static let listeningHistory = "listening_history"
        static let aiTranscripts = "ai_transcripts"
        static let aiChapters = "ai_chapters"
        static let listeningHistoryVerification = "verification_listening_history"
        static let listeningBaselineVerificationScan = "verification_baseline_scan"
        static let listeningBaselineVerification = "verification_listening_baselines"
        static let listeningBaselineVerificationComparison = "verification_baseline_comparison"
    }

    /// The paging order of every sliced phase, in one place. `resolvedOffset`
    /// re-reads the same order to find where a checkpointed row moved to, so the
    /// two must never drift apart.
    private enum SourceOrder {
        static let podcasts = [SortDescriptor(\Podcast.title)]
        static let playlists = [
            SortDescriptor(\Playlist.sortIndex),
            SortDescriptor(\Playlist.title)
        ]
        static let playlistEntries = [SortDescriptor(\PlaylistEntry.order)]
        static let preferences = [SortDescriptor(\PodcastSettings.title)]
        static let episodes = [
            SortDescriptor(\Episode.publishDate, order: .reverse),
            SortDescriptor(\Episode.guid)
        ]
        static let playSessions = [SortDescriptor(\PlaySession.startTime)]
            + [SortDescriptor(\PlaySession.id)]
        static let verificationPlaySessions = [SortDescriptor(\PlaySession.id)]
        static let listeningSummaries = [
            SortDescriptor(\PlaySessionSummary.periodStart),
            SortDescriptor(\PlaySessionSummary.id)
        ]
        static let transcriptionRecords = [
            SortDescriptor(\TranscriptionRecord.finishedAt),
            SortDescriptor(\TranscriptionRecord.id)
        ]
    }

    /// Where a phase resumes.
    ///
    /// A bare row offset is not a safe cursor: `SharedDatabase.sqlite` stays the
    /// live runtime store while slices run across foreground and background
    /// sessions. Delete a row ahead of the cursor — or change a row's sort key,
    /// which a feed refresh does routinely — and every later row shifts down by
    /// one, so the next `fetchOffset` steps over unmigrated rows and the phase
    /// still reports itself complete.
    ///
    /// The boundary key pins the offset to an actual row: the last row the
    /// previous slice consumed. On resume the engine looks that row up again and
    /// continues right after wherever it now sits.
    struct SliceCursor: Equatable {
        var offset: Int
        var boundaryKey: String?
        /// Whether the previous slice already answered a lost boundary row with
        /// a full re-scan. A second consecutive failure keeps paging by raw
        /// offset instead of restarting again, so a store the engine cannot
        /// re-locate rows in degrades to the old offset behaviour rather than
        /// replaying the first page forever.
        var didRelocateFail: Bool = false

        var encoded: String {
            guard boundaryKey?.isEmpty == false || didRelocateFail else {
                return String(offset)
            }
            let separator = String(SliceCursor.separator)
            return [
                String(offset),
                didRelocateFail ? "1" : "0",
                boundaryKey ?? ""
            ].joined(separator: separator)
        }

        static let separator: Character = "\u{1f}"

        /// Also accepts the plain numeric cursors written before boundary keys
        /// existed; those resume exactly as they did before.
        static func decode(_ raw: String) -> SliceCursor? {
            let parts = raw.split(
                separator: separator,
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard let first = parts.first, let offset = Int(first) else { return nil }
            guard parts.count == 3 else { return SliceCursor(offset: max(0, offset)) }
            let boundary = String(parts[2])
            return SliceCursor(
                offset: max(0, offset),
                boundaryKey: boundary.isEmpty ? nil : boundary,
                didRelocateFail: parts[1] == "1"
            )
        }
    }

    /// The human-readable form of a stored cursor: the row position, without the
    /// boundary key that pins it. Used by the migration debug readout.
    nonisolated static func cursorDisplay(_ raw: String) -> String {
        if let history = HistoryVerificationCursor.decode(raw) { return String(history.scanned) }
        return SliceCursor.decode(raw).map { String($0.offset) } ?? raw
    }

    /// How far either side of the recorded offset the engine looks for the
    /// boundary row, as a multiple of the phase's page size. Beyond that the
    /// phase restarts from zero, which costs a re-scan but cannot lose a row:
    /// every write in every phase is idempotent and an already-migrated record
    /// resolves to a skip.
    private static let cursorRelocationPages = 2

    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let cacheContainer: ModelContainer

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        self.cacheContainer = cacheContainer
    }

    // MARK: - Slice engine entry points

    /// Executes exactly one bounded slice and returns what to do next.
    ///
    /// All `ModelContext` instances are created inside this call and released when
    /// it returns, so no faulted object graph survives between slices.
    nonisolated static func runSlice(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        budget: StoreWorkBudget = .migrationSlice,
        shouldContinue: @escaping @Sendable () -> Bool = { Task.isCancelled == false }
    ) async -> StoreSplitSliceReport {
        let worker = StoreSplitMigrationService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )
        return await worker.runOneSlice(
            budget: budget,
            shouldContinue: shouldContinue
        )
    }

    /// Convenience whole-run used by tests and the development "run now" path.
    /// Loops the bounded slice engine to completion. AI content uses its own
    /// cache-only phases and may be omitted only by explicit development calls.
    nonisolated static func migrate(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        includeAIContent: Bool = true
    ) async -> StoreSplitMigrationResult {
        let worker = StoreSplitMigrationService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )
        return await worker.runToCompletion(includeAIContent: includeAIContent)
    }

#if DEBUG
    /// Development helper: re-reads baseline candidates against the live
    /// stores. Existing baselines are preserved; a missing baseline remains
    /// unresolved until a source-revision fence is available.
    nonisolated static func rebuildListeningSummaries(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) -> StoreSplitMigrationPhaseResult {
        let legacyContext = makeContext(for: legacyContainer)
        let destinationContext = makeContext(for: userStateContainer)
        guard let cacheContainer = try? ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true) else {
            return StoreSplitMigrationPhaseResult(failed: 1)
        }
        let cacheContext = makeContext(for: cacheContainer)
        var result = StoreSplitMigrationPhaseResult()
        var offset = 0
        var scanComplete = false
        while Task.isCancelled == false {
            let page = processListeningSummaries(
                offset: offset,
                pageSize: listeningSummaryPageSize,
                legacyContext: legacyContext,
                destinationContext: destinationContext,
                cacheContext: cacheContext,
                shouldContinue: { Task.isCancelled == false }
            )
            result = result + page.delta
            if let error = page.error {
                result.failed += 1
                CrashBreadcrumbs.shared.record("debug_listening_baseline_rebuild_failed", details: error)
                break
            }
            do {
                if cacheContext.hasChanges { try cacheContext.save() }
            } catch {
                cacheContext.rollback()
                result.failed += 1
                break
            }
            offset += page.processed
            if page.reachedEnd {
                scanComplete = true
                break
            }
            if page.processed == 0 { break }
        }
        guard scanComplete, result.failed == 0, !Task.isCancelled else { return result }
        while !Task.isCancelled {
            let context = makeContext(for: cacheContainer)
            let report = runBaselineMaintenanceSlice(
                phase: Phase.listeningBaselinePublication,
                destinationContext: makeContext(for: userStateContainer),
                cacheContext: context,
                budget: .migrationSlice,
                footprintBefore: MemoryFootprint.current(),
                shouldContinue: { !Task.isCancelled }
            )
            if report.status == .failed {
                result.failed += 1
                break
            }
            if report.status != .advanced {
                let id = checkpointID(for: Phase.listeningBaselinePublication)
                var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                if let checkpoint = try? context.fetch(descriptor).first {
                    result.inserted += checkpoint.insertedCount
                    result.skipped += checkpoint.skippedCount
                }
                break
            }
        }
        return result
    }
#endif

    private func runOneSlice(
        budget: StoreWorkBudget,
        shouldContinue: @Sendable () -> Bool
    ) async -> StoreSplitSliceReport {
        let footprintBefore = MemoryFootprint.current()

        let cacheContext = Self.makeContext(for: cacheContainer)
        guard let phase = Self.currentPhase(cache: cacheContext) else {
            return StoreSplitSliceReport(
                status: .completed,
                phase: nil,
                footprintBefore: footprintBefore,
                footprintAfter: MemoryFootprint.current()
            )
        }

        guard shouldContinue() else {
            return StoreSplitSliceReport(
                status: .cancelled,
                phase: phase,
                footprintBefore: footprintBefore,
                footprintAfter: MemoryFootprint.current()
            )
        }

        if Self.isBaselineMaintenancePhase(phase) {
            return Self.runBaselineMaintenanceSlice(
                phase: phase,
                destinationContext: Self.makeContext(for: userStateContainer),
                cacheContext: cacheContext,
                budget: budget,
                footprintBefore: footprintBefore,
                shouldContinue: shouldContinue
            )
        }

        if phase == Phase.listeningHistoryVerification {
            return Self.runHistoryVerificationSlice(
                legacyContext: Self.makeContext(for: legacyContainer),
                destinationContext: Self.makeContext(for: userStateContainer),
                cacheContext: cacheContext,
                budget: budget,
                footprintBefore: footprintBefore,
                shouldContinue: shouldContinue
            )
        }

        if phase == Phase.listeningBaselineVerificationScan
            || phase == Phase.listeningBaselineVerification
            || phase == Phase.listeningBaselineVerificationComparison {
            let handler = phase == Phase.listeningBaselineVerificationComparison
                ? Self.runBaselineAggregateVerificationSlice
                : Self.runBaselineVerificationSlice
            return handler(
                phase,
                Self.makeContext(for: legacyContainer),
                Self.makeContext(for: userStateContainer),
                cacheContext,
                budget,
                footprintBefore,
                shouldContinue
            )
        }

        let resume = Self.resumeProgress(phase: phase, context: cacheContext)
        let legacyContext = Self.makeContext(for: legacyContainer)
        let userStateContext = Self.makeContext(for: userStateContainer)

        // The legacy store kept serving the running app between slices, so the
        // checkpointed offset is corrected against the row it was taken from
        // before it is used to page.
        let resolved = Self.resolvedOffset(
            phase: phase,
            cursor: resume.cursor,
            legacyContext: legacyContext
        )
        let offset = resolved.offset

        let basePageSize = Self.basePageSize(for: phase)
        let adaptivePageSize = StoreSplitAdaptiveBatchSizer.shared.pageSize(
            for: phase,
            base: basePageSize,
            footprint: footprintBefore
        )
        let pageSize = phase == Phase.listeningSummaries
            ? min(adaptivePageSize, max(1, (budget.maximumMutations - 1) / 2))
            : adaptivePageSize

        let deadline = ContinuousClock.now + budget.maximumWallTime
        let boundedShouldContinue: @Sendable () -> Bool = {
            shouldContinue() && ContinuousClock.now < deadline
        }
        let pageStartedAt = ContinuousClock.now
        var outcome = processPage(
            phase: phase,
            offset: offset,
            pageSize: pageSize,
            legacyContext: legacyContext,
            userStateContext: userStateContext,
            cacheContext: cacheContext,
            shouldContinue: boundedShouldContinue
        )
        let pageDuration = pageStartedAt.duration(to: .now).components
        StoreSplitAdaptiveBatchSizer.shared.recordPage(
            phase,
            duration: Double(pageDuration.seconds) + Double(pageDuration.attoseconds) / 1e18
        )

        let combined = resume.result + outcome.delta
        let nextCursor = SliceCursor(
            offset: outcome.error == nil ? offset + outcome.processed : resume.cursor.offset,
            boundaryKey: outcome.error == nil
                ? (outcome.boundaryKey ?? resume.cursor.boundaryKey)
                : resume.cursor.boundaryKey,
            didRelocateFail: resolved.didRelocateFail
        )
        let saveStartedAt = Date()
        var checkpointSaveCount = 1
        var queueCheckpointSaved = true
        if phase == Phase.playlistEntries {
            let queueResume = Self.resumeProgress(
                phase: Phase.queueEntries,
                context: cacheContext
            )
            queueCheckpointSaved = Self.recordCheckpoint(
                phase: Phase.queueEntries,
                result: queueResume.result + outcome.queueDelta,
                cursor: nextCursor.encoded,
                completed: outcome.reachedEnd,
                context: cacheContext
            )
            checkpointSaveCount += 1
        }
        let phaseCheckpointSaved = Self.recordCheckpoint(
            phase: phase,
            result: combined,
            cursor: nextCursor.encoded,
            completed: outcome.reachedEnd && queueCheckpointSaved,
            error: outcome.error ?? (queueCheckpointSaved ? nil : "queue_checkpoint_save_failed"),
            context: cacheContext
        )
        let allCheckpointsSaved = phaseCheckpointSaved && queueCheckpointSaved
        if allCheckpointsSaved == false {
            outcome.error = "checkpoint_save_failed"
            outcome.reachedEnd = false
        }
        let saveDuration = Date().timeIntervalSince(saveStartedAt)

        let footprintAfter = MemoryFootprint.current()
        CrashBreadcrumbs.shared.record(
            "store_split_migration_slice",
            details: "phase=\(phase),processed=\(outcome.processed),end=\(outcome.reachedEnd),footprint=\(MemoryFootprint.formattedDelta(before: footprintBefore, after: footprintAfter))"
        )

        let status: StoreSplitSliceReport.Status
        if outcome.error != nil {
            status = .failed
        } else if shouldContinue() == false {
            status = .cancelled
        } else if outcome.reachedEnd {
            status = Self.currentPhase(cache: cacheContext) == nil
                ? .completed
                : .phaseCompleted
        } else {
            status = .advanced
        }

        return StoreSplitSliceReport(
            status: status,
            phase: phase,
            processed: outcome.processed,
            mutations: outcome.delta.inserted + outcome.delta.updated,
            saveCount: checkpointSaveCount,
            saveDuration: saveDuration,
            footprintBefore: footprintBefore,
            footprintAfter: footprintAfter,
            error: outcome.error
        )
    }

    private func runToCompletion(
        includeAIContent: Bool
    ) async -> StoreSplitMigrationResult {
        CrashBreadcrumbs.shared.record(
            "store_split_migration_started",
            details: "version=\(Self.migrationVersion)"
        )

        var result = StoreSplitMigrationResult()
        for phase in Self.slicePhaseOrder
        where includeAIContent || (phase != Phase.aiTranscripts && phase != Phase.aiChapters) {
            guard Task.isCancelled == false else { return result }
            if Self.isBaselineMaintenancePhase(phase) {
                let phaseResult = processBaselineMaintenanceFully(phase)
                if phase == Phase.listeningBaselinePublication {
                    result.listeningBaselinePublication = phaseResult
                } else {
                    result.listeningBaselinePreparation = result.listeningBaselinePreparation + phaseResult
                }
                if phaseResult.failed > 0 { break }
                continue
            }
            if phase == Phase.listeningHistoryVerification {
                let phaseResult = processHistoryVerificationFully()
                result.listeningHistoryVerification = phaseResult
                if phaseResult.failed > 0 { break }
                continue
            }
            if phase == Phase.listeningBaselineVerificationScan
                || phase == Phase.listeningBaselineVerification
                || phase == Phase.listeningBaselineVerificationComparison {
                let phaseResult = processBaselineVerificationFully(phase)
                if phase == Phase.listeningBaselineVerificationScan {
                    result.listeningBaselineVerificationScan = phaseResult
                } else if phase == Phase.listeningBaselineVerification {
                    result.listeningBaselineVerification = phaseResult
                } else {
                    result.listeningBaselineVerificationComparison = phaseResult
                }
                if phaseResult.failed > 0 { break }
                continue
            }
            let phaseResult = processPhaseFully(phase)
            switch phase {
            case Phase.subscriptions: result.subscriptions = phaseResult.primary
            case Phase.playlists: result.playlists = phaseResult.primary
            case Phase.playlistEntries:
                result.playlistEntries = phaseResult.primary
                result.queueEntries = phaseResult.queue
            case Phase.bookmarks: result.bookmarks = phaseResult.primary
            case Phase.preferences: result.preferences = phaseResult.primary
            case Phase.episodeStates: result.episodeStates = phaseResult.primary
            case Phase.listeningSummaries: result.listeningSummaries = phaseResult.primary
            case Phase.listeningHistory: result.listeningHistory = phaseResult.primary
            case Phase.aiTranscripts: result.aiTranscripts = phaseResult.primary
            case Phase.aiChapters: result.aiChapters = phaseResult.primary
            default: break
            }
            await Task.yield()
        }

        let diagnosticsCache = Self.makeContext(for: cacheContainer)
        StoreSplitMigrationDiagnostics.recordMigrationRun()
        StoreSplitMigrationDiagnostics.recordFailedItems(
            Self.failedItemKeys(from: diagnosticsCache)
        )
        CrashBreadcrumbs.shared.record(
            "store_split_migration_completed",
            details: "failed=\(result.failedCount),subscriptions=\(result.subscriptions.scanned),episodes=\(result.episodeStates.scanned),playlists=\(result.playlists.scanned),bookmarks=\(result.bookmarks.scanned),history=\(result.listeningHistory.scanned),history_verified=\(result.listeningHistoryVerification.scanned),summaries=\(result.listeningSummaries.scanned),ai_transcripts=\(result.aiTranscripts.scanned),ai_chapters=\(result.aiChapters.scanned)"
        )
        return result
    }

    private struct HistoryVerificationCursor: Codable {
        var afterID: UUID?
        var sourceCount: Int
        var scanned: Int

        var encoded: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func decode(_ value: String?) -> Self? {
            guard let value, let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    /// A UUID keyset is used for independent history verification. A deleted
    /// boundary or changed source count fails the phase instead of falling back
    /// to an offset that can silently skip a session.
    private static func runHistoryVerificationSlice(
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        budget: StoreWorkBudget,
        footprintBefore: UInt64,
        shouldContinue: @Sendable () -> Bool,
        forceStart: Bool = false
    ) -> StoreSplitSliceReport {
        let phase = Phase.listeningHistoryVerification
        let id = checkpointID(for: phase)
        let deadline = ContinuousClock.now + budget.maximumWallTime
        var cursor: HistoryVerificationCursor
        var progress = StoreSplitMigrationPhaseResult()
        do {
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 2
            let checkpoints = try cacheContext.fetch(descriptor)
            guard checkpoints.count <= 1 else {
                return StoreSplitSliceReport(status: .failed, phase: phase, error: "listening_history_verification_checkpoint_invalid")
            }
            if !forceStart, let checkpoint = checkpoints.first {
                guard let saved = HistoryVerificationCursor.decode(checkpoint.cursor),
                      saved.scanned >= 0, saved.sourceCount >= saved.scanned else {
                    return StoreSplitSliceReport(status: .failed, phase: phase, error: "listening_history_verification_checkpoint_invalid")
                }
                cursor = saved
                progress = StoreSplitMigrationPhaseResult(
                    scanned: checkpoint.scannedCount, inserted: checkpoint.insertedCount,
                    updated: checkpoint.updatedCount, skipped: checkpoint.skippedCount,
                    failed: checkpoint.failedCount
                )
                guard progress.scanned == saved.scanned else {
                    return StoreSplitSliceReport(status: .failed, phase: phase, error: "listening_history_verification_checkpoint_invalid")
                }
            } else {
                let count = try legacyContext.fetchCount(FetchDescriptor<PlaySession>())
                cursor = HistoryVerificationCursor(afterID: nil, sourceCount: count, scanned: 0)
            }
        } catch {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "listening_history_verification_source_or_checkpoint_read_failed")
        }
        guard shouldContinue(), ContinuousClock.now < deadline else {
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        var failure: String?
        if let afterID = cursor.afterID {
            var descriptor = FetchDescriptor<PlaySession>(predicate: #Predicate { $0.id == afterID })
            descriptor.fetchLimit = 2
            do {
                let boundary = try legacyContext.fetch(descriptor)
                if boundary.count != 1 { failure = "listening_history_verification_source_boundary_lost" }
            } catch { failure = "listening_history_verification_source_fetch_failed" }
        }
        var outcome = PageOutcome()
        if failure == nil {
            outcome = verifyListeningHistoryPage(
                afterID: cursor.afterID,
                pageSize: max(1, min(listeningHistoryVerificationPageSize, budget.maximumMutations)),
                legacyContext: legacyContext,
                destinationContext: destinationContext,
                cacheContext: cacheContext,
                deadline: deadline,
                shouldContinue: shouldContinue
            )
            failure = outcome.error
        }
        guard shouldContinue() else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        if failure == nil, outcome.reachedEnd {
            do {
                let count = try legacyContext.fetchCount(FetchDescriptor<PlaySession>())
                if count != cursor.sourceCount || cursor.scanned + outcome.processed != count {
                    failure = "listening_history_verification_source_changed"
                }
            } catch { failure = "listening_history_verification_source_fetch_failed" }
        }
        if let failure {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .failed, phase: phase, error: failure)
        }
        if let boundary = outcome.boundaryKey, let afterID = UUID(uuidString: boundary) {
            cursor.afterID = afterID
        }
        cursor.scanned += outcome.processed
        progress.scanned += outcome.delta.scanned
        progress.skipped += outcome.delta.skipped
        progress.failed = 0
        guard let encoded = cursor.encoded,
              recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: outcome.reachedEnd, context: cacheContext) else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
        }
        let status: StoreSplitSliceReport.Status = outcome.reachedEnd
            ? (currentPhase(cache: cacheContext) == nil ? .completed : .phaseCompleted)
            : .advanced
        return StoreSplitSliceReport(status: status, phase: phase, processed: outcome.processed, saveCount: 1, footprintBefore: footprintBefore, footprintAfter: MemoryFootprint.current())
    }

    private func processHistoryVerificationFully() -> StoreSplitMigrationPhaseResult {
        var forceStart = true
        while !Task.isCancelled {
            let cacheContext = Self.makeContext(for: cacheContainer)
            let report = Self.runHistoryVerificationSlice(
                legacyContext: Self.makeContext(for: legacyContainer),
                destinationContext: Self.makeContext(for: userStateContainer),
                cacheContext: cacheContext,
                budget: .migrationSlice,
                footprintBefore: MemoryFootprint.current(),
                shouldContinue: { !Task.isCancelled },
                forceStart: forceStart
            )
            forceStart = false
            if report.status != .advanced {
                let id = Self.checkpointID(for: Phase.listeningHistoryVerification)
                var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 2
                guard let checkpoints = try? cacheContext.fetch(descriptor),
                      checkpoints.count == 1, let checkpoint = checkpoints.first else {
                    return StoreSplitMigrationPhaseResult(failed: report.status == .failed ? 1 : 0)
                }
                return StoreSplitMigrationPhaseResult(scanned: checkpoint.scannedCount, skipped: checkpoint.skippedCount, failed: max(checkpoint.failedCount, report.status == .failed ? 1 : 0))
            }
        }
        return StoreSplitMigrationPhaseResult()
    }

    private struct BaselineMaintenanceCursor: Codable {
        var afterID: String?

        var encoded: String? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func decode(_ value: String?) -> Self? {
            guard let value, let data = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    private enum BaselineMaintenanceError: String, Error {
        case checkpoint = "baseline_maintenance_checkpoint_invalid"
        case scratchFetch = "baseline_maintenance_scratch_fetch_failed"
        case legacyScratch = "baseline_legacy_partial_scratch_unresolved"
        case scratchConflict = "baseline_maintenance_scratch_identity_conflict"
        case invalidAggregate = "baseline_maintenance_invalid_aggregate"
        case destinationFetch = "baseline_maintenance_destination_fetch_failed"
        case destinationConflict = "baseline_maintenance_destination_identity_conflict"
        case sourceEvidence = "baseline_publication_source_evidence_unresolved"
    }

    private static func isBaselineMaintenancePhase(_ phase: String) -> Bool {
        phase == Phase.listeningBaselinePrepareAggregates
            || phase == Phase.listeningBaselinePrepareSources
            || phase == Phase.listeningBaselinePublication
    }

    private static func legacyBaselineScratchPresent(in context: ModelContext) throws -> Bool {
        let aggregatePrefix = StableIdentityKey.make("listening-baseline")
        var aggregates = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: aggregatePrefix) })
        aggregates.fetchLimit = 1
        if try !context.fetch(aggregates).isEmpty { return true }
        let sourcePrefix = StableIdentityKey.make("listening-baseline-source")
        var sources = FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id.starts(with: sourcePrefix) })
        sources.fetchLimit = 1
        return try !context.fetch(sources).isEmpty
    }

    /// Old partial scratch is recovery evidence and is never discarded here.
    /// Publication currently verifies that each candidate already has a
    /// destination baseline. Creating a missing write-once baseline requires a
    /// durable source-revision fence, which the legacy store cannot yet prove.
    private static func runBaselineMaintenanceSlice(
        phase: String,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        budget: StoreWorkBudget,
        footprintBefore: UInt64,
        shouldContinue: @Sendable () -> Bool,
        forceStart: Bool = false
    ) -> StoreSplitSliceReport {
        let deadline = ContinuousClock.now + budget.maximumWallTime
        let phaseID = checkpointID(for: phase)
        let isPublication = phase == Phase.listeningBaselinePublication
        let prefix = StableIdentityKey.make(baselineAggregateNamespace)
        var cursor = BaselineMaintenanceCursor(afterID: nil)
        var progress = StoreSplitMigrationPhaseResult()
        do {
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == phaseID })
            descriptor.fetchLimit = 2
            let checkpoints = try cacheContext.fetch(descriptor)
            guard checkpoints.count <= 1 else { throw BaselineMaintenanceError.checkpoint }
            if !forceStart, let checkpoint = checkpoints.first {
                guard let saved = BaselineMaintenanceCursor.decode(checkpoint.cursor),
                      saved.afterID == nil || saved.afterID?.hasPrefix(prefix) == true else {
                    throw BaselineMaintenanceError.checkpoint
                }
                cursor = saved
                progress = StoreSplitMigrationPhaseResult(
                    scanned: checkpoint.scannedCount, inserted: checkpoint.insertedCount,
                    updated: checkpoint.updatedCount, skipped: checkpoint.skippedCount,
                    failed: checkpoint.failedCount
                )
            }
        } catch let error as BaselineMaintenanceError {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: error.rawValue)
        } catch {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: BaselineMaintenanceError.checkpoint.rawValue)
        }
        let originalCursor = cursor
        var processed = 0
        var skipped = 0
        var reachedEnd = false
        var failure: BaselineMaintenanceError?
        let pageSize = max(1, min(40, budget.maximumMutations - 1))
        do {
            guard shouldContinue(), ContinuousClock.now < deadline else {
                return StoreSplitSliceReport(status: .cancelled, phase: phase)
            }
            if !isPublication {
                if phase == Phase.listeningBaselinePrepareAggregates {
                    let oldPrefix = StableIdentityKey.make("listening-baseline")
                    var descriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: oldPrefix) })
                    descriptor.fetchLimit = 1
                    do {
                        guard try cacheContext.fetch(descriptor).isEmpty else { throw BaselineMaintenanceError.legacyScratch }
                    } catch let error as BaselineMaintenanceError { throw error }
                    catch { throw BaselineMaintenanceError.scratchFetch }
                } else {
                    let oldPrefix = StableIdentityKey.make("listening-baseline-source")
                    var descriptor = FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id.starts(with: oldPrefix) })
                    descriptor.fetchLimit = 1
                    do {
                        guard try cacheContext.fetch(descriptor).isEmpty else { throw BaselineMaintenanceError.legacyScratch }
                    } catch let error as BaselineMaintenanceError { throw error }
                    catch { throw BaselineMaintenanceError.scratchFetch }
                }
                reachedEnd = true
            } else {
                do {
                    if try legacyBaselineScratchPresent(in: cacheContext) { throw BaselineMaintenanceError.legacyScratch }
                } catch let error as BaselineMaintenanceError { throw error }
                catch { throw BaselineMaintenanceError.scratchFetch }
                var descriptor: FetchDescriptor<CachedListeningBaselineAggregate>
                if let after = cursor.afterID {
                    descriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                        predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > after },
                        sortBy: [SortDescriptor(\CachedListeningBaselineAggregate.id)]
                    )
                } else {
                    descriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                        predicate: #Predicate { $0.id.starts(with: prefix) },
                        sortBy: [SortDescriptor(\CachedListeningBaselineAggregate.id)]
                    )
                }
                descriptor.fetchLimit = pageSize
                let rows: [CachedListeningBaselineAggregate]
                do { rows = try cacheContext.fetch(descriptor) }
                catch { throw BaselineMaintenanceError.scratchFetch }
                for aggregate in rows {
                    guard shouldContinue() else {
                        destinationContext.rollback()
                        cacheContext.rollback()
                        return StoreSplitSliceReport(status: .cancelled, phase: phase)
                    }
                    if ContinuousClock.now >= deadline { break }
                    let aggregateID = aggregate.id
                    var duplicateDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == aggregateID })
                    duplicateDescriptor.fetchLimit = 2
                    let duplicates: [CachedListeningBaselineAggregate]
                    do { duplicates = try cacheContext.fetch(duplicateDescriptor) }
                    catch { throw BaselineMaintenanceError.scratchFetch }
                    guard duplicates.count == 1,
                          aggregate.id == StableIdentityKey.make(baselineAggregateNamespace, aggregate.feedURL) else {
                        throw BaselineMaintenanceError.scratchConflict
                    }
                    guard aggregate.totalSeconds.isFinite, aggregate.totalSeconds >= 0,
                          aggregate.silenceGapTimeSavedSeconds.isFinite, aggregate.silenceGapTimeSavedSeconds >= 0,
                          aggregate.playbackRateTimeSavedSeconds.isFinite, aggregate.playbackRateTimeSavedSeconds >= 0 else {
                        throw BaselineMaintenanceError.invalidAggregate
                    }
                    if aggregate.totalSeconds > 0 {
                        let feedURL = aggregate.feedURL
                        var baselineDescriptor = FetchDescriptor<ListeningBaselineSync>(predicate: #Predicate { $0.id == feedURL })
                        baselineDescriptor.fetchLimit = 2
                        let existing: [ListeningBaselineSync]
                        do { existing = try destinationContext.fetch(baselineDescriptor) }
                        catch { throw BaselineMaintenanceError.destinationFetch }
                        guard existing.count <= 1 else { throw BaselineMaintenanceError.destinationConflict }
                        guard !existing.isEmpty else { throw BaselineMaintenanceError.sourceEvidence }
                        skipped += 1
                    } else { skipped += 1 }
                    cursor.afterID = aggregate.id
                    processed += 1
                }
                reachedEnd = processed == rows.count && rows.count < pageSize
            }

            guard shouldContinue() else {
                destinationContext.rollback()
                cacheContext.rollback()
                return StoreSplitSliceReport(status: .cancelled, phase: phase)
            }
            guard shouldContinue() else {
                cacheContext.rollback()
                return StoreSplitSliceReport(status: .cancelled, phase: phase)
            }
        } catch let error as BaselineMaintenanceError {
            failure = error
        } catch {
            failure = .scratchFetch
        }
        if let failure {
            destinationContext.rollback()
            cacheContext.rollback()
            progress.failed = 1
            guard let encoded = originalCursor.encoded,
                  recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: false, error: failure.rawValue, context: cacheContext) else {
                return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
            }
            return StoreSplitSliceReport(status: .failed, phase: phase, error: failure.rawValue)
        }
        progress.scanned += processed
        progress.skipped += skipped
        progress.failed = 0
        guard let encoded = cursor.encoded,
              recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: reachedEnd, context: cacheContext) else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
        }
        let status: StoreSplitSliceReport.Status = reachedEnd
            ? (currentPhase(cache: cacheContext) == nil ? .completed : .phaseCompleted)
            : .advanced
        return StoreSplitSliceReport(status: status, phase: phase, processed: processed, saveCount: 1, footprintBefore: footprintBefore, footprintAfter: MemoryFootprint.current())
    }

    private func processBaselineMaintenanceFully(_ phase: String) -> StoreSplitMigrationPhaseResult {
        var forceStart = true
        while !Task.isCancelled {
            let cacheContext = Self.makeContext(for: cacheContainer)
            let report = Self.runBaselineMaintenanceSlice(
                phase: phase,
                destinationContext: Self.makeContext(for: userStateContainer),
                cacheContext: cacheContext,
                budget: .migrationSlice,
                footprintBefore: MemoryFootprint.current(),
                shouldContinue: { !Task.isCancelled },
                forceStart: forceStart
            )
            forceStart = false
            if report.status != .advanced {
                let id = Self.checkpointID(for: phase)
                var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 2
                guard let checkpoints = try? cacheContext.fetch(descriptor),
                      checkpoints.count == 1, let checkpoint = checkpoints.first else {
                    return StoreSplitMigrationPhaseResult(failed: report.status == .failed ? 1 : 0)
                }
                return StoreSplitMigrationPhaseResult(scanned: checkpoint.scannedCount, inserted: checkpoint.insertedCount, updated: checkpoint.updatedCount, skipped: checkpoint.skippedCount, failed: max(checkpoint.failedCount, report.status == .failed ? 1 : 0))
            }
        }
        return StoreSplitMigrationPhaseResult()
    }

    // The source summary UUID is the only indexed, immutable paging key in
    // the legacy model. An absent or duplicate UUID is an unresolved identity,
    // not permission to skip an otherwise eligible summary.
    private struct BaselineVerificationCursor: Codable {
        var runID: UUID
        var lastID: UUID?
        var lastAggregateID: String? = nil
        /// Empty represents a source with no supported summary tier.
        var tier: String

        var encoded: String? {
            guard let bytes = try? JSONEncoder().encode(self) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        static func decode(_ value: String?) -> Self? {
            guard let value, let bytes = value.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: bytes)
        }
    }

    private enum BaselineVerificationError: String, Error {
        case checkpointRead = "baseline_verification_checkpoint_read_failed"
        case checkpointInvalid = "baseline_verification_checkpoint_invalid"
        case scanNotComplete = "baseline_verification_scan_not_complete"
        case tierChanged = "baseline_verification_source_tier_changed"
        case sourceRead = "baseline_verification_source_read_failed"
        case sourceIdentity = "baseline_verification_source_identity_unresolved"
        case duplicateSource = "baseline_verification_duplicate_source_identity"
        case sourceChanged = "baseline_verification_source_changed"
        case invalidValues = "baseline_verification_invalid_values"
        case cacheRead = "baseline_verification_cache_read_failed"
        case destinationRead = "baseline_verification_destination_read_failed"
        case missingBaseline = "baseline_verification_missing_baseline"
        case duplicateBaseline = "baseline_verification_duplicate_baseline"
        case sourceLineage = "baseline_verification_source_lineage_unresolved"
        case aggregateMismatch = "baseline_verification_aggregate_mismatch"
        case fields = "baseline_verification_semantic_mismatch"
    }

    /// Runs the two local baseline checks with UUID keyset paging. Cache
    /// aggregates and the source receipt are committed with the cursor in one
    /// transaction. A second source pass checks the receipts before comparing
    /// the baseline. This is local evidence only; the global verification and
    /// CloudKit convergence gates remain separate.
    private static func runBaselineVerificationSlice(
        phase: String,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        budget: StoreWorkBudget,
        footprintBefore: UInt64,
        shouldContinue: @Sendable () -> Bool
    ) -> StoreSplitSliceReport {
        let deadline = ContinuousClock.now + budget.maximumWallTime
        let isScan = phase == Phase.listeningBaselineVerificationScan
        let phaseCheckpointID = checkpointID(for: phase)
        var progress = StoreSplitMigrationPhaseResult()
        var cursor: BaselineVerificationCursor?
        var checkpoint: StoreSplitMigrationCheckpoint?
        do {
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == phaseCheckpointID }
            )
            descriptor.fetchLimit = 2
            let checkpoints = try cacheContext.fetch(descriptor)
            guard checkpoints.count <= 1 else { throw BaselineVerificationError.checkpointInvalid }
            checkpoint = checkpoints.first
            if let checkpoint {
                guard let saved = BaselineVerificationCursor.decode(checkpoint.cursor) else {
                    throw BaselineVerificationError.checkpointInvalid
                }
                cursor = saved
                progress = StoreSplitMigrationPhaseResult(
                    scanned: checkpoint.scannedCount,
                    inserted: checkpoint.insertedCount,
                    updated: checkpoint.updatedCount,
                    skipped: checkpoint.skippedCount,
                    failed: checkpoint.failedCount
                )
            } else if isScan {
                let tier: String?
                do { tier = try selectedBaselinePeriodKind(in: legacyContext) }
                catch { throw BaselineVerificationError.sourceRead }
                cursor = BaselineVerificationCursor(runID: UUID(), lastID: nil, tier: tier ?? "")
            } else {
                let scanID = checkpointID(for: Phase.listeningBaselineVerificationScan)
                var scanDescriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                    predicate: #Predicate { $0.id == scanID }
                )
                scanDescriptor.fetchLimit = 2
                let scans = try cacheContext.fetch(scanDescriptor)
                guard scans.count == 1, let scan = scans.first,
                      scan.completedAt != nil,
                      let saved = BaselineVerificationCursor.decode(scan.cursor) else {
                    throw BaselineVerificationError.scanNotComplete
                }
                cursor = BaselineVerificationCursor(runID: saved.runID, lastID: nil, tier: saved.tier)
            }
            if !isScan {
                let scanID = checkpointID(for: Phase.listeningBaselineVerificationScan)
                var scanDescriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == scanID })
                scanDescriptor.fetchLimit = 2
                let scans = try cacheContext.fetch(scanDescriptor)
                guard scans.count == 1, let scan = scans.first, scan.completedAt != nil,
                      let saved = BaselineVerificationCursor.decode(scan.cursor) else {
                    throw BaselineVerificationError.scanNotComplete
                }
                if saved.runID != cursor?.runID || saved.tier != cursor?.tier {
                    // Only verification scratch progress is reset; old ledger
                    // rows are namespaced by run ID and cannot enter this pass.
                    cursor = BaselineVerificationCursor(runID: saved.runID, lastID: nil, tier: saved.tier)
                    progress = StoreSplitMigrationPhaseResult()
                }
            }
        } catch let error as BaselineVerificationError {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: error.rawValue)
        } catch {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: BaselineVerificationError.checkpointRead.rawValue)
        }

        guard var cursor else {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: BaselineVerificationError.checkpointInvalid.rawValue)
        }
        guard shouldContinue(), ContinuousClock.now < deadline else {
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        guard StoreSplitMigrationVerifier.invalidateForMigrationStage(in: cacheContext) else {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "baseline_verification_invalidation_failed")
        }

        let committedCursor = cursor
        var processed = 0
        var mutations = 0
        var newFeeds = 0
        var reachedEnd = false
        var failure: BaselineVerificationError?
        do {
            let kind = cursor.tier.isEmpty ? nil : cursor.tier
            guard kind == nil || ["year", "month", "week", "day"].contains(cursor.tier) else {
                throw BaselineVerificationError.checkpointInvalid
            }
            let markerID = StableIdentityKey.make("baseline-verification-tier", cursor.runID.uuidString)
            var markerDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                predicate: #Predicate { $0.id == markerID }
            )
            markerDescriptor.fetchLimit = 2
            let markers: [CachedListeningBaselineAggregate]
            do { markers = try cacheContext.fetch(markerDescriptor) }
            catch { throw BaselineVerificationError.cacheRead }
            guard markers.count <= 1 else { throw BaselineVerificationError.cacheRead }
            let marker = markers.first
            let tier = kind ?? ""
            if let marker {
                guard marker.feedURL == tier else { throw BaselineVerificationError.tierChanged }
            } else if isScan {
                cacheContext.insert(CachedListeningBaselineAggregate(id: markerID, feedURL: tier, podcastName: nil))
                mutations += 1
            } else {
                throw BaselineVerificationError.checkpointInvalid
            }

            let rows: [PlaySessionSummary]
            let pageSize = max(1, min(40, budget.maximumMutations / 3))
            if let kind {
                var descriptor: FetchDescriptor<PlaySessionSummary>
                if let lastID = cursor.lastID {
                    descriptor = FetchDescriptor<PlaySessionSummary>(
                        predicate: #Predicate<PlaySessionSummary> { summary in
                            if let id = summary.id { summary.periodKind == kind && id > lastID } else { false }
                        },
                        sortBy: [SortDescriptor(\PlaySessionSummary.id)]
                    )
                } else {
                    descriptor = FetchDescriptor<PlaySessionSummary>(
                        predicate: #Predicate { $0.periodKind == kind },
                        sortBy: [SortDescriptor(\PlaySessionSummary.id)]
                    )
                }
                descriptor.fetchLimit = pageSize
                do { rows = try legacyContext.fetch(descriptor) }
                catch { throw BaselineVerificationError.sourceRead }
            } else {
                rows = []
            }

            for summary in rows {
                guard shouldContinue() else {
                    cacheContext.rollback()
                    return StoreSplitSliceReport(status: .cancelled, phase: phase)
                }
                if ContinuousClock.now >= deadline { break }
                guard let id = summary.id, let kind else { throw BaselineVerificationError.sourceIdentity }
                var duplicateDescriptor = FetchDescriptor<PlaySessionSummary>(
                    predicate: #Predicate { $0.periodKind == kind && $0.id == id }
                )
                duplicateDescriptor.fetchLimit = 2
                do {
                    guard try legacyContext.fetch(duplicateDescriptor).count == 1 else {
                        throw BaselineVerificationError.duplicateSource
                    }
                } catch let error as BaselineVerificationError { throw error }
                catch { throw BaselineVerificationError.sourceRead }

                let feedURL = summary.podcastFeed.map(PodcastFeedIdentity.normalizedFeedURLString)
                    ?? ListeningBaselineSync.allPodcastsFeedURL
                let seconds = summary.totalSeconds ?? 0
                let silence = summary.silenceGapTimeSavedSeconds ?? 0
                let rate = summary.playbackRateTimeSavedSeconds ?? 0
                guard seconds.isFinite, silence.isFinite, rate.isFinite else {
                    throw BaselineVerificationError.invalidValues
                }
                let payload = StableIdentityKey.make(
                    kind, summary.periodStart.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil",
                    feedURL, summary.podcastName.map { "value:\($0)" } ?? "nil", String(seconds.bitPattern),
                    String(silence.bitPattern), String(rate.bitPattern)
                )
                let logicalID = StableIdentityKey.make("baseline-verification-source", cursor.runID.uuidString, id.uuidString)
                let payloadID = StableIdentityKey.make("baseline-verification-payload", cursor.runID.uuidString, id.uuidString, AIContentSyncCodec.sha256Hex(Data(payload.utf8)))
                func hasReceipt(_ id: String) throws -> Bool {
                    var descriptor = FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 2
                    do {
                        let receipts = try cacheContext.fetch(descriptor)
                        guard receipts.count <= 1 else { throw BaselineVerificationError.cacheRead }
                        return receipts.first != nil
                    }
                    catch let error as BaselineVerificationError { throw error }
                    catch { throw BaselineVerificationError.cacheRead }
                }
                let logicalExists = try hasReceipt(logicalID)
                let payloadExists = try hasReceipt(payloadID)
                if isScan {
                    if logicalExists {
                        guard payloadExists else { throw BaselineVerificationError.sourceChanged }
                    } else {
                        cacheContext.insert(CachedListeningBaselineSource(id: logicalID))
                        cacheContext.insert(CachedListeningBaselineSource(id: payloadID))
                        mutations += 2
                        if summary.periodStart != nil {
                            let aggregateID = StableIdentityKey.make("baseline-verification-aggregate", cursor.runID.uuidString, feedURL)
                            var aggregateDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == aggregateID })
                            aggregateDescriptor.fetchLimit = 2
                            let aggregate: CachedListeningBaselineAggregate
                            do {
                                let aggregates = try cacheContext.fetch(aggregateDescriptor)
                                guard aggregates.count <= 1 else { throw BaselineVerificationError.cacheRead }
                                if let existing = aggregates.first {
                                    aggregate = existing
                                } else {
                                    aggregate = CachedListeningBaselineAggregate(id: aggregateID, feedURL: feedURL, podcastName: summary.podcastName)
                                    cacheContext.insert(aggregate)
                                }
                            } catch { throw BaselineVerificationError.cacheRead }
                            aggregate.totalSeconds += max(0, seconds)
                            aggregate.silenceGapTimeSavedSeconds += max(0, silence)
                            aggregate.playbackRateTimeSavedSeconds += max(0, rate)
                            mutations += 1
                        }
                    }
                } else {
                    guard logicalExists, payloadExists else { throw BaselineVerificationError.sourceChanged }
                    let recheckID = StableIdentityKey.make("baseline-verification-recheck", cursor.runID.uuidString, id.uuidString)
                    let rechecked = try hasReceipt(recheckID)
                    if summary.periodStart != nil {
                        let firstID = StableIdentityKey.make("baseline-verification-aggregate", cursor.runID.uuidString, feedURL)
                        var firstDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == firstID })
                        firstDescriptor.fetchLimit = 2
                        let firstMatches: [CachedListeningBaselineAggregate]
                        do { firstMatches = try cacheContext.fetch(firstDescriptor) }
                        catch { throw BaselineVerificationError.cacheRead }
                        guard firstMatches.count == 1, firstMatches[0].feedURL == feedURL else {
                            throw BaselineVerificationError.cacheRead
                        }
                        let feedReceiptID = StableIdentityKey.make("baseline-verification-recheck-feed", cursor.runID.uuidString, feedURL)
                        let feedSeen = try hasReceipt(feedReceiptID)
                        let aggregateID = StableIdentityKey.make("baseline-verification-second-aggregate", cursor.runID.uuidString, feedURL)
                        var aggregateDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == aggregateID })
                        aggregateDescriptor.fetchLimit = 2
                        let aggregate: CachedListeningBaselineAggregate
                        do {
                            let aggregates = try cacheContext.fetch(aggregateDescriptor)
                            guard aggregates.count <= 1 else { throw BaselineVerificationError.cacheRead }
                            if feedSeen {
                                guard let value = aggregates.first, value.feedURL == feedURL else { throw BaselineVerificationError.cacheRead }
                                aggregate = value
                            } else {
                                guard aggregates.isEmpty, !rechecked else { throw BaselineVerificationError.cacheRead }
                                cacheContext.insert(CachedListeningBaselineSource(id: feedReceiptID))
                                aggregate = CachedListeningBaselineAggregate(id: aggregateID, feedURL: feedURL, podcastName: summary.podcastName)
                                cacheContext.insert(aggregate)
                                newFeeds += 1
                                mutations += 1
                            }
                        } catch let error as BaselineVerificationError { throw error }
                        catch { throw BaselineVerificationError.cacheRead }
                        if !rechecked {
                            aggregate.totalSeconds += max(0, seconds)
                            aggregate.silenceGapTimeSavedSeconds += max(0, silence)
                            aggregate.playbackRateTimeSavedSeconds += max(0, rate)
                            mutations += 1
                        }
                    }
                    if !rechecked {
                        cacheContext.insert(CachedListeningBaselineSource(id: recheckID))
                        mutations += 1
                    }
                }
                cursor.lastID = id
                processed += 1
            }
            reachedEnd = processed == rows.count && rows.count < pageSize
            if reachedEnd {
                let latestKind: String?
                do { latestKind = try selectedBaselinePeriodKind(in: legacyContext) }
                catch { throw BaselineVerificationError.sourceRead }
                guard latestKind == kind else { throw BaselineVerificationError.tierChanged }
            }
            if reachedEnd && !isScan {
                let scanID = checkpointID(for: Phase.listeningBaselineVerificationScan)
                var scanDescriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == scanID })
                scanDescriptor.fetchLimit = 2
                let scans: [StoreSplitMigrationCheckpoint]
                do { scans = try cacheContext.fetch(scanDescriptor) }
                catch { throw BaselineVerificationError.checkpointRead }
                guard scans.count == 1, let scan = scans.first else { throw BaselineVerificationError.checkpointInvalid }
                let sourceCount: Int
                do {
                    if let kind {
                        sourceCount = try legacyContext.fetchCount(FetchDescriptor<PlaySessionSummary>(predicate: #Predicate { $0.periodKind == kind }))
                    } else { sourceCount = 0 }
                } catch { throw BaselineVerificationError.sourceRead }
                guard scan.scannedCount == progress.scanned + processed,
                      scan.scannedCount == sourceCount else { throw BaselineVerificationError.sourceChanged }
                let runID = cursor.runID.uuidString
                let firstPrefix = StableIdentityKey.make("baseline-verification-aggregate", runID)
                let secondPrefix = StableIdentityKey.make("baseline-verification-second-aggregate", runID)
                let feedPrefix = StableIdentityKey.make("baseline-verification-recheck-feed", runID)
                do {
                    let firstCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: firstPrefix) }))
                    let secondCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: secondPrefix) }))
                    let feedCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id.starts(with: feedPrefix) }))
                    guard firstCount == secondCount, secondCount == feedCount,
                          feedCount == progress.updated + newFeeds else { throw BaselineVerificationError.aggregateMismatch }
                } catch let error as BaselineVerificationError { throw error }
                catch { throw BaselineVerificationError.cacheRead }
            }
        } catch let error as BaselineVerificationError {
            failure = error
        } catch {
            failure = .sourceRead
        }

        if let failure {
            cacheContext.rollback()
            progress.failed = 1
            guard let encoded = committedCursor.encoded,
                  recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: false, error: failure.rawValue, context: cacheContext) else {
                return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
            }
            return StoreSplitSliceReport(status: .failed, phase: phase, error: failure.rawValue)
        }
        guard shouldContinue() else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        progress.scanned += processed
        progress.updated += newFeeds
        progress.failed = 0
        guard let encoded = cursor.encoded,
              recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: reachedEnd, context: cacheContext) else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
        }
        let status: StoreSplitSliceReport.Status = reachedEnd
            ? (currentPhase(cache: cacheContext) == nil ? .completed : .phaseCompleted)
            : .advanced
        return StoreSplitSliceReport(status: status, phase: phase, processed: processed, mutations: mutations, saveCount: 1, footprintBefore: footprintBefore, footprintAfter: MemoryFootprint.current())
    }

    /// Compare the independently accumulated feed totals and the portable
    /// baseline in bounded keyset pages. The earlier summary passes are only
    /// local evidence; delayed imports still require a fresh verification.
    private static func runBaselineAggregateVerificationSlice(
        phase: String,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        budget: StoreWorkBudget,
        footprintBefore: UInt64,
        shouldContinue: @Sendable () -> Bool
    ) -> StoreSplitSliceReport {
        let deadline = ContinuousClock.now + budget.maximumWallTime
        let phaseID = checkpointID(for: phase)
        let secondID = checkpointID(for: Phase.listeningBaselineVerification)
        let scanID = checkpointID(for: Phase.listeningBaselineVerificationScan)
        func readCheckpoint(_ id: String) throws -> StoreSplitMigrationCheckpoint? {
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 2
            do {
                let rows = try cacheContext.fetch(descriptor)
                guard rows.count <= 1 else { throw BaselineVerificationError.checkpointInvalid }
                return rows.first
            } catch let error as BaselineVerificationError { throw error }
            catch { throw BaselineVerificationError.checkpointRead }
        }

        var progress = StoreSplitMigrationPhaseResult()
        let scan: StoreSplitMigrationCheckpoint
        let expectedFeedCount: Int
        let cursorAtStart: BaselineVerificationCursor
        do {
            guard let sourceScan = try readCheckpoint(scanID), sourceScan.completedAt != nil,
                  let sourceCursor = BaselineVerificationCursor.decode(sourceScan.cursor),
                  let second = try readCheckpoint(secondID), second.completedAt != nil,
                  let secondCursor = BaselineVerificationCursor.decode(second.cursor),
                  sourceCursor.runID == secondCursor.runID,
                  sourceCursor.tier == secondCursor.tier,
                  sourceScan.scannedCount == second.scannedCount else {
                throw BaselineVerificationError.scanNotComplete
            }
            scan = sourceScan
            expectedFeedCount = second.updatedCount
            if let checkpoint = try readCheckpoint(phaseID) {
                guard let saved = BaselineVerificationCursor.decode(checkpoint.cursor),
                      saved.lastID == nil else { throw BaselineVerificationError.checkpointInvalid }
                if saved.runID == sourceCursor.runID && saved.tier == sourceCursor.tier {
                    cursorAtStart = saved
                    progress = StoreSplitMigrationPhaseResult(
                        scanned: checkpoint.scannedCount, inserted: checkpoint.insertedCount,
                        updated: checkpoint.updatedCount, skipped: checkpoint.skippedCount,
                        failed: checkpoint.failedCount
                    )
                } else {
                    cursorAtStart = BaselineVerificationCursor(runID: sourceCursor.runID, lastID: nil, tier: sourceCursor.tier)
                }
            } else {
                cursorAtStart = BaselineVerificationCursor(runID: sourceCursor.runID, lastID: nil, tier: sourceCursor.tier)
            }
        } catch let error as BaselineVerificationError {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: error.rawValue)
        } catch {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: BaselineVerificationError.checkpointRead.rawValue)
        }

        guard shouldContinue(), ContinuousClock.now < deadline else {
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        guard StoreSplitMigrationVerifier.invalidateForMigrationStage(in: cacheContext) else {
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "baseline_verification_invalidation_failed")
        }
        var cursor = cursorAtStart
        var processed = 0
        var reachedEnd = false
        var failure: BaselineVerificationError?
        do {
            let runID = cursor.runID.uuidString
            let firstPrefix = StableIdentityKey.make("baseline-verification-aggregate", runID)
            let secondPrefix = StableIdentityKey.make("baseline-verification-second-aggregate", runID)
            if let last = cursor.lastAggregateID, !last.hasPrefix(firstPrefix) {
                throw BaselineVerificationError.checkpointInvalid
            }
            let markerID = StableIdentityKey.make("baseline-verification-tier", runID)
            var markerDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == markerID })
            markerDescriptor.fetchLimit = 2
            let markers: [CachedListeningBaselineAggregate]
            do { markers = try cacheContext.fetch(markerDescriptor) }
            catch { throw BaselineVerificationError.cacheRead }
            guard markers.count == 1, markers[0].feedURL == cursor.tier else {
                throw BaselineVerificationError.cacheRead
            }

            var descriptor: FetchDescriptor<CachedListeningBaselineAggregate>
            if let last = cursor.lastAggregateID {
                descriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                    predicate: #Predicate { $0.id.starts(with: firstPrefix) && $0.id > last },
                    sortBy: [SortDescriptor(\CachedListeningBaselineAggregate.id)]
                )
            } else {
                descriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                    predicate: #Predicate { $0.id.starts(with: firstPrefix) },
                    sortBy: [SortDescriptor(\CachedListeningBaselineAggregate.id)]
                )
            }
            let pageSize = max(1, min(40, budget.maximumMutations))
            descriptor.fetchLimit = pageSize
            let aggregates: [CachedListeningBaselineAggregate]
            do { aggregates = try cacheContext.fetch(descriptor) }
            catch { throw BaselineVerificationError.cacheRead }
            func equal(_ a: Double, _ b: Double) -> Bool {
                a.isFinite && b.isFinite && abs(a - b) <= max(0.001, max(abs(a), abs(b)) * 0.000_001)
            }
            for first in aggregates {
                guard shouldContinue() else {
                    cacheContext.rollback()
                    return StoreSplitSliceReport(status: .cancelled, phase: phase)
                }
                if ContinuousClock.now >= deadline { break }
                let feedURL = first.feedURL
                guard first.id == StableIdentityKey.make("baseline-verification-aggregate", runID, feedURL) else {
                    throw BaselineVerificationError.cacheRead
                }
                let firstID = first.id
                var firstDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == firstID })
                firstDescriptor.fetchLimit = 2
                let secondID = StableIdentityKey.make("baseline-verification-second-aggregate", runID, feedURL)
                var secondDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id == secondID })
                secondDescriptor.fetchLimit = 2
                let firstMatches: [CachedListeningBaselineAggregate]
                let secondMatches: [CachedListeningBaselineAggregate]
                do {
                    firstMatches = try cacheContext.fetch(firstDescriptor)
                    secondMatches = try cacheContext.fetch(secondDescriptor)
                } catch { throw BaselineVerificationError.cacheRead }
                guard firstMatches.count == 1, secondMatches.count == 1,
                      let second = secondMatches.first, second.feedURL == feedURL else {
                    throw BaselineVerificationError.cacheRead
                }
                let feedReceiptID = StableIdentityKey.make("baseline-verification-recheck-feed", runID, feedURL)
                var feedReceiptDescriptor = FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id == feedReceiptID })
                feedReceiptDescriptor.fetchLimit = 2
                do {
                    guard try cacheContext.fetch(feedReceiptDescriptor).count == 1 else {
                        throw BaselineVerificationError.cacheRead
                    }
                } catch let error as BaselineVerificationError { throw error }
                catch { throw BaselineVerificationError.cacheRead }
                guard equal(first.totalSeconds, second.totalSeconds),
                      equal(first.silenceGapTimeSavedSeconds, second.silenceGapTimeSavedSeconds),
                      equal(first.playbackRateTimeSavedSeconds, second.playbackRateTimeSavedSeconds) else {
                    throw BaselineVerificationError.aggregateMismatch
                }
                if first.totalSeconds > 0 {
                    var baselineDescriptor = FetchDescriptor<ListeningBaselineSync>(predicate: #Predicate { $0.id == feedURL })
                    baselineDescriptor.fetchLimit = 2
                    let baselines: [ListeningBaselineSync]
                    do { baselines = try destinationContext.fetch(baselineDescriptor) }
                    catch { throw BaselineVerificationError.destinationRead }
                    guard baselines.count <= 1 else { throw BaselineVerificationError.duplicateBaseline }
                    guard let baseline = baselines.first else { throw BaselineVerificationError.missingBaseline }
                    guard baseline.capturedByDeviceID == ListeningDeviceIdentity.current().id else {
                        throw BaselineVerificationError.sourceLineage
                    }
                    guard baseline.feedURL == feedURL,
                          equal(baseline.totalSeconds, first.totalSeconds),
                          equal(baseline.silenceGapTimeSavedSeconds, first.silenceGapTimeSavedSeconds),
                          equal(baseline.playbackRateTimeSavedSeconds, first.playbackRateTimeSavedSeconds) else {
                        throw BaselineVerificationError.fields
                    }
                }
                cursor.lastAggregateID = first.id
                processed += 1
            }
            reachedEnd = processed == aggregates.count && aggregates.count < pageSize
            if reachedEnd {
                let firstCount: Int
                let secondCount: Int
                let feedCount: Int
                let feedPrefix = StableIdentityKey.make("baseline-verification-recheck-feed", runID)
                do {
                    firstCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: firstPrefix) }))
                    secondCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: secondPrefix) }))
                    feedCount = try cacheContext.fetchCount(FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id.starts(with: feedPrefix) }))
                } catch { throw BaselineVerificationError.cacheRead }
                guard firstCount == secondCount, secondCount == feedCount,
                      feedCount == expectedFeedCount, firstCount == progress.scanned + processed else {
                    throw BaselineVerificationError.aggregateMismatch
                }
                let kind = cursor.tier.isEmpty ? nil : cursor.tier
                let latestKind: String?
                let sourceCount: Int
                do {
                    latestKind = try selectedBaselinePeriodKind(in: legacyContext)
                    if let kind {
                        sourceCount = try legacyContext.fetchCount(FetchDescriptor<PlaySessionSummary>(predicate: #Predicate { $0.periodKind == kind }))
                    } else { sourceCount = 0 }
                } catch { throw BaselineVerificationError.sourceRead }
                guard latestKind == kind else { throw BaselineVerificationError.tierChanged }
                guard sourceCount == scan.scannedCount else { throw BaselineVerificationError.sourceChanged }
            }
        } catch let error as BaselineVerificationError {
            failure = error
        } catch {
            failure = .cacheRead
        }
        if let failure {
            cacheContext.rollback()
            progress.failed = 1
            guard let encoded = cursorAtStart.encoded,
                  recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: false, error: failure.rawValue, context: cacheContext) else {
                return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
            }
            return StoreSplitSliceReport(status: .failed, phase: phase, error: failure.rawValue)
        }
        guard shouldContinue() else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .cancelled, phase: phase)
        }
        progress.scanned += processed
        progress.failed = 0
        guard let encoded = cursor.encoded,
              recordCheckpoint(phase: phase, result: progress, cursor: encoded, completed: reachedEnd, context: cacheContext) else {
            cacheContext.rollback()
            return StoreSplitSliceReport(status: .failed, phase: phase, error: "checkpoint_save_failed")
        }
        let status: StoreSplitSliceReport.Status = reachedEnd
            ? (currentPhase(cache: cacheContext) == nil ? .completed : .phaseCompleted)
            : .advanced
        return StoreSplitSliceReport(status: status, phase: phase, processed: processed, saveCount: 1, footprintBefore: footprintBefore, footprintAfter: MemoryFootprint.current())
    }

    private func processBaselineVerificationFully(_ phase: String) -> StoreSplitMigrationPhaseResult {
        while !Task.isCancelled {
            let context = Self.makeContext(for: cacheContainer)
            let handler = phase == Phase.listeningBaselineVerificationComparison
                ? Self.runBaselineAggregateVerificationSlice
                : Self.runBaselineVerificationSlice
            let report: StoreSplitSliceReport = handler(
                phase,
                Self.makeContext(for: legacyContainer),
                Self.makeContext(for: userStateContainer),
                context,
                .migrationSlice,
                MemoryFootprint.current(),
                { !Task.isCancelled }
            )
            if report.status != .advanced {
                let id = Self.checkpointID(for: phase)
                var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 2
                guard let checkpoints = try? context.fetch(descriptor),
                      checkpoints.count == 1,
                      let checkpoint = checkpoints.first else {
                    return StoreSplitMigrationPhaseResult(failed: report.status == .failed ? 1 : 0)
                }
                return StoreSplitMigrationPhaseResult(scanned: checkpoint.scannedCount, inserted: checkpoint.insertedCount, updated: checkpoint.updatedCount, skipped: checkpoint.skippedCount, failed: max(checkpoint.failedCount, report.status == .failed ? 1 : 0))
            }
        }
        return StoreSplitMigrationPhaseResult()
    }

    private struct PhaseRunResult {
        var primary = StoreSplitMigrationPhaseResult()
        var queue = StoreSplitMigrationPhaseResult()
    }

    /// Processes an entire phase one page at a time, recreating contexts between
    /// pages so the whole-run path stays memory bounded too. Always re-scans from
    /// offset 0, which keeps re-runs idempotent (each record resolves to a skip).
    private func processPhaseFully(_ phase: String) -> PhaseRunResult {
        var run = PhaseRunResult()
        var offset = 0
        var boundaryKey: String?
        while true {
            // Each page runs inside its own autorelease pool so the faulted
            // object graph and the autoreleased CoreFoundation temporaries
            // (CFString/NSURL backing the row data) are released between pages
            // instead of accumulating across the whole phase.
            let outcome = autoreleasepool { () -> PageOutcome in
                let legacyContext = Self.makeContext(for: legacyContainer)
                let userStateContext = Self.makeContext(for: userStateContainer)
                let cacheContext = Self.makeContext(for: cacheContainer)

                var outcome = processPage(
                    phase: phase,
                    offset: offset,
                    pageSize: Self.basePageSize(for: phase),
                    legacyContext: legacyContext,
                    userStateContext: userStateContext,
                    cacheContext: cacheContext,
                    shouldContinue: { Task.isCancelled == false }
                )
                run.primary = run.primary + outcome.delta
                run.queue = run.queue + outcome.queueDelta
                offset += outcome.processed
                boundaryKey = outcome.boundaryKey ?? boundaryKey
                // Recorded in the same form the slice engine reads, so a run cut
                // short here resumes safely there.
                let cursor = SliceCursor(offset: offset, boundaryKey: boundaryKey)

                var queueSaved = true
                if phase == Phase.playlistEntries {
                    queueSaved = Self.recordCheckpoint(
                        phase: Phase.queueEntries,
                        result: run.queue,
                        cursor: cursor.encoded,
                        completed: outcome.reachedEnd,
                        context: cacheContext
                    )
                }
                let phaseSaved = Self.recordCheckpoint(
                    phase: phase,
                    result: run.primary,
                    cursor: cursor.encoded,
                    completed: outcome.reachedEnd && queueSaved,
                    error: outcome.error ?? (queueSaved ? nil : "queue_checkpoint_save_failed"),
                    context: cacheContext
                )
                let checkpointsSaved = phaseSaved && queueSaved
                if checkpointsSaved == false {
                    outcome.error = "checkpoint_save_failed"
                    outcome.reachedEnd = false
                }
                return outcome
            }

            if outcome.reachedEnd || outcome.error != nil || Task.isCancelled {
                break
            }
        }
        return run
    }

    // MARK: - Page processing

    private struct PageOutcome {
        var delta = StoreSplitMigrationPhaseResult()
        var queueDelta = StoreSplitMigrationPhaseResult()
        var processed = 0
        var reachedEnd = true
        var error: String?
        /// Identifies the last source row this page consumed, so the next slice
        /// can resume from that row rather than from a raw offset.
        var boundaryKey: String?
    }

    private func processPage(
        phase: String,
        offset: Int,
        pageSize: Int,
        legacyContext: ModelContext,
        userStateContext: ModelContext,
        cacheContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        switch phase {
        case Phase.subscriptions:
            return Self.processSubscriptionsPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.playlists:
            return Self.processPlaylistsPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.playlistEntries:
            return Self.processPlaylistEntriesPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.bookmarks:
            return Self.processBookmarksPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.preferences:
            return Self.processPreferencesPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.episodeStates:
            return Self.processEpisodeStatesPage(
                offset: offset,
                pageSize: pageSize,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.listeningSummaries:
            return Self.processListeningSummaries(
                offset: offset,
                pageSize: pageSize,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                cacheContext: cacheContext,
                shouldContinue: shouldContinue
            )
        case Phase.listeningHistory:
            return Self.processListeningHistoryPage(
                offset: offset,
                pageSize: pageSize,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                cacheContext: cacheContext,
                shouldContinue: shouldContinue
            )
        case Phase.aiTranscripts:
            return Self.processAITranscriptPage(
                offset: offset,
                legacyContext: legacyContext,
                cacheContext: cacheContext,
                shouldContinue: shouldContinue
            )
        case Phase.aiChapters:
            return Self.processAIChapterPage(
                offset: offset,
                legacyContext: legacyContext,
                cacheContext: cacheContext,
                shouldContinue: shouldContinue
            )
        default:
            return PageOutcome()
        }
    }

    private static func basePageSize(for phase: String) -> Int {
        switch phase {
        case Phase.episodeStates: episodePageSize
        case Phase.listeningSummaries: listeningSummaryPageSize
        case Phase.listeningHistory: listeningHistoryPageSize
        case Phase.listeningHistoryVerification: listeningHistoryVerificationPageSize
        default: defaultPageSize
        }
    }

    // MARK: - Stable cursors

    /// The stable key of the last row a page actually consumed.
    ///
    /// Pages count `processed` in fetch order, one per row, so the row at
    /// `processed - 1` is the boundary — including a page cut short by
    /// cancellation.
    private static func boundaryKey<T: PersistentModel>(
        of page: [T],
        processed: Int
    ) -> String? {
        guard processed > 0, processed <= page.count else { return nil }
        return rowKey(page[processed - 1].persistentModelID)
    }

    /// A comparable string form of a row identity. Only ever compared against
    /// other keys produced here, so the encoding just has to be deterministic.
    private static func rowKey(_ id: PersistentIdentifier) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(id) else {
            return String(describing: id)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Corrects a checkpointed offset against the live source before paging.
    ///
    /// Returns the position right after the boundary row's *current* index, so
    /// rows that shifted while the app kept using the legacy store are neither
    /// skipped nor re-scanned. Falls back to restarting the phase when the
    /// boundary row is gone or has moved further than the search window.
    private static func resolvedOffset(
        phase: String,
        cursor: SliceCursor,
        legacyContext: ModelContext
    ) -> (offset: Int, didRelocateFail: Bool) {
        guard cursor.offset > 0, let boundaryKey = cursor.boundaryKey else {
            return (cursor.offset, cursor.didRelocateFail)
        }
        guard let located = locate(
            phase: phase,
            boundaryKey: boundaryKey,
            offset: cursor.offset,
            legacyContext: legacyContext
        ) else {
            CrashBreadcrumbs.shared.record(
                "store_split_migration_cursor_lost",
                details: "phase=\(phase),offset=\(cursor.offset),rescan=\(cursor.didRelocateFail == false)"
            )
            // The boundary row is gone or moved further than the window. Re-scan
            // the phase once — every write is idempotent, so the pass resolves to
            // skips — but never twice in a row.
            return (cursor.didRelocateFail ? cursor.offset : 0, true)
        }
        return (located, false)
    }

    private static func locate(
        phase: String,
        boundaryKey: String,
        offset: Int,
        legacyContext: ModelContext
    ) -> Int? {
        switch phase {
        case Phase.subscriptions:
            return relocate(
                FetchDescriptor<Podcast>(sortBy: SourceOrder.podcasts),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: defaultPageSize, context: legacyContext
            )
        case Phase.playlists:
            return relocate(
                FetchDescriptor<Playlist>(sortBy: SourceOrder.playlists),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: defaultPageSize, context: legacyContext
            )
        case Phase.playlistEntries:
            return relocate(
                FetchDescriptor<PlaylistEntry>(sortBy: SourceOrder.playlistEntries),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: defaultPageSize, context: legacyContext
            )
        case Phase.bookmarks:
            return relocateBookmark(boundaryKey: boundaryKey, context: legacyContext)
        case Phase.preferences:
            return relocate(
                FetchDescriptor<PodcastSettings>(sortBy: SourceOrder.preferences),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: defaultPageSize, context: legacyContext
            )
        case Phase.episodeStates:
            return relocate(
                FetchDescriptor<Episode>(sortBy: SourceOrder.episodes),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: episodePageSize, context: legacyContext
            )
        case Phase.listeningHistory:
            return relocate(
                FetchDescriptor<PlaySession>(sortBy: SourceOrder.playSessions),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: listeningHistoryPageSize, context: legacyContext
            )
        case Phase.listeningSummaries:
            guard let kind = (try? selectedBaselinePeriodKind(in: legacyContext)) ?? nil else {
                return offset
            }
            let predicate = #Predicate<PlaySessionSummary> { $0.periodKind == kind }
            return relocate(
                FetchDescriptor<PlaySessionSummary>(
                    predicate: predicate,
                    sortBy: SourceOrder.listeningSummaries
                ),
                boundaryKey: boundaryKey,
                offset: offset,
                pageSize: listeningSummaryPageSize,
                context: legacyContext
            )
        case Phase.aiTranscripts:
            return relocate(
                FetchDescriptor<TranscriptionRecord>(sortBy: SourceOrder.transcriptionRecords),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: aiContentPageSize, context: legacyContext
            )
        case Phase.aiChapters:
            return relocate(
                FetchDescriptor<Episode>(sortBy: SourceOrder.episodes),
                boundaryKey: boundaryKey, offset: offset,
                pageSize: aiContentPageSize, context: legacyContext
            )
        default:
            return offset
        }
    }

    /// The position right after the boundary row's current index, or `nil` when
    /// the row is no longer inside the search window.
    ///
    /// The window is read with a plain fetch rather than `fetchIdentifiers`:
    /// sorted identifier fetches throw `sortingPendingChangesWithIdentifiers`
    /// whenever the store has uncommitted changes, which the live legacy store
    /// routinely does. It is bounded to a couple of pages and released
    /// immediately, so it stays inside the same memory budget as a page.
    /// The position right after the boundary bookmark in the ordering
    /// `orderedBookmarks` produces, or `nil` when that row is gone.
    ///
    /// The whole (small) list is searched rather than a window, so a bookmark
    /// deleted between slices restarts the phase instead of silently shifting
    /// every later offset by one. Cursors from before the paging change are not
    /// a concern here: that change carries a phase revision, so those
    /// checkpoints are ignored and the phase starts fresh.
    private static func relocateBookmark(
        boundaryKey: String,
        context: ModelContext
    ) -> Int? {
        guard let rows = try? orderedBookmarks(in: context) else { return nil }
        guard let index = rows.firstIndex(
            where: { rowKey($0.persistentModelID) == boundaryKey }
        ) else {
            return nil
        }
        return index + 1
    }

    private static func relocate<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        boundaryKey: String,
        offset: Int,
        pageSize: Int,
        context: ModelContext
    ) -> Int? {
        autoreleasepool {
            let window = pageSize * cursorRelocationPages
            var windowDescriptor = descriptor
            let start = max(0, offset - window)
            windowDescriptor.fetchOffset = start
            windowDescriptor.fetchLimit = (offset - start) + window
            guard let rows = try? context.fetch(windowDescriptor) else { return offset }
            guard let index = rows.firstIndex(
                where: { rowKey($0.persistentModelID) == boundaryKey }
            ) else { return nil }
            return start + index + 1
        }
    }

    // MARK: - Subscriptions

    private static func processSubscriptionsPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<Podcast>(sortBy: SourceOrder.podcasts)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = defaultPageSize

        let podcasts: [Podcast]
        do {
            podcasts = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        for podcast in podcasts {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1
            guard let feed = podcast.feed else {
                outcome.delta.failed += 1
                continue
            }

            let feedURL = PodcastFeedIdentity.normalizedFeedURLString(feed)
            let metadata = podcast.metaData
            let subscribedAt = metadata?.subscriptionDate ?? .distantPast
            let isSubscribed = metadata?.isSubscribed != false
            // Feed refresh timestamps are cache activity, not subscription edits.
            let updatedAt = metadata?.subscriptionDate ?? .distantPast

            if let destination = fetchSubscription(
                id: feedURL,
                in: destinationContext
            ) {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) else {
                    outcome.delta.skipped += 1
                    continue
                }
                destination.feedURL = feedURL
                destination.isSubscribed = isSubscribed
                destination.subscribedAt = subscribedAt
                destination.unsubscribedAt = isSubscribed ? nil : updatedAt
                destination.updatedAt = updatedAt
                outcome.delta.updated += 1
            } else {
                let destination = SubscriptionSync(
                    feedURL: feedURL,
                    isSubscribed: isSubscribed,
                    subscribedAt: subscribedAt,
                    unsubscribedAt: isSubscribed ? nil : updatedAt,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                outcome.delta.inserted += 1
            }
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: podcasts, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = podcasts.count < defaultPageSize
        }
        return outcome
    }

    // MARK: - Playlists

    private static func processPlaylistsPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<Playlist>(sortBy: SourceOrder.playlists)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = defaultPageSize

        let playlists: [Playlist]
        do {
            playlists = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        for playlist in playlists {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            let playlistID = playlist.storeSplitSyncID
            let entryDates = playlist.ordered.compactMap(\.dateAdded)
            let createdAt = entryDates.min() ?? .distantPast
            let updatedAt = entryDates.max() ?? createdAt
            let smartFilterRawValue = playlist.smartFilter.flatMap {
                try? JSONEncoder().encode($0)
            }.flatMap {
                String(data: $0, encoding: .utf8)
            }

            if let destination = fetchPlaylist(
                id: playlistID,
                in: destinationContext
            ) {
                if StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) {
                    destination.title = playlist.title
                    destination.symbolName = playlist.symbolName
                    destination.sortIndex = playlist.sortIndex
                    destination.kindRawValue = playlist.kindRawValue
                    destination.smartFilterRawValue = smartFilterRawValue
                    destination.isHidden = playlist.hidden
                    destination.autoDownloadEnabled = playlist.autoDownloadEnabled
                    destination.autoDownloadEpisodeLimit =
                        playlist.resolvedAutoDownloadEpisodeLimit
                    destination.removesEpisodesPlayedElsewhere =
                        playlist.removesEpisodesPlayedElsewhere
                    destination.updatedAt = updatedAt
                    outcome.delta.updated += 1
                } else {
                    outcome.delta.skipped += 1
                }
            } else {
                let destination = PlaylistSync(
                    id: playlistID,
                    title: playlist.title,
                    symbolName: playlist.symbolName,
                    sortIndex: playlist.sortIndex,
                    kindRawValue: playlist.kindRawValue,
                    smartFilterRawValue: smartFilterRawValue,
                    isHidden: playlist.hidden,
                    autoDownloadEnabled: playlist.autoDownloadEnabled,
                    autoDownloadEpisodeLimit: playlist.resolvedAutoDownloadEpisodeLimit,
                    removesEpisodesPlayedElsewhere: playlist.removesEpisodesPlayedElsewhere,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                outcome.delta.inserted += 1
            }
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: playlists, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = playlists.count < defaultPageSize
        }
        return outcome
    }

    // MARK: - Playlist + queue entries

    private static func processPlaylistEntriesPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<PlaylistEntry>(sortBy: SourceOrder.playlistEntries)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = defaultPageSize

        let entries: [PlaylistEntry]
        do {
            entries = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        var entriesByID = ((try? destinationContext.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [])
            .reduce(into: [String: PlaylistEntrySync]()) { $0[$1.id] = $1 }
        var queueByID = ((try? destinationContext.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
            .reduce(into: [String: QueueEntrySync]()) { $0[$1.id] = $1 }

        for entry in entries {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            guard let playlist = entry.playlist else {
                outcome.delta.skipped += 1
                continue
            }
            let playlistID = playlist.storeSplitSyncID
            let isDefaultQueue = playlist.title == Playlist.defaultQueueTitle

            guard let episode = entry.episode,
                  episode.podcast?.feed != nil else {
                outcome.delta.skipped += 1
                if isDefaultQueue {
                    outcome.queueDelta.scanned += 1
                    outcome.queueDelta.skipped += 1
                }
                continue
            }

            let identity = episode.stableEpisodeIdentity
            let addedAt = entry.dateAdded ?? .distantPast
            let entryID = StableIdentityKey.make(
                playlistID,
                identity.feedURL,
                identity.episodeID
            )
            upsertPlaylistEntry(
                id: entryID,
                playlistID: playlistID,
                identity: identity,
                sortIndex: entry.order,
                addedAt: addedAt,
                destinationContext: destinationContext,
                recordsByID: &entriesByID,
                result: &outcome.delta
            )

            if isDefaultQueue {
                outcome.queueDelta.scanned += 1
                upsertQueueEntry(
                    identity: identity,
                    sortIndex: entry.order,
                    addedAt: addedAt,
                    destinationContext: destinationContext,
                    recordsByID: &queueByID,
                    result: &outcome.queueDelta
                )
            }
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: entries, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = entries.count < defaultPageSize
        }
        return outcome
    }

    private static func upsertPlaylistEntry(
        id: String,
        playlistID: String,
        identity: EpisodeStableIdentity,
        sortIndex: Int,
        addedAt: Date,
        destinationContext: ModelContext,
        recordsByID: inout [String: PlaylistEntrySync],
        result: inout StoreSplitMigrationPhaseResult
    ) {
        if let destination = recordsByID[id] {
            guard StoreSplitMergePolicy.prefersIncoming(
                existingUpdatedAt: destination.updatedAt,
                incomingUpdatedAt: addedAt
            ) else {
                result.skipped += 1
                return
            }
            destination.sortIndex = sortIndex
            destination.addedAt = addedAt
            destination.isDeleted = false
            destination.deletedAt = nil
            destination.updatedAt = addedAt
            result.updated += 1
        } else {
            let destination = PlaylistEntrySync(
                playlistID: playlistID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: sortIndex,
                addedAt: addedAt,
                updatedAt: addedAt
            )
            destinationContext.insert(destination)
            recordsByID[id] = destination
            result.inserted += 1
        }
    }

    private static func upsertQueueEntry(
        identity: EpisodeStableIdentity,
        sortIndex: Int,
        addedAt: Date,
        destinationContext: ModelContext,
        recordsByID: inout [String: QueueEntrySync],
        result: inout StoreSplitMigrationPhaseResult
    ) {
        if let destination = recordsByID[identity.key] {
            guard StoreSplitMergePolicy.prefersIncoming(
                existingUpdatedAt: destination.updatedAt,
                incomingUpdatedAt: addedAt
            ) else {
                result.skipped += 1
                return
            }
            destination.sortIndex = sortIndex
            destination.addedAt = addedAt
            destination.isDeleted = false
            destination.deletedAt = nil
            destination.updatedAt = addedAt
            result.updated += 1
        } else {
            let destination = QueueEntrySync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: sortIndex,
                addedAt: addedAt,
                updatedAt: addedAt
            )
            destinationContext.insert(destination)
            recordsByID[identity.key] = destination
            result.inserted += 1
        }
    }

    // MARK: - Bookmarks

    private static func processBookmarksPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()

        let ordered: [Bookmark]
        do {
            ordered = try orderedBookmarks(in: legacyContext)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        let start = min(max(0, offset), ordered.count)
        let end = min(start + defaultPageSize, ordered.count)
        let bookmarkPage = Array(ordered[start..<end])

        for bookmark in bookmarkPage {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            guard let episode = bookmark.bookmarkEpisode,
                  episode.podcast?.feed != nil else {
                outcome.delta.skipped += 1
                continue
            }

            let identity = episode.stableEpisodeIdentity
            let createdAt = bookmark.creationtime ?? .distantPast
            let bookmarkID = bookmark.uuid?.uuidString ?? StableIdentityKey.make(
                "legacy-bookmark",
                identity.key,
                String(bookmark.start ?? 0),
                bookmark.title,
                String(createdAt.timeIntervalSince1970)
            )

            if let destination = fetchBookmark(
                id: bookmarkID,
                in: destinationContext
            ) {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: createdAt
                ) else {
                    outcome.delta.skipped += 1
                    continue
                }
                destination.feedURL = identity.feedURL
                destination.episodeID = identity.episodeID
                destination.time = bookmark.start ?? 0
                destination.title = bookmark.title
                destination.createdAt = createdAt
                destination.updatedAt = createdAt
                outcome.delta.updated += 1
            } else {
                let destination = BookmarkSync(
                    id: bookmarkID,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    time: bookmark.start ?? 0,
                    title: bookmark.title,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                destinationContext.insert(destination)
                outcome.delta.inserted += 1
            }
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: bookmarkPage, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = end >= ordered.count
        }
        return outcome
    }

    /// Every legacy bookmark, in a stable order.
    ///
    /// `Bookmark` inherits all of its stored properties from `Marker`, and a
    /// `FetchDescriptor` that sorts or filters a `@Model` subclass by an
    /// inherited key path trips a SwiftData assertion, so the fetch is unsorted
    /// and the ordering is applied here.
    ///
    /// The previous workaround paged the `Marker` base table and cast each row
    /// to `Bookmark`. `Marker` is also the chapter model, so that walked every
    /// chapter of every episode — an unindexed sorted fetch with a growing
    /// offset, which makes SQLite spill a temp B-tree to disk on every slice.
    /// Two of those per slice, with only a short idle gap, dirtied gigabytes per
    /// run (68GB in one report) to migrate a handful of bookmarks.
    private static func orderedBookmarks(in context: ModelContext) throws -> [Bookmark] {
        try context.fetch(FetchDescriptor<Bookmark>())
            .sorted { lhs, rhs in
                let lhsCreated = lhs.creationtime ?? .distantPast
                let rhsCreated = rhs.creationtime ?? .distantPast
                if lhsCreated != rhsCreated {
                    return lhsCreated < rhsCreated
                }
                // Stable tiebreaker: the cursor has to mean the same thing on
                // the next slice.
                return (lhs.uuid?.uuidString ?? "") < (rhs.uuid?.uuidString ?? "")
            }
    }

    // MARK: - Episode playback state (recent first)

    // MARK: - Portable preferences

    private static func processPreferencesPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<PodcastSettings>(sortBy: SourceOrder.preferences)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = defaultPageSize
        let settings: [PodcastSettings]
        do {
            settings = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for setting in settings {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1
            let feedURL = setting.podcast?.feed.map(
                PodcastFeedIdentity.normalizedFeedURLString
            )
            let candidate = PodcastPreferenceSync(
                feedURL: feedURL,
                isEnabled: setting.isEnabled,
                playNextPositionRawValue: (try? encoder.encode(setting.playnextPosition))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "",
                defaultPlaylistID: setting.defaultPlaylistID.flatMap { playlistID in
                    (try? legacyContext.fetch(FetchDescriptor<Playlist>(
                        predicate: #Predicate { $0.id == playlistID }
                    )))?.first?.storeSplitSyncID
                },
                autoDownload: setting.autoDownload,
                autoDownloadEpisodeCount: setting.autoDownloadEpisodeCount,
                autoDownloadSelectionRawValue: setting.autoDownloadSelectionRawValue,
                autoDownloadNetworkModeRawValue: setting.autoDownloadNetworkModeRawValue,
                autoDownloadIncludesArchivedEpisodes: setting.autoDownloadIncludesArchivedEpisodes,
                archiveFileRetentionDays: setting.archiveFileRetentionDays,
                playbackSpeed: setting.playbackSpeed.map(Double.init),
                reduceSilenceGapsEnabled: setting.reduceSilenceGapsEnabled,
                silenceGapReductionLevelRawValue: setting.silenceGapReductionLevelRawValue,
                voiceEnhancementEnabled: setting.voiceEnhancementEnabled,
                autoSkipKeywordsJSON: (try? encoder.encode(setting.autoSkipKeywords))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "[]",
                autoDownloadFilterJSON: setting.autoDownloadFilterJSON,
                cutFront: setting.cutFront.map(Double.init),
                cutEnd: setting.cutEnd.map(Double.init),
                skipForwardSeconds: setting.skipForward.rawValue,
                skipBackSeconds: setting.skipBack.rawValue,
                skipForwardBehaviorRawValue: setting.skipForwardBehaviorRawValue,
                skipBackBehaviorRawValue: setting.skipBackBehaviorRawValue,
                markAsPlayedAfterSubscribe: setting.markAsPlayedAfterSubscribe,
                playSumAdjustedByPlaySpeed: setting.playSumAdjustedbyPlayspeed,
                enableLockscreenSlider: setting.enableLockscreenSlider,
                enableInAppSlider: setting.enableInAppSlider,
                continuousPlayEnabled: setting.getContinuousPlay,
                showLivePodcasts: setting.showLivePodcasts,
                liveItemNotificationsEnabled: setting.enableLiveItemNotifications,
                sleepTimerAddMinutes: setting.sleepTimerAddMinutes,
                sleepTimerDurationToReactivate: setting.sleepTimerDurationToReactivate,
                sleepTimerVoiceFeedbackEnabled: setting.sleepTimerVoiceFeedbackEnabled,
                sleepTimerText: setting.sleepTimerText,
                updatedAt: .distantPast,
                sourceDeviceID: ListeningDeviceIdentity.current().id
            )
            if let existing = fetchPreference(id: candidate.id, in: destinationContext) {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: existing.updatedAt,
                    incomingUpdatedAt: candidate.updatedAt
                ) else {
                    outcome.delta.skipped += 1
                    continue
                }
                applyPreference(candidate, to: existing)
                outcome.delta.updated += 1
            } else {
                destinationContext.insert(candidate)
                outcome.delta.inserted += 1
            }
        }
        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: settings, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = settings.count < defaultPageSize
        }
        return outcome
    }

    private static func applyPreference(
        _ source: PodcastPreferenceSync,
        to destination: PodcastPreferenceSync
    ) {
        destination.feedURL = source.feedURL
        destination.isEnabled = source.isEnabled
        destination.playNextPositionRawValue = source.playNextPositionRawValue
        destination.defaultPlaylistID = source.defaultPlaylistID
        destination.autoDownload = source.autoDownload
        destination.autoDownloadEpisodeCount = source.autoDownloadEpisodeCount
        destination.autoDownloadSelectionRawValue = source.autoDownloadSelectionRawValue
        destination.autoDownloadNetworkModeRawValue = source.autoDownloadNetworkModeRawValue
        destination.autoDownloadIncludesArchivedEpisodes = source.autoDownloadIncludesArchivedEpisodes
        destination.archiveFileRetentionDays = source.archiveFileRetentionDays
        destination.autoDownloadFilterJSON = source.autoDownloadFilterJSON
        destination.playbackSpeed = source.playbackSpeed
        destination.reduceSilenceGapsEnabled = source.reduceSilenceGapsEnabled
        destination.silenceGapReductionLevelRawValue = source.silenceGapReductionLevelRawValue
        destination.voiceEnhancementEnabled = source.voiceEnhancementEnabled
        destination.autoSkipKeywordsJSON = source.autoSkipKeywordsJSON
        destination.cutFront = source.cutFront
        destination.cutEnd = source.cutEnd
        destination.skipForwardSeconds = source.skipForwardSeconds
        destination.skipBackSeconds = source.skipBackSeconds
        destination.skipForwardBehaviorRawValue = source.skipForwardBehaviorRawValue
        destination.skipBackBehaviorRawValue = source.skipBackBehaviorRawValue
        destination.markAsPlayedAfterSubscribe = source.markAsPlayedAfterSubscribe
        destination.playSumAdjustedByPlaySpeed = source.playSumAdjustedByPlaySpeed
        destination.enableLockscreenSlider = source.enableLockscreenSlider
        destination.enableInAppSlider = source.enableInAppSlider
        destination.continuousPlayEnabled = source.continuousPlayEnabled
        destination.showLivePodcasts = source.showLivePodcasts
        destination.liveItemNotificationsEnabled = source.liveItemNotificationsEnabled
        destination.sleepTimerAddMinutes = source.sleepTimerAddMinutes
        destination.sleepTimerDurationToReactivate = source.sleepTimerDurationToReactivate
        destination.sleepTimerVoiceFeedbackEnabled = source.sleepTimerVoiceFeedbackEnabled
        destination.sleepTimerText = source.sleepTimerText
        destination.updatedAt = source.updatedAt
        destination.sourceDeviceID = source.sourceDeviceID
    }

    private static func processEpisodeStatesPage(
        offset: Int,
        pageSize: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<Episode>(sortBy: SourceOrder.episodes)
        descriptor.fetchLimit = pageSize
        descriptor.fetchOffset = offset

        let episodes: [Episode]
        do {
            episodes = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        for episode in episodes {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            guard let metadata = episode.metaData,
                  episode.podcast?.feed != nil else {
                outcome.delta.skipped += 1
                continue
            }

            let isPlayed = metadata.isHistory == true
                || metadata.status == .history
                || metadata.completionDate != nil
            let isArchived = metadata.isArchived == true || metadata.status == .archived
            let hasMeaningfulState = (metadata.playPosition ?? 0) > 0
                || (metadata.maxPlayposition ?? 0) > 0
                || isPlayed
                || isArchived
                || metadata.wasSkipped
                || metadata.firstListenDate != nil
                || metadata.lastPlayed != nil

            guard hasMeaningfulState else {
                outcome.delta.skipped += 1
                continue
            }

            let identity = episode.stableEpisodeIdentity
            // `stateUpdatedAt` is the explicit generation stamp written by the
            // dual-write; the playback timestamps are the fallback for rows that
            // predate it.
            let updatedAt = metadata.effectiveStateUpdatedAt ?? .distantPast

            let stateID = identity.key
            if let destination = fetchEpisodeState(
                id: stateID,
                in: destinationContext
            ) {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) else {
                    outcome.delta.skipped += 1
                    continue
                }
                applyEpisodeState(
                    metadata: metadata,
                    episode: episode,
                    identity: identity,
                    isPlayed: isPlayed,
                    isArchived: isArchived,
                    updatedAt: updatedAt,
                    to: destination
                )
                outcome.delta.updated += 1
            } else {
                let destination = EpisodeStateSync(
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    playPosition: metadata.playPosition ?? 0,
                    maxPlayPosition: metadata.maxPlayposition ?? 0,
                    duration: episode.duration,
                    isPlayed: isPlayed,
                    isArchived: isArchived,
                    wasSkipped: metadata.wasSkipped,
                    completedAt: metadata.completionDate,
                    archivedAt: metadata.archivedAt,
                    firstPlayedAt: metadata.firstListenDate,
                    lastPlayedAt: metadata.lastPlayed,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                outcome.delta.inserted += 1
            }
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: episodes, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = episodes.count < pageSize
        }
        return outcome
    }

    private static func applyEpisodeState(
        metadata: EpisodeMetaData,
        episode: Episode,
        identity: EpisodeStableIdentity,
        isPlayed: Bool,
        isArchived: Bool,
        updatedAt: Date,
        to destination: EpisodeStateSync
    ) {
        destination.feedURL = identity.feedURL
        destination.episodeID = identity.episodeID
        destination.playPosition = metadata.playPosition ?? 0
        destination.maxPlayPosition = max(
            destination.maxPlayPosition,
            metadata.maxPlayposition ?? 0
        )
        destination.duration = episode.duration ?? destination.duration
        destination.isPlayed = isPlayed
        destination.isArchived = isArchived
        destination.wasSkipped = metadata.wasSkipped
        destination.completedAt = metadata.completionDate
        destination.archivedAt = metadata.archivedAt
        destination.firstPlayedAt = metadata.firstListenDate
        destination.lastPlayedAt = metadata.lastPlayed
        destination.updatedAt = updatedAt
    }

    // MARK: - Listening history

    private static func processListeningHistoryPage(
        offset: Int,
        pageSize: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<PlaySession>(sortBy: SourceOrder.playSessions)
        descriptor.fetchLimit = pageSize
        descriptor.fetchOffset = offset

        let sessions: [PlaySession]
        do {
            sessions = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        for session in sessions {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            guard let episode = session.episode,
                  episode.podcast?.feed != nil,
                  let startedAt = session.startTime else {
                outcome.delta.skipped += 1
                continue
            }

            let identity = episode.stableEpisodeIdentity
            let sourceDeviceID = session.sourceDeviceID ?? legacyDeviceID(
                deviceModel: session.deviceModel,
                osVersion: session.osVersion
            )
            let sourceDeviceName = session.sourceDeviceName
                ?? session.deviceModel
                ?? "Legacy device"
            guard historyIdentityValuesAreValid(
                startedAt: startedAt,
                endedAt: session.endTime,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0
            ) else {
                outcome.error = "listening_history_invalid_source"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                destinationContext.rollback()
                cacheContext.rollback()
                return outcome
            }
            guard let endedAt = session.endTime, endedAt > startedAt else {
                do { try cacheLegacySession(
                    session,
                    episode: episode,
                    identity: identity,
                    sourceDeviceID: sourceDeviceID,
                    sourceDeviceName: sourceDeviceName,
                    startedAt: startedAt,
                    endedAt: nil,
                    listenedSeconds: 0,
                    in: cacheContext,
                    shouldContinue: shouldContinue
                ) } catch is CancellationError {
                    outcome.reachedEnd = false
                    break
                } catch {
                    outcome.error = "listening_cache_fetch_failed: \(error.localizedDescription)"
                    outcome.reachedEnd = false
                    break
                }
                outcome.delta.skipped += 1
                continue
            }
            let recordID = ListeningHistoryIdentity.make(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0,
            )
            let listenedSeconds = endedAt.timeIntervalSince(startedAt)
            let updatedAt = endedAt

            do { try cacheLegacySession(
                session,
                episode: episode,
                identity: identity,
                sourceDeviceID: sourceDeviceID,
                sourceDeviceName: sourceDeviceName,
                startedAt: startedAt,
                endedAt: endedAt,
                listenedSeconds: listenedSeconds,
                in: cacheContext,
                shouldContinue: shouldContinue
            ) } catch is CancellationError {
                outcome.reachedEnd = false
                break
            } catch {
                outcome.error = "listening_cache_fetch_failed: \(error.localizedDescription)"
                outcome.reachedEnd = false
                break
            }

            let destination: ListeningHistorySync?
            do {
                destination = try fetchListeningHistory(id: recordID, in: destinationContext)
            } catch {
                outcome.error = "listening_history_destination_fetch_failed: \(error.localizedDescription)"
                outcome.reachedEnd = false
                break
            }
            if let destination {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) else {
                    outcome.delta.skipped += 1
                    continue
                }
                applyListeningHistory(
                    session: session,
                    episode: episode,
                    identity: identity,
                    sourceDeviceID: sourceDeviceID,
                    sourceDeviceName: sourceDeviceName,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    listenedSeconds: listenedSeconds,
                    updatedAt: updatedAt,
                    to: destination
                )
                outcome.delta.updated += 1
            } else {
                destinationContext.insert(
                    ListeningHistorySync(
                        id: recordID,
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        podcastName: session.podcastName ?? episode.displayPodcastTitle,
                        episodeTitle: episode.title,
                        sourceDeviceID: sourceDeviceID,
                        sourceDeviceName: sourceDeviceName,
                        deviceModel: session.deviceModel,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        startPosition: session.startPosition ?? 0,
                        endPosition: session.endPosition ?? 0,
                        listenedSeconds: listenedSeconds,
                        silenceGapTimeSavedSeconds:
                            session.silenceGapTimeSavedSeconds ?? 0,
                        playbackRateTimeSavedSeconds:
                            PlaybackRateSavingsCalculator.secondsSaved(in: session),
                        endedCleanly: session.endedCleanly == true,
                        isLegacyMigrated: true,
                        updatedAt: updatedAt
                    )
                )
                outcome.delta.inserted += 1
            }
        }

        if outcome.error != nil {
            destinationContext.rollback()
            cacheContext.rollback()
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        if shouldContinue() == false {
            destinationContext.rollback()
            cacheContext.rollback()
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }

        guard save(destinationContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "destination_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        do {
            if cacheContext.hasChanges { try cacheContext.save() }
        } catch {
            cacheContext.rollback()
            outcome.error = "cache_save_failed"
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: sessions, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = sessions.count < pageSize
        }
        return outcome
    }

    /// Rechecks one UUID-keyset page after backfill. The cursor advances only
    /// when every eligible completed session has a matching UserState row.
    private static func verifyListeningHistoryPage(
        afterID: UUID?,
        pageSize: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        deadline: ContinuousClock.Instant,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        guard StoreSplitMigrationVerifier.invalidateForMigrationStage(in: cacheContext) else {
            outcome.error = "listening_history_verification_invalidation_failed"
            outcome.delta.failed = 1
            outcome.reachedEnd = false
            return outcome
        }
        var descriptor: FetchDescriptor<PlaySession>
        if let afterID {
            descriptor = FetchDescriptor<PlaySession>(
                predicate: #Predicate<PlaySession> { session in
                    if let id = session.id { id > afterID } else { false }
                },
                sortBy: SourceOrder.verificationPlaySessions
            )
        } else {
            descriptor = FetchDescriptor<PlaySession>(sortBy: SourceOrder.verificationPlaySessions)
        }
        descriptor.fetchLimit = pageSize

        let sessions: [PlaySession]
        do {
            sessions = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = "listening_history_verification_source_fetch_failed"
            outcome.delta.failed = 1
            outcome.reachedEnd = false
            return outcome
        }

        for session in sessions {
            guard shouldContinue() else {
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
            if ContinuousClock.now >= deadline { break }
            guard let sessionID = session.id else {
                outcome.error = "listening_history_verification_source_identity_unresolved"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
            var duplicateDescriptor = FetchDescriptor<PlaySession>(predicate: #Predicate { $0.id == sessionID })
            duplicateDescriptor.fetchLimit = 2
            do {
                guard try legacyContext.fetch(duplicateDescriptor).count == 1 else {
                    outcome.error = "listening_history_verification_duplicate_source_identity"
                    outcome.delta.failed += 1
                    outcome.processed = 0
                    outcome.reachedEnd = false
                    return outcome
                }
            } catch {
                outcome.error = "listening_history_verification_source_fetch_failed"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
            outcome.processed += 1
            outcome.delta.scanned += 1

            guard let episode = session.episode,
                  episode.podcast?.feed != nil,
                  let startedAt = session.startTime else {
                outcome.error = "listening_history_verification_source_identity_unresolved"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }

            let identity = episode.stableEpisodeIdentity
            let sourceDeviceID = session.sourceDeviceID ?? legacyDeviceID(
                deviceModel: session.deviceModel,
                osVersion: session.osVersion
            )
            let sourceDeviceName = session.sourceDeviceName
                ?? session.deviceModel
                ?? "Legacy device"

            guard historyIdentityValuesAreValid(
                startedAt: startedAt,
                endedAt: session.endTime,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0
            ) else {
                outcome.error = "listening_history_verification_invalid_source"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
            guard let endedAt = session.endTime, endedAt > startedAt else {
                let cacheID = cachedLegacySessionID(
                    session,
                    identity: identity,
                    startedAt: startedAt
                )
                let cached: CachedPlaySession?
                do {
                    var cachedDescriptor = FetchDescriptor<CachedPlaySession>(
                        predicate: #Predicate { $0.id == cacheID }
                    )
                    cachedDescriptor.fetchLimit = 2
                    let records = try cacheContext.fetch(cachedDescriptor)
                    guard records.count <= 1 else {
                        outcome.error = "listening_history_verification_duplicate_cache_identity"
                        outcome.delta.failed += 1
                        outcome.processed = 0
                        outcome.reachedEnd = false
                        return outcome
                    }
                    cached = records.first
                } catch {
                    outcome.error = "listening_history_verification_cache_fetch_failed"
                    outcome.delta.failed += 1
                    outcome.processed = 0
                    outcome.reachedEnd = false
                    return outcome
                }
                guard let cached else {
                    outcome.error = "listening_history_verification_missing_incomplete_cache_record"
                    outcome.delta.failed += 1
                    outcome.processed = 0
                    outcome.reachedEnd = false
                    return outcome
                }
                let expectedCached = CachedPlaySession(
                    id: cacheID,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    podcastName: session.podcastName ?? episode.displayPodcastTitle,
                    episodeTitle: episode.title,
                    sourceDeviceID: sourceDeviceID,
                    sourceDeviceName: sourceDeviceName,
                    deviceModel: session.deviceModel,
                    osVersion: session.osVersion,
                    appVersion: session.appVersion,
                    startedAt: startedAt,
                    endedAt: nil,
                    startPosition: session.startPosition ?? 0,
                    endPosition: session.endPosition,
                    silenceGapTimeSavedSeconds: max(0, session.silenceGapTimeSavedSeconds ?? 0),
                    playbackRateTimeSavedSeconds: max(0, PlaybackRateSavingsCalculator.secondsSaved(in: session)),
                    endedCleanly: session.endedCleanly == true,
                    updatedAt: startedAt
                )
                guard cachedLegacySessionMatches(cached, expected: expectedCached) else {
                    outcome.error = "listening_history_verification_incomplete_cache_mismatch"
                    outcome.delta.failed += 1
                    outcome.processed = 0
                    outcome.reachedEnd = false
                    return outcome
                }
                outcome.delta.skipped += 1
                continue
            }

            let recordID = ListeningHistoryIdentity.make(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0
            )

            let actual: ListeningHistorySync?
            do {
                var historyDescriptor = FetchDescriptor<ListeningHistorySync>(predicate: #Predicate { $0.id == recordID })
                historyDescriptor.fetchLimit = 2
                let records = try destinationContext.fetch(historyDescriptor)
                guard records.count <= 1 else {
                    outcome.error = "listening_history_verification_duplicate_destination_identity"
                    outcome.delta.failed += 1
                    outcome.processed = 0
                    outcome.reachedEnd = false
                    return outcome
                }
                actual = records.first
            } catch {
                outcome.error = "listening_history_verification_destination_fetch_failed"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
            guard let actual else {
                outcome.error = "listening_history_verification_missing_record"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }

            // The ID must still describe the destination row. A later update
            // is preserved, but cannot turn a mismatched episode or session
            // into evidence for this source identity.
            guard historyIdentityValuesAreValid(
                    startedAt: actual.startedAt, endedAt: actual.endedAt,
                    startPosition: actual.startPosition, endPosition: actual.endPosition
                  ),
                  ListeningHistoryIdentity.make(for: actual) == recordID else {
                outcome.error = "listening_history_verification_semantic_mismatch"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }

            // CloudKit may have delivered a later edit from another device.
            // Preserve it and accept it as newer evidence; never rewrite it
            // during verification. Equal or older rows must match the complete
            // legacy projection, including device lineage and saved-time fields.
            if actual.updatedAt > endedAt {
                outcome.delta.skipped += 1
                continue
            }

            let expected = ListeningHistorySync(
                id: recordID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                podcastName: session.podcastName ?? episode.displayPodcastTitle,
                episodeTitle: episode.title,
                sourceDeviceID: sourceDeviceID,
                sourceDeviceName: sourceDeviceName,
                deviceModel: session.deviceModel,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: session.startPosition ?? 0,
                endPosition: session.endPosition ?? 0,
                listenedSeconds: endedAt.timeIntervalSince(startedAt),
                silenceGapTimeSavedSeconds: session.silenceGapTimeSavedSeconds ?? 0,
                playbackRateTimeSavedSeconds: PlaybackRateSavingsCalculator.secondsSaved(in: session),
                endedCleanly: session.endedCleanly == true,
                isLegacyMigrated: true,
                updatedAt: endedAt
            )
            guard listeningHistoryMatches(actual, expected: expected) else {
                outcome.error = "listening_history_verification_semantic_mismatch"
                outcome.delta.failed += 1
                outcome.processed = 0
                outcome.reachedEnd = false
                return outcome
            }
        }

        if outcome.processed > 0 {
            outcome.boundaryKey = sessions[outcome.processed - 1].id?.uuidString
        }
        outcome.reachedEnd = outcome.processed == sessions.count && sessions.count < pageSize
        return outcome
    }

    private static func historyIdentityValuesAreValid(
        startedAt: Date,
        endedAt: Date?,
        startPosition: Double,
        endPosition: Double
    ) -> Bool {
        // Identity construction rounds timestamps and decisecond positions to
        // Int. Invalid legacy data must fail verification rather than trap.
        let limit = Double(Int.max) / 20
        let values = [startedAt.timeIntervalSince1970, startPosition, endPosition]
            + (endedAt.map { [$0.timeIntervalSince1970] } ?? [])
        return values.allSatisfy { $0.isFinite && abs($0) < limit }
    }

    private static func listeningHistoryMatches(
        _ actual: ListeningHistorySync,
        expected: ListeningHistorySync
    ) -> Bool {
        func equal(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) <= max(0.001, max(abs(lhs), abs(rhs)) * 0.000_001)
        }
        return actual.id == expected.id
            && actual.feedURL == expected.feedURL
            && actual.episodeID == expected.episodeID
            && actual.podcastName == expected.podcastName
            && actual.episodeTitle == expected.episodeTitle
            && actual.sourceDeviceID == expected.sourceDeviceID
            && actual.sourceDeviceName == expected.sourceDeviceName
            && actual.deviceModel == expected.deviceModel
            && actual.startedAt == expected.startedAt
            && actual.endedAt == expected.endedAt
            && equal(actual.listenedSeconds, expected.listenedSeconds)
            && equal(actual.startPosition, expected.startPosition)
            && equal(actual.endPosition, expected.endPosition)
            && equal(actual.silenceGapTimeSavedSeconds, expected.silenceGapTimeSavedSeconds)
            && equal(actual.playbackRateTimeSavedSeconds, expected.playbackRateTimeSavedSeconds)
            && actual.endedCleanly == expected.endedCleanly
            && actual.isLegacyMigrated == expected.isLegacyMigrated
    }

    private static func cachedLegacySessionMatches(
        _ actual: CachedPlaySession,
        expected: CachedPlaySession
    ) -> Bool {
        func equal(_ lhs: Double?, _ rhs: Double?) -> Bool {
            guard let left = lhs, let right = rhs else {
                return lhs == nil && rhs == nil
            }
            return abs(left - right) <= max(0.001, max(abs(left), abs(right)) * 0.000_001)
        }
        return actual.id == expected.id
            && actual.feedURL == expected.feedURL
            && actual.episodeID == expected.episodeID
            && actual.podcastName == expected.podcastName
            && actual.episodeTitle == expected.episodeTitle
            && actual.sourceDeviceID == expected.sourceDeviceID
            && actual.sourceDeviceName == expected.sourceDeviceName
            && actual.deviceModel == expected.deviceModel
            && actual.osVersion == expected.osVersion
            && actual.appVersion == expected.appVersion
            && actual.startedAt == expected.startedAt
            && actual.endedAt == nil
            && equal(actual.startPosition, expected.startPosition)
            && equal(actual.endPosition, expected.endPosition)
            && equal(actual.silenceGapTimeSavedSeconds, expected.silenceGapTimeSavedSeconds)
            && equal(actual.playbackRateTimeSavedSeconds, expected.playbackRateTimeSavedSeconds)
            && actual.endedCleanly == expected.endedCleanly
    }

    private static func cachedLegacySessionID(
        _ session: PlaySession,
        identity: EpisodeStableIdentity,
        startedAt: Date
    ) -> String {
        session.id?.uuidString ?? StableIdentityKey.uuid(for:
            StableIdentityKey.make(
                identity.key,
                String(Int(startedAt.timeIntervalSince1970))
            )
        ).uuidString
    }

    private static func cacheLegacySession(
        _ session: PlaySession,
        episode: Episode,
        identity: EpisodeStableIdentity,
        sourceDeviceID: String,
        sourceDeviceName: String,
        startedAt: Date,
        endedAt: Date?,
        listenedSeconds: Double,
        in context: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) throws {
        let sessionID = cachedLegacySessionID(session, identity: identity, startedAt: startedAt)
        var descriptor = FetchDescriptor<CachedPlaySession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        descriptor.fetchLimit = 1
        let cachedValue = try context.fetch(descriptor).first
        let cached = cachedValue ?? CachedPlaySession(
                id: sessionID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sourceDeviceID: sourceDeviceID,
                startedAt: startedAt
        )
        if cached.modelContext == nil { context.insert(cached) }
        func update<Value: Equatable>(
            _ keyPath: ReferenceWritableKeyPath<CachedPlaySession, Value>,
            to value: Value
        ) {
            if cached[keyPath: keyPath] != value { cached[keyPath: keyPath] = value }
        }
        update(\.feedURL, to: identity.feedURL)
        update(\.episodeID, to: identity.episodeID)
        update(\.podcastName, to: session.podcastName ?? episode.displayPodcastTitle)
        update(\.episodeTitle, to: episode.title)
        update(\.sourceDeviceID, to: sourceDeviceID)
        update(\.sourceDeviceName, to: sourceDeviceName)
        update(\.deviceModel, to: session.deviceModel)
        update(\.osVersion, to: session.osVersion)
        update(\.appVersion, to: session.appVersion)
        update(\.startedAt, to: startedAt)
        update(\.endedAt, to: endedAt)
        update(\.startPosition, to: session.startPosition ?? 0)
        update(\.endPosition, to: session.endPosition)
        update(\.silenceGapTimeSavedSeconds, to: max(
            0,
            session.silenceGapTimeSavedSeconds ?? 0
        ))
        let rateSaved = max(0, PlaybackRateSavingsCalculator.secondsSaved(in: session))
        update(\.playbackRateTimeSavedSeconds, to: rateSaved)
        update(\.endedCleanly, to: session.endedCleanly == true)
        update(\.updatedAt, to: endedAt ?? startedAt)

        let rateDescriptor = FetchDescriptor<CachedRateSegment>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let oldRates = try context.fetch(rateDescriptor)
        var retainedRateIDs = Set<String>()
        for (ordinal, segment) in (session.segments ?? []).sorted(by: {
            ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
        }).enumerated() {
            guard shouldContinue() else { throw CancellationError() }
            let id = StableIdentityKey.make(sessionID, "rate", String(ordinal))
            retainedRateIDs.insert(id)
            let existing = oldRates.first { $0.id == id }
            if let existing {
                let rate = segment.rate ?? 1
                if existing.ordinal != ordinal
                    || existing.rate != rate
                    || existing.startTime != segment.startTime
                    || existing.startPosition != segment.startPosition
                    || existing.endTime != segment.endTime
                    || existing.endPosition != segment.endPosition {
                    existing.ordinal = ordinal
                    existing.rate = rate
                    existing.startTime = segment.startTime
                    existing.startPosition = segment.startPosition
                    existing.endTime = segment.endTime
                    existing.endPosition = segment.endPosition
                }
            } else {
                context.insert(CachedRateSegment(
                    id: id,
                    sessionID: sessionID,
                    ordinal: ordinal,
                    rate: segment.rate ?? 1,
                    startTime: segment.startTime,
                    startPosition: segment.startPosition,
                    endTime: segment.endTime,
                    endPosition: segment.endPosition
                ))
            }
        }
        for old in oldRates where retainedRateIDs.contains(old.id) == false { context.delete(old) }

        let hourDescriptor = FetchDescriptor<CachedHourlyListeningStat>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let oldHours = try context.fetch(hourDescriptor)
        var retainedHourIDs = Set<String>()
        let silenceSaved = max(0, session.silenceGapTimeSavedSeconds ?? 0)
        guard let endedAt, endedAt > startedAt else {
            for old in oldHours { context.delete(old) }
            return
        }
        let calendar = Calendar.current
        var cursor = startedAt
        while cursor < endedAt {
            guard shouldContinue() else { throw CancellationError() }
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart)
                ?? endedAt
            let blockEnd = min(nextHour, endedAt)
            let seconds = blockEnd.timeIntervalSince(cursor)
            let fraction = listenedSeconds > 0 ? seconds / listenedSeconds : 0
            let id = StableIdentityKey.make(
                    sessionID,
                    "hour",
                    String(Int(hourStart.timeIntervalSince1970))
                )
            retainedHourIDs.insert(id)
            if let existing = oldHours.first(where: { $0.id == id }) {
                let silenceSeconds = silenceSaved * fraction
                let rateSeconds = rateSaved * fraction
                if existing.feedURL != identity.feedURL
                    || existing.podcastName != cached.podcastName
                    || existing.sourceDeviceID != sourceDeviceID
                    || existing.startOfHour != hourStart
                    || existing.totalSeconds != seconds
                    || existing.silenceGapTimeSavedSeconds != silenceSeconds
                    || existing.playbackRateTimeSavedSeconds != rateSeconds {
                    existing.feedURL = identity.feedURL
                    existing.podcastName = cached.podcastName
                    existing.sourceDeviceID = sourceDeviceID
                    existing.startOfHour = hourStart
                    existing.totalSeconds = seconds
                    existing.silenceGapTimeSavedSeconds = silenceSeconds
                    existing.playbackRateTimeSavedSeconds = rateSeconds
                }
            } else {
                context.insert(CachedHourlyListeningStat(
                    id: id,
                    sessionID: sessionID,
                    feedURL: identity.feedURL,
                    podcastName: cached.podcastName,
                    sourceDeviceID: sourceDeviceID,
                    startOfHour: hourStart,
                    totalSeconds: seconds,
                    silenceGapTimeSavedSeconds: silenceSaved * fraction,
                    playbackRateTimeSavedSeconds: rateSaved * fraction
                ))
            }
            cursor = blockEnd
        }
        for old in oldHours where retainedHourIDs.contains(old.id) == false { context.delete(old) }
    }

    private static func applyListeningHistory(
        session: PlaySession,
        episode: Episode,
        identity: EpisodeStableIdentity,
        sourceDeviceID: String,
        sourceDeviceName: String,
        startedAt: Date,
        endedAt: Date,
        listenedSeconds: Double,
        updatedAt: Date,
        to destination: ListeningHistorySync
    ) {
        destination.feedURL = identity.feedURL
        destination.episodeID = identity.episodeID
        destination.podcastName = session.podcastName ?? episode.displayPodcastTitle
        destination.episodeTitle = episode.title
        destination.sourceDeviceID = sourceDeviceID
        destination.sourceDeviceName = sourceDeviceName
        destination.deviceModel = session.deviceModel
        destination.startedAt = startedAt
        destination.endedAt = endedAt
        destination.startPosition = session.startPosition ?? 0
        destination.endPosition = session.endPosition ?? 0
        destination.listenedSeconds = listenedSeconds
        destination.silenceGapTimeSavedSeconds = session.silenceGapTimeSavedSeconds ?? 0
        destination.playbackRateTimeSavedSeconds = PlaybackRateSavingsCalculator.secondsSaved(in: session)
        destination.endedCleanly = session.endedCleanly == true
        destination.isLegacyMigrated = true
        destination.updatedAt = updatedAt
    }

    // MARK: - Listening summaries

    /// The period tier to sum the baseline from: the coarsest one this store
    /// actually has.
    ///
    /// Each tier partitions all time on its own, so summing within a single tier
    /// never double-counts — but summing *across* tiers does, because a month is
    /// inside a year. `PlaySessionTrackerActor` writes day, week, month and year
    /// together, so `.year` is what a real store yields; the coarser-first search
    /// only matters for a store whose older tiers were pruned, where the
    /// alternative would be capturing no baseline and silently dropping the
    /// account's pre-split history.
    static func baselinePeriodKind(
        in summaries: [PlaySessionSummary]
    ) -> String? {
        let available = Set(summaries.compactMap(\.periodKind))
        return [
            PlaySessionSummaryPeriod.year,
            .month,
            .week,
            .day
        ].first { available.contains($0.rawValue) }?.rawValue
    }

    private static func selectedBaselinePeriodKind(in context: ModelContext) throws -> String? {
        for kind in [PlaySessionSummaryPeriod.year, .month, .week, .day] {
            let rawValue = kind.rawValue
            let predicate = #Predicate<PlaySessionSummary> { $0.periodKind == rawValue }
            if try context.fetchCount(FetchDescriptor(predicate: predicate)) > 0 {
                return rawValue
            }
        }
        return nil
    }

    /// Builds local candidate totals for the pre-split listening baseline.
    ///
    /// Raw `PlaySession` rows are pruned after 30 days, so the era before the
    /// split survives only as legacy `PlaySessionSummary` aggregates. Summing the
    /// `.year` rows is what turns them into a lifetime figure — `.year` periods
    /// partition all time, so summing them never double-counts, and it is the
    /// same derivation the legacy statistics screen has always used.
    ///
    /// UserState baselines are write-once. Publication preserves existing rows
    /// and blocks a missing row until a durable source-revision fence proves
    /// that a candidate is complete; the retained cache is recovery evidence.
    private static func processListeningSummaries(
        offset: Int,
        pageSize: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        cacheContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        if offset == 0 {
            let checkpointID = checkpointID(for: Phase.listeningSummaries)
            var checkpointDescriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
            checkpointDescriptor.fetchLimit = 2
            let aggregatePrefix = StableIdentityKey.make(baselineAggregateNamespace)
            let sourcePrefix = StableIdentityKey.make(baselineSourceNamespace)
            var aggregateDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(predicate: #Predicate { $0.id.starts(with: aggregatePrefix) })
            aggregateDescriptor.fetchLimit = 1
            var sourceDescriptor = FetchDescriptor<CachedListeningBaselineSource>(predicate: #Predicate { $0.id.starts(with: sourcePrefix) })
            sourceDescriptor.fetchLimit = 1
            do {
                if try legacyBaselineScratchPresent(in: cacheContext) {
                    outcome.error = "baseline_legacy_partial_scratch_unresolved"
                    outcome.reachedEnd = false
                    return outcome
                }
                let checkpoints = try cacheContext.fetch(checkpointDescriptor)
                guard checkpoints.count <= 1 else {
                    outcome.error = "baseline_scan_checkpoint_ambiguous"
                    outcome.reachedEnd = false
                    return outcome
                }
                if (checkpoints.isEmpty || checkpoints[0].scannedCount == 0),
                   try !cacheContext.fetch(aggregateDescriptor).isEmpty || !cacheContext.fetch(sourceDescriptor).isEmpty {
                    outcome.error = "baseline_scan_orphaned_scratch_unresolved"
                    outcome.reachedEnd = false
                    return outcome
                }
            } catch {
                outcome.error = "baseline_scan_scratch_fetch_failed"
                outcome.reachedEnd = false
                return outcome
            }
        }
        var baselineKind: String?
        do {
            baselineKind = try selectedBaselinePeriodKind(in: legacyContext)
        } catch {
            outcome.error = "summary_source_count_failed: \(error.localizedDescription)"
            outcome.reachedEnd = false
            return outcome
        }

        guard let baselineKind else { return outcome }

        let periodPredicate = #Predicate<PlaySessionSummary> { $0.periodKind == baselineKind }
        var descriptor = FetchDescriptor<PlaySessionSummary>(
            predicate: periodPredicate,
            sortBy: [SortDescriptor(\.periodStart), SortDescriptor(\.id)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = pageSize
        let summaries: [PlaySessionSummary]
        do {
            summaries = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = "summary_source_fetch_failed: \(error.localizedDescription)"
            outcome.reachedEnd = false
            return outcome
        }

        for summary in summaries {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1
            guard let periodStart = summary.periodStart else {
                outcome.delta.skipped += 1
                continue
            }

            let feedURL = summary.podcastFeed
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? ListeningBaselineSync.allPodcastsFeedURL
            let sourceID = summary.id?.uuidString ?? StableIdentityKey.make(
                feedURL,
                baselineKind,
                String(periodStart.timeIntervalSince1970),
                summary.podcastName ?? ""
            )
            let sourceKey = StableIdentityKey.make(baselineSourceNamespace, sourceID)
            var sourceDescriptor = FetchDescriptor<CachedListeningBaselineSource>(
                predicate: #Predicate { $0.id == sourceKey }
            )
            sourceDescriptor.fetchLimit = 2
            do {
                let existing = try cacheContext.fetch(sourceDescriptor)
                guard existing.count <= 1 else {
                    outcome.error = "summary_source_ledger_identity_conflict"
                    outcome.reachedEnd = false
                    break
                }
                if existing.first != nil {
                    outcome.delta.skipped += 1
                    continue
                }
            } catch {
                outcome.error = "summary_source_ledger_fetch_failed: \(error.localizedDescription)"
                outcome.reachedEnd = false
                break
            }
            let aggregateID = StableIdentityKey.make(baselineAggregateNamespace, feedURL)
            var aggregateDescriptor = FetchDescriptor<CachedListeningBaselineAggregate>(
                predicate: #Predicate { $0.id == aggregateID }
            )
            aggregateDescriptor.fetchLimit = 2
            let aggregate: CachedListeningBaselineAggregate
            do {
                let aggregates = try cacheContext.fetch(aggregateDescriptor)
                guard aggregates.count <= 1 else {
                    outcome.error = "summary_aggregate_identity_conflict"
                    outcome.reachedEnd = false
                    break
                }
                if let existing = aggregates.first {
                    aggregate = existing
                } else {
                    aggregate = CachedListeningBaselineAggregate(
                        id: aggregateID,
                        feedURL: feedURL,
                        podcastName: summary.podcastName
                    )
                    cacheContext.insert(aggregate)
                }
            } catch {
                outcome.error = "summary_aggregate_fetch_failed: \(error.localizedDescription)"
                outcome.reachedEnd = false
                break
            }
            aggregate.podcastName = summary.podcastName ?? aggregate.podcastName
            aggregate.totalSeconds += max(0, summary.totalSeconds ?? 0)
            aggregate.silenceGapTimeSavedSeconds += max(0, summary.silenceGapTimeSavedSeconds ?? 0)
            aggregate.playbackRateTimeSavedSeconds += max(0, summary.playbackRateTimeSavedSeconds ?? 0)
            cacheContext.insert(CachedListeningBaselineSource(id: sourceKey))
        }

        if outcome.error != nil {
            cacheContext.rollback()
            destinationContext.rollback()
            outcome.processed = 0
            return outcome
        }

        outcome.boundaryKey = boundaryKey(of: summaries, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = summaries.count < pageSize
        }

        return outcome
    }

    // MARK: - AI content backfill

    private static func processAITranscriptPage(
        offset: Int,
        legacyContext: ModelContext,
        cacheContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: SourceOrder.transcriptionRecords
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = aiContentPageSize
        let records: [TranscriptionRecord]
        do {
            records = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        let sourceDeviceID = ListeningDeviceIdentity.current().id
        for record in records {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            outcome.delta.scanned += 1
            guard let episodeURL = record.episodeURL else {
                outcome.delta.skipped += 1
                continue
            }
            let episodeDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.url == episodeURL }
            )
            let episode: Episode?
            do {
                episode = try legacyContext.fetch(episodeDescriptor).first
            } catch {
                outcome.error = error.localizedDescription
                outcome.reachedEnd = false
                break
            }
            guard let episode,
                  let lines = episode.transcriptLines,
                  lines.isEmpty == false else {
                outcome.delta.skipped += 1
                continue
            }

            do {
                let identity = episode.stableEpisodeIdentity
                let values = lines.map {
                    AITranscriptLineValue(
                        speaker: $0.speaker,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime
                    )
                }
                let encoded = try AIContentSyncCodec.encodeTranscript(values)
                let identityKey = identity.key
                let manifestDescriptor = FetchDescriptor<AITranscriptSync>(
                    predicate: #Predicate { $0.id == identityKey }
                )
                let manifest = try cacheContext.fetch(manifestDescriptor).first
                if let manifest, record.finishedAt <= manifest.updatedAt {
                    outcome.delta.skipped += 1
                    continue
                }

                for (index, payload) in encoded.chunks.enumerated() {
                    let chunkID = StableIdentityKey.make(
                        identity.key,
                        encoded.revisionID,
                        String(index)
                    )
                    let chunkDescriptor = FetchDescriptor<AITranscriptChunkSync>(
                        predicate: #Predicate { $0.id == chunkID }
                    )
                    guard try cacheContext.fetch(chunkDescriptor).first == nil else { continue }
                    cacheContext.insert(AITranscriptChunkSync(
                        transcriptID: identity.key,
                        revisionID: encoded.revisionID,
                        chunkIndex: index,
                        payloadJSON: payload,
                        contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8)),
                        updatedAt: record.finishedAt
                    ))
                }

                if let manifest {
                    manifest.revisionID = encoded.revisionID
                    manifest.localeIdentifier = record.localeIdentifier
                    manifest.chunkCount = encoded.chunks.count
                    manifest.lineCount = encoded.lineCount
                    manifest.contentHash = encoded.contentHash
                    manifest.generatedAt = record.finishedAt
                    manifest.deletedAt = nil
                    manifest.updatedAt = record.finishedAt
                    manifest.sourceDeviceID = sourceDeviceID
                    outcome.delta.updated += 1
                } else {
                    cacheContext.insert(AITranscriptSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: encoded.revisionID,
                        localeIdentifier: record.localeIdentifier,
                        chunkCount: encoded.chunks.count,
                        lineCount: encoded.lineCount,
                        contentHash: encoded.contentHash,
                        generatedAt: record.finishedAt,
                        updatedAt: record.finishedAt,
                        sourceDeviceID: sourceDeviceID
                    ))
                    outcome.delta.inserted += 1
                }
            } catch {
                outcome.delta.failed += 1
                outcome.error = error.localizedDescription
                outcome.reachedEnd = false
                break
            }
        }

        guard save(cacheContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "ai_transcript_cache_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: records, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = records.count < aiContentPageSize
        }
        return outcome
    }

    private static func processAIChapterPage(
        offset: Int,
        legacyContext: ModelContext,
        cacheContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<Episode>(sortBy: SourceOrder.episodes)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = aiContentPageSize
        let episodes: [Episode]
        do {
            episodes = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        let sourceDeviceID = ListeningDeviceIdentity.current().id
        for episode in episodes {
            guard shouldContinue() else {
                outcome.reachedEnd = false
                break
            }
            outcome.processed += 1
            let chapters = (episode.chapters ?? []).filter { $0.type == .ai }
            guard chapters.isEmpty == false else { continue }
            outcome.delta.scanned += 1
            do {
                let identity = episode.stableEpisodeIdentity
                let values = chapters.compactMap { chapter -> AIChapterValue? in
                    guard let start = chapter.start else { return nil }
                    return AIChapterValue(
                        title: chapter.title,
                        startTime: start,
                        duration: chapter.duration,
                        typeRawValue: chapter.type.rawValue,
                        analysisVariantID: chapter.analysisVariantID
                    )
                }
                guard values.isEmpty == false else {
                    outcome.delta.skipped += 1
                    continue
                }
                let encoded = try AIContentSyncCodec.encodeChapters(values)
                let generatedAt = chapters.compactMap(\.creationtime).max() ?? .distantPast
                let identityKey = identity.key
                let manifestDescriptor = FetchDescriptor<AIChapterSetSync>(
                    predicate: #Predicate { $0.id == identityKey }
                )
                let manifest = try cacheContext.fetch(manifestDescriptor).first
                if let manifest, generatedAt <= manifest.updatedAt {
                    outcome.delta.skipped += 1
                    continue
                }
                if let manifest {
                    manifest.revisionID = encoded.hash
                    manifest.payloadJSON = encoded.payload
                    manifest.chapterCount = values.count
                    manifest.contentHash = encoded.hash
                    manifest.generatedAt = generatedAt
                    manifest.updatedAt = generatedAt
                    manifest.sourceDeviceID = sourceDeviceID
                    outcome.delta.updated += 1
                } else {
                    cacheContext.insert(AIChapterSetSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: encoded.hash,
                        payloadJSON: encoded.payload,
                        chapterCount: values.count,
                        contentHash: encoded.hash,
                        generatedAt: generatedAt,
                        updatedAt: generatedAt,
                        sourceDeviceID: sourceDeviceID
                    ))
                    outcome.delta.inserted += 1
                }
            } catch {
                outcome.delta.failed += 1
                outcome.error = error.localizedDescription
                outcome.reachedEnd = false
                break
            }
        }

        guard save(cacheContext, result: &outcome.delta, shouldContinue: shouldContinue) else {
            outcome.error = shouldContinue() ? "ai_chapter_cache_save_failed" : nil
            outcome.processed = 0
            outcome.reachedEnd = false
            return outcome
        }
        outcome.boundaryKey = boundaryKey(of: episodes, processed: outcome.processed)
        if outcome.reachedEnd {
            outcome.reachedEnd = episodes.count < aiContentPageSize
        }
        return outcome
    }

    // MARK: - Phase bookkeeping

    /// Whether every required user-state and AI-cache phase has a completed
    /// checkpoint for this migration version.
    nonisolated static func isSliceMigrationComplete(
        cacheContainer: ModelContainer
    ) -> Bool {
        let context = makeContext(for: cacheContainer)
        return currentPhase(cache: context) == nil
    }

    /// Records the no-source case explicitly. A fresh install has no legacy
    /// rows to page, but leaving eight checkpoints absent makes diagnostics say
    /// `0/8` forever and keeps a completed no-op indistinguishable from a stall.
    @discardableResult
    nonisolated static func markMigrationCompleteWithoutSource(
        cacheContainer: ModelContainer
    ) -> Bool {
        let context = makeContext(for: cacheContainer)
        for phase in slicePhaseOrder {
            let id = checkpointID(for: phase)
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            let existing: StoreSplitMigrationCheckpoint?
            do {
                existing = try context.fetch(descriptor).first
            } catch {
                CrashBreadcrumbs.shared.record(
                    "store_split_no_source_checkpoint_fetch_failed",
                    details: "phase=\(phase),error=\(error.localizedDescription)"
                )
                return false
            }
            let checkpoint = existing ?? StoreSplitMigrationCheckpoint(
                    id: id,
                    migrationVersion: migrationVersion,
                    phase: phase,
                    cursor: "0",
                    startedAt: .now
                )
            if checkpoint.modelContext == nil {
                context.insert(checkpoint)
            }
            checkpoint.cursor = "0"
            checkpoint.completedAt = checkpoint.completedAt ?? .now
            checkpoint.updatedAt = .now
        }
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            CrashBreadcrumbs.shared.record(
                "store_split_no_source_checkpoint_save_failed",
                details: error.localizedDescription
            )
            return false
        }
    }

    nonisolated static func isMigrationVerified(
        cacheContainer: ModelContainer
    ) -> Bool {
        guard StoreSplitMigrationVerifier.unresolvedReleaseEvidence.isEmpty else { return false }
        return isDiagnosticVerificationPassed(cacheContainer: cacheContainer)
    }

    /// A local diagnostic result is useful for finding discrepancies, but it
    /// does not by itself prove current production coverage or convergence.
    nonisolated static func isDiagnosticVerificationPassed(
        cacheContainer: ModelContainer
    ) -> Bool {
        guard let record = StoreSplitMigrationVerifier.latestVerification(
            cacheContainer: cacheContainer
        ) else { return false }
        return record.migrationVersion == migrationVersion
            && record.verifiedAt != nil
            && record.issues.isEmpty
            && record.cacheMissingCount == 0
    }

    /// Shared diagnostics entry point for the automatic slice runner. Keeping
    /// the checkpoint-to-key formatting here prevents the App Store path from
    /// reporting a successful run with stale failure telemetry.
    nonisolated static func failedItemKeysForDiagnostics(
        from context: ModelContext
    ) -> [String] {
        let checkpoints = (try? context.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>())) ?? []
        return Array(
            checkpoints
                .filter { $0.failedCount > 0 }
                .map { "\($0.phase):\($0.lastError ?? "failed=\($0.failedCount)")" }
                .prefix(100)
        )
    }

    /// The first required phase whose checkpoint has not completed, or `nil` when
    /// the whole slice migration is finished.
    private static func currentPhase(cache: ModelContext) -> String? {
        // A failed read is not an empty ledger. Fail closed by keeping work
        // pending so the scheduler can retry once the cache store is readable.
        guard let fetched = try? cache.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>()) else {
            return slicePhaseOrder.first
        }
        let checkpoints = fetched
            .filter {
                $0.migrationVersion == migrationVersion
                    && $0.id == checkpointID(for: $0.phase)
            }
            .reduce(into: [String: [StoreSplitMigrationCheckpoint]]()) { $0[$1.phase, default: []].append($1) }
        for phase in slicePhaseOrder {
            guard let phaseCheckpoints = checkpoints[phase],
                  phaseCheckpoints.count == 1,
                  phaseCheckpoints[0].completedAt != nil else {
                return phase
            }
        }
        // A reset or partial ledger repair must not combine completed phases
        // from different verification runs. Fresh installs intentionally use
        // the explicit no-source cursor for all three phases.
        let first = checkpoints[Phase.listeningBaselineVerificationScan]![0]
        let second = checkpoints[Phase.listeningBaselineVerification]![0]
        let third = checkpoints[Phase.listeningBaselineVerificationComparison]![0]
        if first.cursor == "0", second.cursor == "0", third.cursor == "0" { return nil }
        guard let firstCursor = BaselineVerificationCursor.decode(first.cursor) else {
            return Phase.listeningBaselineVerificationScan
        }
        guard let secondCursor = BaselineVerificationCursor.decode(second.cursor),
              secondCursor.runID == firstCursor.runID,
              secondCursor.tier == firstCursor.tier else {
            return Phase.listeningBaselineVerification
        }
        guard let thirdCursor = BaselineVerificationCursor.decode(third.cursor),
              thirdCursor.runID == firstCursor.runID,
              thirdCursor.tier == firstCursor.tier else {
            return Phase.listeningBaselineVerificationComparison
        }
        return nil
    }

    private static func fetchSubscription(
        id: String,
        in context: ModelContext
    ) -> SubscriptionSync? {
        var descriptor = FetchDescriptor<SubscriptionSync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchPlaylist(
        id: String,
        in context: ModelContext
    ) -> PlaylistSync? {
        var descriptor = FetchDescriptor<PlaylistSync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchBookmark(
        id: String,
        in context: ModelContext
    ) -> BookmarkSync? {
        var descriptor = FetchDescriptor<BookmarkSync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchEpisodeState(
        id: String,
        in context: ModelContext
    ) -> EpisodeStateSync? {
        var descriptor = FetchDescriptor<EpisodeStateSync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchPreference(
        id: String,
        in context: ModelContext
    ) -> PodcastPreferenceSync? {
        var descriptor = FetchDescriptor<PodcastPreferenceSync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchListeningHistory(
        id: String,
        in context: ModelContext
    ) throws -> ListeningHistorySync? {
        var descriptor = FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func makeContext(for container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func legacyDeviceID(
        deviceModel: String?,
        osVersion: String?
    ) -> String {
        StableIdentityKey.make(
            "legacy-device",
            deviceModel ?? "unknown-model",
            osVersion ?? "unknown-os"
        )
    }

    @discardableResult
    private static func recordCheckpoint(
        phase: String,
        result: StoreSplitMigrationPhaseResult,
        cursor: String? = nil,
        completed: Bool = true,
        error: String? = nil,
        context: ModelContext
    ) -> Bool {
        let checkpointID = checkpointID(for: phase)
        var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        descriptor.fetchLimit = 2
        let existing: StoreSplitMigrationCheckpoint?
        do {
            let matches = try context.fetch(descriptor)
            guard matches.count <= 1 else {
                context.rollback()
                CrashBreadcrumbs.shared.record("store_split_checkpoint_duplicate", details: "phase=\(phase)")
                return false
            }
            existing = matches.first
        } catch {
            context.rollback()
            CrashBreadcrumbs.shared.record(
                "store_split_checkpoint_fetch_failed",
                details: "phase=\(phase),error=\(error.localizedDescription)"
            )
            return false
        }
        let checkpoint = existing ?? StoreSplitMigrationCheckpoint(
                id: checkpointID,
                migrationVersion: migrationVersion,
                phase: phase,
                startedAt: .now
            )

        if checkpoint.modelContext == nil {
            context.insert(checkpoint)
        }
        checkpoint.cursor = cursor
        checkpoint.completedAt = completed ? .now : nil
        checkpoint.scannedCount = result.scanned
        checkpoint.insertedCount = result.inserted
        checkpoint.updatedCount = result.updated
        checkpoint.skippedCount = result.skipped
        checkpoint.failedCount = result.failed
        checkpoint.lastError = error
        checkpoint.updatedAt = .now
        do {
            try context.save()
            CrashBreadcrumbs.shared.record(
                "store_split_checkpoint_saved",
                details: "phase=\(phase),complete=\(completed)"
            )
            return true
        } catch {
            context.rollback()
            CrashBreadcrumbs.shared.record(
                "store_split_checkpoint_save_failed",
                details: "phase=\(phase),error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private static func resumeProgress(
        phase: String,
        context: ModelContext
    ) -> (cursor: SliceCursor, result: StoreSplitMigrationPhaseResult) {
        let checkpointID = checkpointID(for: phase)
        let descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        guard let checkpoint = try? context.fetch(descriptor).first,
              checkpoint.completedAt == nil,
              let raw = checkpoint.cursor,
              let cursor = SliceCursor.decode(raw) else {
            return (SliceCursor(offset: 0), StoreSplitMigrationPhaseResult())
        }
        return (
            cursor,
            StoreSplitMigrationPhaseResult(
                scanned: checkpoint.scannedCount,
                inserted: checkpoint.insertedCount,
                updated: checkpoint.updatedCount,
                skipped: checkpoint.skippedCount,
                failed: checkpoint.failedCount
            )
        )
    }

    private static func failedItemKeys(from context: ModelContext) -> [String] {
        let checkpoints = (try? context.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>())) ?? []
        return Array(
            checkpoints
                .filter { $0.failedCount > 0 }
                .map { "\($0.phase):\($0.lastError ?? "failed=\($0.failedCount)")" }
                .prefix(maximumFailedItemKeys)
        )
    }

    @discardableResult
    private static func save(
        _ context: ModelContext,
        result: inout StoreSplitMigrationPhaseResult,
        shouldContinue: @Sendable () -> Bool
    ) -> Bool {
        guard context.hasChanges else { return true }
        guard shouldContinue() else {
            context.rollback()
            return false
        }
        do {
            try context.save()
            return true
        } catch {
            result.failed += 1
            context.rollback()
            CrashBreadcrumbs.shared.record(
                "store_split_migration_save_failed",
                details: error.localizedDescription
            )
            return false
        }
    }

    private static func latestDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

/// Describes the outcome of a reconciliation dry run. This release has not
/// proven deletion authority or all-device CloudKit convergence, so this
/// service must preserve destination-only rows and must not publish deletions.
enum StoreSplitReconciliationStatus: String, Sendable, Equatable {
    case notStarted
    case dryRunInProgress
    case dryRunCompleted
    case blockedAuthorityEvidence
    case fetchFailed
}

struct StoreSplitAuthoritativeReconciliationResult: Sendable, Equatable {
    var status: StoreSplitReconciliationStatus = .notStarted
    /// Nil means the dry run did not scan enough state to classify rows.
    var destinationOnlyPreserved: Int?
    var sourceOnly: Int?
    var conflicts: Int?
    var subscriptionsRepublished = 0
    var episodeStatesRepublished = 0
    var preferencesRepublished = 0
    var subscriptionsTombstoned = 0
    var playlistsTombstoned = 0
    var playlistEntriesTombstoned = 0
    var queueEntriesTombstoned = 0
    var bookmarksTombstoned = 0
    var preferencesDeleted = 0
    var episodeStatesDeleted = 0
    var listeningHistoryPreserved = 0
    var failed = 0
    var error: String?

    var republishedCount: Int {
        subscriptionsRepublished + episodeStatesRepublished + preferencesRepublished
    }

    var cleanupCount: Int {
        subscriptionsTombstoned
            + playlistsTombstoned
            + playlistEntriesTombstoned
            + queueEntriesTombstoned
            + bookmarksTombstoned
            + preferencesDeleted
            + episodeStatesDeleted
    }

    var changedCount: Int {
        republishedCount + cleanupCount
    }
}

enum StoreSplitAuthoritativeReconciliationService {
    nonisolated static func reconcile(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) async -> StoreSplitAuthoritativeReconciliationResult {
        // Destination-only CloudKit rows cannot be assumed stale merely because
        // the current device's legacy snapshot lacks them. Until source lineage,
        // CloudKit convergence and timestamp/tombstone authority are recorded,
        // reconciliation is intentionally a non-destructive blocked stage.
        var result = StoreSplitAuthoritativeReconciliationResult()
        result.status = .blockedAuthorityEvidence
        result.failed = 1
        result.error = "Destination-only records preserved: authoritative lineage and CloudKit convergence are not proven"
        CrashBreadcrumbs.shared.record(
            "store_split_reconciliation_preserved_destination_only",
            details: "reason=authority_evidence_unavailable"
        )
        return result
    }
}
