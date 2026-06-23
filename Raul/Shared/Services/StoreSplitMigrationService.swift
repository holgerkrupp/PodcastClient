import Foundation
import SwiftData

struct StoreSplitMigrationResult: Sendable {
    var subscriptions = StoreSplitMigrationPhaseResult()
    var episodeStates = StoreSplitMigrationPhaseResult()
    var playlists = StoreSplitMigrationPhaseResult()
    var playlistEntries = StoreSplitMigrationPhaseResult()
    var queueEntries = StoreSplitMigrationPhaseResult()
    var bookmarks = StoreSplitMigrationPhaseResult()
    var listeningHistory = StoreSplitMigrationPhaseResult()
    var listeningSummaries = StoreSplitMigrationPhaseResult()
    var aiTranscripts = StoreSplitMigrationPhaseResult()
    var aiChapters = StoreSplitMigrationPhaseResult()

    var failedCount: Int {
        subscriptions.failed
            + episodeStates.failed
            + playlists.failed
            + playlistEntries.failed
            + queueEntries.failed
            + bookmarks.failed
            + listeningHistory.failed
            + listeningSummaries.failed
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
        /// Every non-AI phase has completed.
        case completed
        /// The slice was cancelled before doing work.
        case cancelled
        /// A fetch/save error stopped the current phase.
        case failed
    }

    var status: Status
    var phase: String?
    var processed: Int = 0
    var footprintBefore: UInt64 = 0
    var footprintAfter: UInt64 = 0
    var error: String?

    var footprintDeltaDescription: String {
        MemoryFootprint.formattedDelta(before: footprintBefore, after: footprintAfter)
    }
}

actor StoreSplitMigrationService {
    nonisolated static let migrationVersion = 3

    /// Per-slice record budget for the light phases. Heavier phases override this
    /// with smaller pages because each record faults a larger object graph.
    private static let defaultPageSize = 100
    private static let episodePageSize = 50
    private static let listeningHistoryPageSize = 10
    private static let aiContentPageSize = 10
    private static let maximumFailedItemKeys = 100

    /// Ordered, memory-prioritised list of non-AI phases. Subscriptions,
    /// playlists/queue, bookmarks, and recent playback state come first; the
    /// heavy listening-history phases come last. AI transcript/chapter migration
    /// is intentionally excluded from the slice engine.
    nonisolated static let slicePhaseOrder = [
        Phase.subscriptions,
        Phase.playlists,
        Phase.playlistEntries,
        Phase.bookmarks,
        Phase.episodeStates,
        Phase.listeningSummaries,
        Phase.listeningHistory
    ]

    enum Phase {
        static let subscriptions = "subscriptions"
        static let playlists = "playlists"
        static let playlistEntries = "playlist_entries"
        static let queueEntries = "queue_entries"
        static let bookmarks = "bookmarks"
        static let episodeStates = "episode_states"
        static let listeningSummaries = "listening_summaries"
        static let listeningHistory = "listening_history"
    }

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
        shouldContinue: @escaping @Sendable () -> Bool = { Task.isCancelled == false }
    ) async -> StoreSplitSliceReport {
        let worker = StoreSplitMigrationService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )
        return await worker.runOneSlice(shouldContinue: shouldContinue)
    }

    /// Convenience whole-run used by tests and the development "run now" path.
    /// Loops the slice engine to completion, then migrates AI content when
    /// requested (the slice engine itself never touches AI content).
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

    private func runOneSlice(
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

        let resume = Self.resumeProgress(phase: phase, context: cacheContext)
        let legacyContext = Self.makeContext(for: legacyContainer)
        let userStateContext = Self.makeContext(for: userStateContainer)

        let outcome = processPage(
            phase: phase,
            offset: resume.offset,
            legacyContext: legacyContext,
            userStateContext: userStateContext,
            cacheContext: cacheContext,
            shouldContinue: shouldContinue
        )

        let combined = resume.result + outcome.delta
        let newOffset = resume.offset + outcome.processed
        Self.recordCheckpoint(
            phase: phase,
            result: combined,
            cursor: String(newOffset),
            completed: outcome.reachedEnd,
            error: outcome.error,
            context: cacheContext
        )

        if phase == Phase.playlistEntries {
            let queueResume = Self.resumeProgress(
                phase: Phase.queueEntries,
                context: cacheContext
            )
            Self.recordCheckpoint(
                phase: Phase.queueEntries,
                result: queueResume.result + outcome.queueDelta,
                cursor: String(newOffset),
                completed: outcome.reachedEnd,
                context: cacheContext
            )
        }

        let footprintAfter = MemoryFootprint.current()
        CrashBreadcrumbs.shared.record(
            "store_split_migration_slice",
            details: "phase=\(phase),processed=\(outcome.processed),end=\(outcome.reachedEnd),footprint=\(MemoryFootprint.formattedDelta(before: footprintBefore, after: footprintAfter))"
        )

        let status: StoreSplitSliceReport.Status
        if outcome.error != nil {
            status = .failed
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
        for phase in Self.slicePhaseOrder {
            guard Task.isCancelled == false else { return result }
            let phaseResult = processPhaseFully(phase)
            switch phase {
            case Phase.subscriptions: result.subscriptions = phaseResult.primary
            case Phase.playlists: result.playlists = phaseResult.primary
            case Phase.playlistEntries:
                result.playlistEntries = phaseResult.primary
                result.queueEntries = phaseResult.queue
            case Phase.bookmarks: result.bookmarks = phaseResult.primary
            case Phase.episodeStates: result.episodeStates = phaseResult.primary
            case Phase.listeningSummaries: result.listeningSummaries = phaseResult.primary
            case Phase.listeningHistory: result.listeningHistory = phaseResult.primary
            default: break
            }
            await Task.yield()
        }

        if includeAIContent {
            guard Task.isCancelled == false else { return result }
            let userStateContext = Self.makeContext(for: userStateContainer)
            let cacheContext = Self.makeContext(for: cacheContainer)
            let aiContentResults = Self.migrateAIContent(
                legacyContainer: legacyContainer,
                destinationContext: userStateContext
            )
            result.aiTranscripts = aiContentResults.transcripts
            result.aiChapters = aiContentResults.chapters
            Self.recordCheckpoint(phase: "ai_transcripts", result: result.aiTranscripts, context: cacheContext)
            Self.recordCheckpoint(phase: "ai_chapters", result: result.aiChapters, context: cacheContext)
        } else {
            CrashBreadcrumbs.shared.record(
                "store_split_ai_migration_deferred",
                details: "reason=automatic_memory_safety"
            )
        }

        let diagnosticsCache = Self.makeContext(for: cacheContainer)
        StoreSplitMigrationDiagnostics.recordMigrationRun()
        StoreSplitMigrationDiagnostics.recordFailedItems(
            Self.failedItemKeys(from: diagnosticsCache)
        )
        CrashBreadcrumbs.shared.record(
            "store_split_migration_completed",
            details: "failed=\(result.failedCount),subscriptions=\(result.subscriptions.scanned),episodes=\(result.episodeStates.scanned),playlists=\(result.playlists.scanned),bookmarks=\(result.bookmarks.scanned),history=\(result.listeningHistory.scanned),summaries=\(result.listeningSummaries.scanned),ai_transcripts=\(result.aiTranscripts.scanned),ai_chapters=\(result.aiChapters.scanned)"
        )
        return result
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
        while true {
            // Each page runs inside its own autorelease pool so the faulted
            // object graph and the autoreleased CoreFoundation temporaries
            // (CFString/NSURL backing the row data) are released between pages
            // instead of accumulating across the whole phase.
            let outcome = autoreleasepool { () -> PageOutcome in
                let legacyContext = Self.makeContext(for: legacyContainer)
                let userStateContext = Self.makeContext(for: userStateContainer)
                let cacheContext = Self.makeContext(for: cacheContainer)

                let outcome = processPage(
                    phase: phase,
                    offset: offset,
                    legacyContext: legacyContext,
                    userStateContext: userStateContext,
                    cacheContext: cacheContext,
                    shouldContinue: { Task.isCancelled == false }
                )
                run.primary = run.primary + outcome.delta
                run.queue = run.queue + outcome.queueDelta
                offset += outcome.processed

                Self.recordCheckpoint(
                    phase: phase,
                    result: run.primary,
                    cursor: String(offset),
                    completed: outcome.reachedEnd,
                    error: outcome.error,
                    context: cacheContext
                )
                if phase == Phase.playlistEntries {
                    Self.recordCheckpoint(
                        phase: Phase.queueEntries,
                        result: run.queue,
                        cursor: String(offset),
                        completed: outcome.reachedEnd,
                        context: cacheContext
                    )
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
    }

    private func processPage(
        phase: String,
        offset: Int,
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
        case Phase.episodeStates:
            return Self.processEpisodeStatesPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        case Phase.listeningSummaries:
            return Self.processListeningSummaries(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext
            )
        case Phase.listeningHistory:
            return Self.processListeningHistoryPage(
                offset: offset,
                legacyContext: legacyContext,
                destinationContext: userStateContext,
                shouldContinue: shouldContinue
            )
        default:
            return PageOutcome()
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
        var descriptor = FetchDescriptor<Podcast>(
            sortBy: [SortDescriptor(\Podcast.title)]
        )
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

        save(destinationContext, result: &outcome.delta)
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
        var descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\Playlist.sortIndex), SortDescriptor(\Playlist.title)]
        )
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

            let playlistID = playlist.id.uuidString
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
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                outcome.delta.inserted += 1
            }
        }

        save(destinationContext, result: &outcome.delta)
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
        var descriptor = FetchDescriptor<PlaylistEntry>(
            sortBy: [SortDescriptor(\PlaylistEntry.order)]
        )
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
            let playlistID = playlist.id.uuidString
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

        save(destinationContext, result: &outcome.delta)
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
        var descriptor = FetchDescriptor<Bookmark>(
            sortBy: [SortDescriptor(\Bookmark.creationtime)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = defaultPageSize

        let bookmarks: [Bookmark]
        do {
            bookmarks = try legacyContext.fetch(descriptor)
        } catch {
            outcome.error = error.localizedDescription
            outcome.reachedEnd = false
            return outcome
        }

        for bookmark in bookmarks {
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

        save(destinationContext, result: &outcome.delta)
        if outcome.reachedEnd {
            outcome.reachedEnd = bookmarks.count < defaultPageSize
        }
        return outcome
    }

    // MARK: - Episode playback state (recent first)

    private static func processEpisodeStatesPage(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<Episode>(
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = episodePageSize
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
            let updatedAt = latestDate(
                metadata.lastPlayed,
                metadata.completionDate,
                metadata.archivedAt,
                metadata.firstListenDate
            ) ?? .distantPast

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

        save(destinationContext, result: &outcome.delta)
        if outcome.reachedEnd {
            outcome.reachedEnd = episodes.count < episodePageSize
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
        legacyContext: ModelContext,
        destinationContext: ModelContext,
        shouldContinue: @Sendable () -> Bool
    ) -> PageOutcome {
        var outcome = PageOutcome()
        var descriptor = FetchDescriptor<PlaySession>(
            sortBy: [SortDescriptor(\PlaySession.startTime)]
        )
        descriptor.fetchLimit = listeningHistoryPageSize
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
                  let startedAt = session.startTime,
                  let endedAt = session.endTime,
                  endedAt > startedAt else {
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

            if let destination = fetchListeningHistory(
                id: recordID,
                in: destinationContext
            ) {
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
                        updatedAt: updatedAt
                    )
                )
                outcome.delta.inserted += 1
            }
        }

        save(destinationContext, result: &outcome.delta)
        if outcome.reachedEnd {
            outcome.reachedEnd = sessions.count < listeningHistoryPageSize
        }
        return outcome
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
        destination.updatedAt = updatedAt
    }

    // MARK: - Listening summaries

    private struct LegacySummaryKey: Hashable {
        let feedURL: String
        let periodKind: String
        let periodStart: Date
    }

    private struct LegacySummaryValue {
        var podcastName: String?
        var totalSeconds = 0.0
        var silenceGapTimeSavedSeconds = 0.0
        var playbackRateTimeSavedSeconds = 0.0
        var activeHourCount = 0
        var seenRecordIDs = Set<String>()
    }

    /// Listening summaries are aggregated period totals (a few records per period
    /// per podcast), so the whole phase runs in a single slice. Aggregating the
    /// full set in one pass preserves the existing summing semantics; paging it
    /// would split same-key summaries across pages and break the totals.
    private static func processListeningSummaries(
        offset: Int,
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> PageOutcome {
        var outcome = PageOutcome()
        // Already completed in a prior slice within this phase.
        guard offset == 0 else {
            outcome.reachedEnd = true
            return outcome
        }

        let legacySummaries = (try? legacyContext.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        var aggregates: [LegacySummaryKey: LegacySummaryValue] = [:]

        for summary in legacySummaries {
            outcome.delta.scanned += 1
            guard let periodKind = summary.periodKind,
                  let periodStart = summary.periodStart else {
                outcome.delta.skipped += 1
                continue
            }

            let feedURL = summary.podcastFeed
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? "__all_podcasts__"
            let key = LegacySummaryKey(
                feedURL: feedURL,
                periodKind: periodKind,
                periodStart: periodStart
            )
            let recordID = summary.id?.uuidString ?? StableIdentityKey.make(
                feedURL,
                periodKind,
                String(periodStart.timeIntervalSince1970),
                summary.podcastName ?? ""
            )
            guard aggregates[key]?.seenRecordIDs.contains(recordID) != true else {
                outcome.delta.skipped += 1
                continue
            }

            var value = aggregates[key] ?? LegacySummaryValue()
            value.seenRecordIDs.insert(recordID)
            value.podcastName = summary.podcastName ?? value.podcastName
            value.totalSeconds += max(0, summary.totalSeconds ?? 0)
            value.silenceGapTimeSavedSeconds += max(0, summary.silenceGapTimeSavedSeconds ?? 0)
            value.playbackRateTimeSavedSeconds += max(0, summary.playbackRateTimeSavedSeconds ?? 0)
            value.activeHourCount += max(0, summary.activeHourCount ?? 0)
            aggregates[key] = value
        }

        var recordsByID = ((try? destinationContext.fetch(FetchDescriptor<ListeningSummarySync>())) ?? [])
            .reduce(into: [String: ListeningSummarySync]()) { $0[$1.id] = $1 }

        for (key, value) in aggregates {
            let candidate = ListeningSummarySync(
                feedURL: key.feedURL,
                periodKind: key.periodKind,
                periodStart: key.periodStart,
                sourceDeviceID: ListeningDeviceIdentity.legacySharedID,
                sourceDeviceName: "Migrated history",
                podcastName: value.podcastName,
                totalSeconds: value.totalSeconds,
                silenceGapTimeSavedSeconds: value.silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: value.playbackRateTimeSavedSeconds,
                activeHourCount: value.activeHourCount,
                updatedAt: .now
            )

            if let destination = recordsByID[candidate.id] {
                // Partial CloudKit imports may reveal additional legacy summaries later.
                let totalSeconds = max(destination.totalSeconds, candidate.totalSeconds)
                let silenceGapTimeSavedSeconds = max(
                    destination.silenceGapTimeSavedSeconds,
                    candidate.silenceGapTimeSavedSeconds
                )
                let playbackRateTimeSavedSeconds = max(
                    destination.playbackRateTimeSavedSeconds,
                    candidate.playbackRateTimeSavedSeconds
                )
                let activeHourCount = max(
                    destination.activeHourCount,
                    candidate.activeHourCount
                )
                let podcastName = candidate.podcastName ?? destination.podcastName
                let changed = totalSeconds != destination.totalSeconds
                    || silenceGapTimeSavedSeconds != destination.silenceGapTimeSavedSeconds
                    || playbackRateTimeSavedSeconds != destination.playbackRateTimeSavedSeconds
                    || activeHourCount != destination.activeHourCount
                    || podcastName != destination.podcastName

                if changed {
                    destination.totalSeconds = totalSeconds
                    destination.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
                    destination.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
                    destination.activeHourCount = activeHourCount
                    destination.podcastName = podcastName
                    destination.updatedAt = .now
                    outcome.delta.updated += 1
                } else {
                    outcome.delta.skipped += 1
                }
            } else {
                destinationContext.insert(candidate)
                recordsByID[candidate.id] = candidate
                outcome.delta.inserted += 1
            }
        }

        save(destinationContext, result: &outcome.delta)
        outcome.processed = legacySummaries.count
        outcome.reachedEnd = true
        return outcome
    }

    // MARK: - AI content (whole-run only; excluded from the slice engine)

    private static func migrateAIContent(
        legacyContainer: ModelContainer,
        destinationContext: ModelContext
    ) -> (
        transcripts: StoreSplitMigrationPhaseResult,
        chapters: StoreSplitMigrationPhaseResult
    ) {
        var transcriptResult = StoreSplitMigrationPhaseResult()
        var chapterResult = StoreSplitMigrationPhaseResult()
        // The transcript phase keeps a single legacy context alive because
        // `latestRecordByEpisodeURL` holds faulted `TranscriptionRecord` objects
        // from it. The chapter phase below pages with a fresh context per page.
        let legacyContext = Self.makeContext(for: legacyContainer)
        let records = (try? legacyContext.fetch(FetchDescriptor<TranscriptionRecord>())) ?? []
        let latestRecordByEpisodeURL = records.reduce(
            into: [URL: TranscriptionRecord]()
        ) { result, record in
            guard let episodeURL = record.episodeURL else { return }
            if let existing = result[episodeURL], existing.finishedAt >= record.finishedAt {
                return
            }
            result[episodeURL] = record
        }
        var transcriptsByID = ((try? destinationContext.fetch(FetchDescriptor<AITranscriptSync>())) ?? [])
            .reduce(into: [String: AITranscriptSync]()) { $0[$1.id] = $1 }
        var chapterSetsByID = ((try? destinationContext.fetch(FetchDescriptor<AIChapterSetSync>())) ?? [])
            .reduce(into: [String: AIChapterSetSync]()) { $0[$1.id] = $1 }
        let sourceDeviceID = ListeningDeviceIdentity.current().id

        for (episodeURL, record) in latestRecordByEpisodeURL {
            autoreleasepool {
                transcriptResult.scanned += 1
                let episodeDescriptor = FetchDescriptor<Episode>(
                    predicate: #Predicate<Episode> { $0.url == episodeURL }
                )
                guard let episode = try? legacyContext.fetch(episodeDescriptor).first,
                      let lines = episode.transcriptLines,
                      lines.isEmpty == false else {
                    transcriptResult.skipped += 1
                    return
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

                    for (index, payload) in encoded.chunks.enumerated() {
                        let chunkID = StableIdentityKey.make(
                            identity.key,
                            encoded.revisionID,
                            String(index)
                        )
                        let chunkDescriptor = FetchDescriptor<AITranscriptChunkSync>(
                            predicate: #Predicate<AITranscriptChunkSync> { $0.id == chunkID }
                        )
                        if (try? destinationContext.fetch(chunkDescriptor).first) == nil {
                            let chunk = AITranscriptChunkSync(
                                transcriptID: identity.key,
                                revisionID: encoded.revisionID,
                                chunkIndex: index,
                                payloadJSON: payload,
                                contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8)),
                                updatedAt: record.finishedAt
                            )
                            destinationContext.insert(chunk)
                        }
                    }

                    if let transcript = transcriptsByID[identity.key] {
                        guard record.finishedAt > transcript.updatedAt else {
                            transcriptResult.skipped += 1
                            return
                        }
                        transcript.revisionID = encoded.revisionID
                        transcript.localeIdentifier = record.localeIdentifier
                        transcript.chunkCount = encoded.chunks.count
                        transcript.lineCount = encoded.lineCount
                        transcript.contentHash = encoded.contentHash
                        transcript.generatedAt = record.finishedAt
                        transcript.deletedAt = nil
                        transcript.updatedAt = record.finishedAt
                        transcript.sourceDeviceID = sourceDeviceID
                        transcriptResult.updated += 1
                    } else {
                        let transcript = AITranscriptSync(
                            feedURL: identity.feedURL,
                            episodeID: identity.episodeID,
                            revisionID: encoded.revisionID,
                            localeIdentifier: record.localeIdentifier,
                            chunkCount: encoded.chunks.count,
                            lineCount: encoded.lineCount,
                            contentHash: encoded.contentHash,
                            generatedAt: record.finishedAt,
                            deletedAt: nil,
                            updatedAt: record.finishedAt,
                            sourceDeviceID: sourceDeviceID
                        )
                        destinationContext.insert(transcript)
                        transcriptsByID[identity.key] = transcript
                        transcriptResult.inserted += 1
                    }
                } catch {
                    transcriptResult.failed += 1
                }
            }
        }
        save(destinationContext, result: &transcriptResult)

        var episodeOffset = 0
        while true {
            guard Task.isCancelled == false else { break }
            // Fresh context per page so each batch of faulted episodes (and their
            // chapter relationships) is released before the next page loads.
            let reachedEnd = autoreleasepool { () -> Bool in
                let pageContext = Self.makeContext(for: legacyContainer)
                var descriptor = FetchDescriptor<Episode>(
                    sortBy: [SortDescriptor(\Episode.publishDate)]
                )
                descriptor.fetchLimit = aiContentPageSize
                descriptor.fetchOffset = episodeOffset
                guard let episodes = try? pageContext.fetch(descriptor),
                      episodes.isEmpty == false else {
                    return true
                }

                for episode in episodes {
                let aiChapters = (episode.chapters ?? []).filter { $0.type == .ai }
                guard aiChapters.isEmpty == false else { continue }
                chapterResult.scanned += 1

                do {
                    let identity = episode.stableEpisodeIdentity
                    let values = aiChapters.compactMap { chapter -> AIChapterValue? in
                        guard let start = chapter.start else { return nil }
                        return AIChapterValue(
                            title: chapter.title,
                            startTime: start,
                            duration: chapter.duration
                        )
                    }
                    guard values.isEmpty == false else {
                        chapterResult.skipped += 1
                        continue
                    }
                    let encoded = try AIContentSyncCodec.encodeChapters(values)
                    let generatedAt = aiChapters.compactMap(\.creationtime).max() ?? .distantPast

                    if let chapterSet = chapterSetsByID[identity.key] {
                        guard generatedAt > chapterSet.updatedAt else {
                            chapterResult.skipped += 1
                            continue
                        }
                        chapterSet.revisionID = encoded.hash
                        chapterSet.payloadJSON = encoded.payload
                        chapterSet.chapterCount = values.count
                        chapterSet.contentHash = encoded.hash
                        chapterSet.generatedAt = generatedAt
                        chapterSet.updatedAt = generatedAt
                        chapterSet.sourceDeviceID = sourceDeviceID
                        chapterResult.updated += 1
                    } else {
                        let chapterSet = AIChapterSetSync(
                            feedURL: identity.feedURL,
                            episodeID: identity.episodeID,
                            revisionID: encoded.hash,
                            payloadJSON: encoded.payload,
                            chapterCount: values.count,
                            contentHash: encoded.hash,
                            generatedAt: generatedAt,
                            updatedAt: generatedAt,
                            sourceDeviceID: sourceDeviceID
                        )
                        destinationContext.insert(chapterSet)
                        chapterSetsByID[identity.key] = chapterSet
                        chapterResult.inserted += 1
                    }
                } catch {
                    chapterResult.failed += 1
                }
                }

                save(destinationContext, result: &chapterResult)
                episodeOffset += episodes.count
                return episodes.count < aiContentPageSize
            }

            if reachedEnd {
                break
            }
        }

        save(destinationContext, result: &chapterResult)
        return (transcriptResult, chapterResult)
    }

    // MARK: - Phase bookkeeping

    /// Whether every non-AI phase has a completed checkpoint for this migration
    /// version. Used by the rollout to decide when an existing user can switch to
    /// reading from the split store.
    nonisolated static func isSliceMigrationComplete(
        cacheContainer: ModelContainer
    ) -> Bool {
        let context = makeContext(for: cacheContainer)
        return currentPhase(cache: context) == nil
    }

    /// The first non-AI phase whose checkpoint has not completed, or `nil` when
    /// the whole slice migration is finished.
    private static func currentPhase(cache: ModelContext) -> String? {
        let checkpoints = ((try? cache.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>())) ?? [])
            .filter { $0.migrationVersion == migrationVersion }
            .reduce(into: [String: StoreSplitMigrationCheckpoint]()) { $0[$1.phase] = $1 }
        for phase in slicePhaseOrder {
            let checkpoint = checkpoints[phase]
            if checkpoint == nil || checkpoint?.completedAt == nil {
                return phase
            }
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

    private static func fetchListeningHistory(
        id: String,
        in context: ModelContext
    ) -> ListeningHistorySync? {
        var descriptor = FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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

    private static func recordCheckpoint(
        phase: String,
        result: StoreSplitMigrationPhaseResult,
        cursor: String? = nil,
        completed: Bool = true,
        error: String? = nil,
        context: ModelContext
    ) {
        let checkpointID = "v\(migrationVersion).\(phase)"
        let descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        let checkpoint = (try? context.fetch(descriptor).first)
            ?? StoreSplitMigrationCheckpoint(
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
        try? context.save()
    }

    private static func resumeProgress(
        phase: String,
        context: ModelContext
    ) -> (offset: Int, result: StoreSplitMigrationPhaseResult) {
        let checkpointID = "v\(migrationVersion).\(phase)"
        let descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        guard let checkpoint = try? context.fetch(descriptor).first,
              checkpoint.completedAt == nil,
              let cursor = checkpoint.cursor,
              let offset = Int(cursor) else {
            return (0, StoreSplitMigrationPhaseResult())
        }
        return (
            max(0, offset),
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

    private static func save(
        _ context: ModelContext,
        result: inout StoreSplitMigrationPhaseResult
    ) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_migration_save_failed",
                details: error.localizedDescription
            )
        }
    }

    private static func latestDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}
