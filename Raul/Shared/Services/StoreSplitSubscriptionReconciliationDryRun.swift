import Foundation
import SwiftData

/// Counts are evidence from one destination traversal, not evidence of source
/// completeness or CloudKit convergence. Unmatched local identity is unresolved.
struct StoreSplitSubscriptionReconciliationProgress: Codable, Equatable, Sendable {
    var lastID: String?
    var scanned = 0
    var matching = 0
    var newerDestination = 0
    var semanticConflicts = 0
    var unresolvedLineage = 0
    var tombstonesPreserved = 0
    var inconsistentTombstones = 0
    var duplicateIdentities = 0
    var traversalComplete = false

    var isValid: Bool {
        guard scanned >= 0, (scanned == 0) == (lastID == nil) else { return false }
        var unclassified = scanned
        for count in [matching, newerDestination, semanticConflicts, unresolvedLineage,
                      tombstonesPreserved, inconsistentTombstones, duplicateIdentities] {
            guard count >= 0, count <= unclassified else { return false }
            unclassified -= count
        }
        return unclassified == 0
    }
}

struct StoreSplitSubscriptionReconciliationPage: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case advanced, traversalCompleted, blockedDuplicateIdentity, cancelled, failed
    }
    var status: Status
    var progress: StoreSplitSubscriptionReconciliationProgress
    /// Stable failure code without feed identity or credentials.
    var error: String? = nil
}

/// Performs bounded read-only subscription comparisons. The cursor is stored in
/// PodcastCache; callers must restart after imports or source changes. A finished
/// traversal never authorizes deletion or proves cross-device convergence.
actor StoreSplitSubscriptionReconciliationDryRun {
    static var checkpointID: String {
        "storeSplit.reconciliation.v\(StoreSplitMigrationService.migrationVersion).subscriptions.r1"
    }
    static let checkpointPhase = "reconciliation_subscription_dry_run"
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

    nonisolated static func runPage(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        pageSize: Int = 50,
        restart: Bool = false,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) async -> StoreSplitSubscriptionReconciliationPage {
        let worker = StoreSplitSubscriptionReconciliationDryRun(
            legacy: legacyContainer, destination: userStateContainer, cache: cacheContainer
        )
        return await worker.runPage(
            pageSize: max(1, min(pageSize, maximumPageSize)), restart: restart,
            shouldContinue: shouldContinue
        )
    }

    private func runPage(
        pageSize: Int,
        restart: Bool,
        shouldContinue: @Sendable () -> Bool
    ) -> StoreSplitSubscriptionReconciliationPage {
        var checkpoint: StoreSplitMigrationCheckpoint?
        do {
            let id = Self.checkpointID
            var descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 2
            let checkpoints = try cache.fetch(descriptor)
            guard checkpoints.count <= 1 else { return failure("duplicate_checkpoint") }
            checkpoint = checkpoints.first
        } catch {
            return failure("checkpoint_fetch_failed")
        }

        var progress: StoreSplitSubscriptionReconciliationProgress
        if restart || checkpoint == nil {
            progress = .init()
        } else if let raw = checkpoint?.cursor,
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(StoreSplitSubscriptionReconciliationProgress.self, from: data),
                  decoded.isValid {
            progress = decoded
        } else {
            return failure("checkpoint_invalid")
        }
        let initial = progress
        guard shouldContinue() else { return .init(status: .cancelled, progress: initial) }

        if restart {
            let reset = saveProgress(progress, checkpoint: checkpoint, restart: true, status: .advanced)
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
                } catch { return failure("checkpoint_fetch_failed") }
            }
            guard shouldContinue() else { return .init(status: .cancelled, progress: initial) }
        }
        if progress.traversalComplete { return .init(status: .traversalCompleted, progress: progress) }

        var descriptor: FetchDescriptor<SubscriptionSync>
        if let lastID = progress.lastID {
            descriptor = FetchDescriptor(
                predicate: #Predicate<SubscriptionSync> { $0.id > lastID },
                sortBy: [SortDescriptor(\SubscriptionSync.id)]
            )
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\SubscriptionSync.id)])
        }
        descriptor.fetchLimit = pageSize + 1
        let fetched: [SubscriptionSync]
        do { fetched = try destination.fetch(descriptor) }
        catch { return failure("destination_fetch_failed", progress: initial) }
        guard shouldContinue() else { return .init(status: .cancelled, progress: initial) }

        var page = Array(fetched.prefix(pageSize))
        if fetched.count > pageSize, let last = page.last, last.id == fetched[pageSize].id {
            let boundaryID = last.id
            while page.last?.id == boundaryID { page.removeLast() }
            if page.isEmpty {
                return saveProgress(
                    initial, checkpoint: checkpoint, restart: false,
                    status: .blockedDuplicateIdentity, error: "duplicate_identity_exceeds_page_budget"
                )
            }
        }

        var index = 0
        while index < page.count {
            guard shouldContinue() else { return .init(status: .cancelled, progress: initial) }
            let id = page[index].id
            var end = index + 1
            while end < page.count, page[end].id == id { end += 1 }
            progress.scanned += end - index
            if end - index > 1 || id.isEmpty {
                progress.duplicateIdentities += end - index
            } else {
                do { try classify(page[index], progress: &progress) }
                catch { return failure("source_fetch_failed", progress: initial) }
            }
            progress.lastID = id
            index = end
        }
        guard shouldContinue() else { return .init(status: .cancelled, progress: initial) }
        progress.traversalComplete = fetched.count <= pageSize
        return saveProgress(
            progress, checkpoint: checkpoint, restart: false,
            status: progress.traversalComplete ? .traversalCompleted : .advanced,
            previousProgress: initial
        )
    }

    private func saveProgress(
        _ progress: StoreSplitSubscriptionReconciliationProgress,
        checkpoint existing: StoreSplitMigrationCheckpoint?,
        restart: Bool,
        status: StoreSplitSubscriptionReconciliationPage.Status,
        error: String? = nil,
        previousProgress: StoreSplitSubscriptionReconciliationProgress? = nil
    ) -> StoreSplitSubscriptionReconciliationPage {
        do {
            let checkpoint = existing ?? StoreSplitMigrationCheckpoint(
                id: Self.checkpointID, migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: Self.checkpointPhase, startedAt: .now
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
        _ portable: SubscriptionSync,
        progress: inout StoreSplitSubscriptionReconciliationProgress
    ) throws {
        // Check the complete normalized identity; URL syntax or a partial title
        // match is not proof that two publisher records are the same feed.
        guard let feed = URL(string: portable.feedURL),
              ["http", "https"].contains(feed.scheme?.lowercased() ?? ""),
              PodcastFeedIdentity.normalizedFeedURLString(feed) == portable.id else {
            progress.unresolvedLineage += 1
            return
        }
        if portable.isSubscribed == (portable.unsubscribedAt != nil) {
            progress.inconsistentTombstones += 1
            return
        }
        if !portable.isSubscribed {
            progress.tombstonesPreserved += 1
            return
        }

        // Exact URL lookup is deliberately conservative. A legacy URL with a
        // different spelling may normalize to this identity; if it cannot be
        // found via the bounded indexed query, classify lineage as unresolved.
        let candidate: URL? = feed
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feed == candidate })
        descriptor.fetchLimit = 2
        let candidates = try legacy.fetch(descriptor).filter {
            $0.feed.map(PodcastFeedIdentity.normalizedFeedURLString) == portable.id
        }
        guard candidates.count == 1, let source = candidates.first else {
            progress.unresolvedLineage += 1
            return
        }
        let metadata = source.metaData
        let sourceSubscribedAt = metadata?.subscriptionDate ?? .distantPast
        let same = (metadata?.isSubscribed != false) == portable.isSubscribed
            && sourceSubscribedAt == portable.subscribedAt
            && metadata?.accessProfileID == portable.accessProfileID
            && metadata?.accessKindRawValue == portable.accessKindRawValue
            && metadata?.accessProviderID == portable.accessProviderID
        if same {
            progress.matching += 1
        } else if let date = metadata?.subscriptionDate, portable.updatedAt > date {
            // The source has only a subscription date, not an authoritative
            // edit time. This label never authorizes a write or cleanup.
            progress.newerDestination += 1
        } else {
            progress.semanticConflicts += 1
        }
    }

    private func failure(
        _ error: String,
        progress: StoreSplitSubscriptionReconciliationProgress = .init()
    ) -> StoreSplitSubscriptionReconciliationPage {
        .init(status: .failed, progress: progress, error: error)
    }
}
