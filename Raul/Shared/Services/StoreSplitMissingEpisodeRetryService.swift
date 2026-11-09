import Foundation
import SwiftData

struct StoreSplitMissingEpisodeRetryResult: Sendable {
    var examined = 0
    var applied = 0
    var postponed = 0
    var failed = 0
    var cancelled = false
    var cacheEpisodesMaterialized = 0
    var cacheContentProjectionPending = 0
    var projectionBlocked = false
}

/// Compare the last-writer-wins fields. Maximum playback position is merged
/// monotonically and is therefore not a same-timestamp conflict.
enum StoreSplitEpisodeStateComparison {
    static func agrees(_ state: EpisodeStateSync, with local: EpisodeMetaData) -> Bool {
        guard (local.playPosition ?? 0) == max(0, state.playPosition),
              local.lastPlayed == state.lastPlayedAt,
              local.firstListenDate == state.firstPlayedAt,
              local.completionDate == state.completedAt,
              local.archivedAt == state.archivedAt,
              local.wasSkipped == state.wasSkipped,
              (local.isArchived ?? false) == state.isArchived,
              (local.isHistory ?? false) == state.isPlayed else { return false }
        if state.isArchived { return local.isInbox == false && local.status == .archived }
        if state.isPlayed { return local.isInbox == false && local.status == .history }
        return local.status != .archived && local.status != .history
    }
}

/// Keeps a bounded page pending until a cross-writer consistency mechanism is
/// available. No absence is a tombstone and this service cannot project state.
actor StoreSplitMissingEpisodeRetryService {
    private let library: ModelContainer

    private init(library: ModelContainer) {
        self.library = library
    }

    nonisolated static func runPage(
        libraryContainer: ModelContainer,
        limit: Int = 40,
        now: Date = .now,
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) async -> StoreSplitMissingEpisodeRetryResult {
        let worker = StoreSplitMissingEpisodeRetryService(library: libraryContainer)
        return await worker.runPage(limit: limit, now: now, shouldContinue: shouldContinue)
    }

    private func runPage(limit: Int, now: Date,
                         shouldContinue: @Sendable () -> Bool) -> StoreSplitMissingEpisodeRetryResult {
        var result = StoreSplitMissingEpisodeRetryResult()
        guard shouldContinue() else { result.cancelled = true; return result }
        let lease: Int32
        do { lease = try StoreSplitMissingEpisodeLedger.beginDrain() }
        catch { result.failed = 1; return result }
        defer { StoreSplitMissingEpisodeLedger.endDrain(lease) }
        let page: [StoreSplitMissingEpisodeReference]
        do {
            page = try StoreSplitMissingEpisodeLedger.duePage(libraryContainer: library, limit: limit, now: now)
        } catch {
            result.failed = 1
            return result
        }
        if page.isEmpty {
            do { try StoreSplitMissingEpisodeLedger.reconcilePendingStatus(libraryContainer: library) }
            catch { result.failed = 1 }
            return result
        }
        // The drain lease only serializes retry workers. RSS, playback,
        // import, and CloudKit writers do not share an exclusive generation or
        // fence, so even an existing episode or bookmark could change between
        // comparison and save. Do not project or acknowledge any reference.
        // Callers must not schedule this blocked worker in a wake loop.
        guard shouldContinue() else { result.cancelled = true; return result }
        result.projectionBlocked = true
        do {
            let finished = try StoreSplitMissingEpisodeLedger.finishPage(
                projected: [], postponed: page, superseded: [], contentPending: [],
                now: now, libraryContainer: library
            )
            result.examined = page.count
            result.postponed = finished.postponed
        } catch {
            result.failed = 1
        }
        return result
    }
}
