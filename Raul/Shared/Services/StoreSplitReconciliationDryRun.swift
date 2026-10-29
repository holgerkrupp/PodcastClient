import Foundation
import SwiftData

/// A local, read-only traversal of the portable playlist records. The scan is
/// evidence for diagnostics, not proof that CloudKit imports have converged or
/// that this device's legacy store is authoritative.
struct StoreSplitPlaylistReconciliationProgress: Codable, Equatable, Sendable {
    var lastID: String?
    var scanned = 0
    var matching = 0
    var semanticConflicts = 0
    var unresolvedLineage = 0
    var tombstonesPreserved = 0
    var inconsistentTombstones = 0
    var duplicateIdentities = 0
    var traversalComplete = false

    var isValid: Bool {
        guard scanned >= 0,
              (scanned == 0) == (lastID == nil) else { return false }
        var unclassified = scanned
        for count in [matching, semanticConflicts, unresolvedLineage,
                      tombstonesPreserved, inconsistentTombstones, duplicateIdentities] {
            guard count >= 0, count <= unclassified else { return false }
            unclassified -= count
        }
        return unclassified == 0
    }
}

struct StoreSplitPlaylistReconciliationPage: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case advanced
        case traversalCompleted
        case blockedDuplicateIdentity
        case cancelled
        case failed
    }

    var status: Status
    var progress: StoreSplitPlaylistReconciliationProgress
    /// Stable, privacy-safe failure code; never contains a feed URL or row ID.
    var error: String? = nil
}

/// Scans a bounded destination page per call and commits progress to the local
/// PodcastCache checkpoint in the same transaction. A completed traversal
/// remains unresolved authority evidence: a later import or legacy change can
/// introduce records before the cursor, so callers must restart after changes
/// and separately prove CloudKit convergence before using any result as a gate.
actor StoreSplitReconciliationDryRun {
    static var checkpointID: String {
        "storeSplit.reconciliation.v\(StoreSplitMigrationService.migrationVersion).playlists.r1"
    }
    static let checkpointPhase = "reconciliation_playlist_dry_run"
    static let maximumPageSize = 100

    private let legacy: ModelContext
    private let destination: ModelContext
    private let cache: ModelContext

    private init(legacy: ModelContainer, destination: ModelContainer, cache: ModelContainer) {
        self.legacy = ModelContext(legacy)
        self.destination = ModelContext(destination)
        self.cache = ModelContext(cache)
        self.cache.autosaveEnabled = false
    }

    nonisolated static func runPlaylistPage(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        pageSize: Int = 50,
        restart: Bool = false,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) async -> StoreSplitPlaylistReconciliationPage {
        let worker = StoreSplitReconciliationDryRun(
            legacy: legacyContainer, destination: userStateContainer, cache: cacheContainer
        )
        return await worker.runPlaylistPage(
            pageSize: max(1, min(pageSize, maximumPageSize)),
            restart: restart,
            shouldContinue: shouldContinue
        )
    }

    private func runPlaylistPage(
        pageSize: Int,
        restart: Bool,
        shouldContinue: @Sendable () -> Bool
    ) -> StoreSplitPlaylistReconciliationPage {
        var checkpoint: StoreSplitMigrationCheckpoint?
        do {
            let id = Self.checkpointID
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 2
            let checkpoints = try cache.fetch(descriptor)
            guard checkpoints.count <= 1 else {
                return failure("duplicate_checkpoint")
            }
            checkpoint = checkpoints.first
        } catch {
            return failure("checkpoint_fetch_failed")
        }

        var progress: StoreSplitPlaylistReconciliationProgress
        if restart || checkpoint == nil {
            progress = StoreSplitPlaylistReconciliationProgress()
        } else if let raw = checkpoint?.cursor,
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(StoreSplitPlaylistReconciliationProgress.self, from: data),
                  decoded.isValid {
            progress = decoded
        } else {
            return failure("checkpoint_invalid")
        }
        let initialProgress = progress

        guard shouldContinue() else {
            return .init(status: .cancelled, progress: progress)
        }
        if restart {
            // Invalidate the old traversal before reading either store. If a
            // fetch fails or the task expires, a subsequent resume cannot
            // mistake the old completed pass for this new scan.
            let reset = saveProgress(
                progress, checkpoint: checkpoint, restart: true, status: .advanced
            )
            guard reset.status != .failed else { return reset }
            if checkpoint == nil {
                do {
                    let id = Self.checkpointID
                    var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                        predicate: #Predicate { $0.id == id }
                    )
                    descriptor.fetchLimit = 1
                    checkpoint = try cache.fetch(descriptor).first
                    guard checkpoint != nil else { return failure("checkpoint_fetch_failed") }
                } catch {
                    return failure("checkpoint_fetch_failed")
                }
            }
        }
        guard shouldContinue() else {
            return .init(status: .cancelled, progress: progress)
        }
        if progress.traversalComplete {
            return .init(status: .traversalCompleted, progress: progress)
        }

        var descriptor: FetchDescriptor<PlaylistSync>
        if let lastID = progress.lastID {
            descriptor = FetchDescriptor(
                predicate: #Predicate<PlaylistSync> { $0.id > lastID },
                sortBy: [SortDescriptor(\PlaylistSync.id)]
            )
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\PlaylistSync.id)])
        }
        descriptor.fetchLimit = pageSize + 1
        let fetched: [PlaylistSync]
        do {
            fetched = try destination.fetch(descriptor)
        } catch {
            return failure("destination_fetch_failed", progress: progress)
        }
        guard shouldContinue() else {
            return .init(status: .cancelled, progress: initialProgress)
        }

        // Never advance past a group of duplicate IDs split by the page limit.
        // A pathological group larger than the budget blocks for repair rather
        // than requiring an unbounded fetch or silently skipping records.
        var page = Array(fetched.prefix(pageSize))
        if fetched.count > pageSize,
           let last = page.last,
           last.id == fetched[pageSize].id {
            let boundaryID = last.id
            while page.last?.id == boundaryID { page.removeLast() }
            if page.isEmpty {
                return saveProgress(
                    initialProgress, checkpoint: checkpoint, restart: false,
                    status: .blockedDuplicateIdentity,
                    error: "duplicate_identity_exceeds_page_budget"
                )
            }
        }

        var index = 0
        while index < page.count {
            guard shouldContinue() else {
                return .init(status: .cancelled, progress: initialProgress)
            }
            let id = page[index].id
            var end = index + 1
            while end < page.count, page[end].id == id { end += 1 }
            progress.scanned += end - index
            if end - index > 1 || id.isEmpty {
                progress.duplicateIdentities += end - index
            } else {
                do {
                    try classify(page[index], progress: &progress)
                } catch {
                    return failure("source_fetch_failed", progress: initialProgress)
                }
            }
            progress.lastID = id
            index = end
        }
        guard shouldContinue() else {
            return .init(status: .cancelled, progress: initialProgress)
        }
        progress.traversalComplete = fetched.count <= pageSize
        return saveProgress(
            progress, checkpoint: checkpoint, restart: false,
            status: progress.traversalComplete ? .traversalCompleted : .advanced,
            previousProgress: initialProgress
        )
    }

    private func saveProgress(
        _ progress: StoreSplitPlaylistReconciliationProgress,
        checkpoint existing: StoreSplitMigrationCheckpoint?,
        restart: Bool,
        status: StoreSplitPlaylistReconciliationPage.Status,
        error: String? = nil,
        previousProgress: StoreSplitPlaylistReconciliationProgress? = nil
    ) -> StoreSplitPlaylistReconciliationPage {
        do {
            let checkpoint = existing ?? StoreSplitMigrationCheckpoint(
                id: Self.checkpointID,
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: Self.checkpointPhase,
                startedAt: .now
            )
            if checkpoint.modelContext == nil { cache.insert(checkpoint) }
            if restart { checkpoint.startedAt = .now }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            checkpoint.cursor = String(decoding: try encoder.encode(progress), as: UTF8.self)
            checkpoint.scannedCount = progress.scanned
            checkpoint.completedAt = progress.traversalComplete ? .now : nil
            checkpoint.failedCount = error == nil ? 0 : 1
            checkpoint.lastError = error
            checkpoint.updatedAt = .now
            try cache.save()
        } catch {
            cache.rollback()
            return failure("checkpoint_save_failed", progress: previousProgress ?? progress)
        }
        return .init(status: status, progress: progress, error: error)
    }

    private func classify(
        _ portable: PlaylistSync,
        progress: inout StoreSplitPlaylistReconciliationProgress
    ) throws {
        if portable.isDeleted != (portable.deletedAt != nil) {
            progress.inconsistentTombstones += 1
            return
        }
        if portable.isDeleted {
            progress.tombstonesPreserved += 1
            return
        }

        let id = portable.id
        let optionalID: String? = id
        var matches: [Playlist] = []
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.syncID == optionalID })
        descriptor.fetchLimit = 2
        matches.append(contentsOf: try legacy.fetch(descriptor))
        if let uuid = UUID(uuidString: id) {
            var byID = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == uuid })
            byID.fetchLimit = 2
            matches.append(contentsOf: try legacy.fetch(byID))
        }
        if id == Playlist.defaultQueueSyncID {
            let title = Playlist.defaultQueueTitle
            var queue = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == title })
            queue.fetchLimit = 2
            matches.append(contentsOf: try legacy.fetch(queue))
        }
        var seen = Set<PersistentIdentifier>()
        matches = matches.filter { seen.insert($0.persistentModelID).inserted }
        guard matches.count == 1, let source = matches.first,
              source.storeSplitSyncID == id else {
            // An absent local row, duplicate identity, or unnormalized legacy
            // sync ID cannot establish whether this CloudKit row is stale.
            progress.unresolvedLineage += 1
            return
        }

        let portableFilter: SmartPlaylistFilter?
        if let raw = portable.smartFilterRawValue {
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SmartPlaylistFilter.self, from: data) else {
                progress.semanticConflicts += 1
                return
            }
            portableFilter = decoded
        } else {
            portableFilter = nil
        }
        if source.title == portable.title,
           source.symbolName == portable.symbolName,
           source.sortIndex == portable.sortIndex,
           source.kindRawValue == portable.kindRawValue,
           source.smartFilter == portableFilter,
           source.hidden == portable.isHidden,
           source.autoDownloadEnabled == portable.autoDownloadEnabled,
           source.autoDownloadEpisodeLimit == portable.autoDownloadEpisodeLimit,
           source.removesEpisodesPlayedElsewhere == portable.removesEpisodesPlayedElsewhere {
            progress.matching += 1
        } else {
            // Legacy playlists have no trustworthy edit timestamp. A difference
            // is a conflict, never permission to overwrite the destination.
            progress.semanticConflicts += 1
        }
    }

    private func failure(
        _ error: String,
        progress: StoreSplitPlaylistReconciliationProgress = .init()
    ) -> StoreSplitPlaylistReconciliationPage {
        .init(status: .failed, progress: progress, error: error)
    }
}
