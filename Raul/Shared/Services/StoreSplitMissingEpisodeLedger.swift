import CryptoKit
import Darwin
import Foundation
import SwiftData

/// A portable source record that could not be projected because its episode
/// was unavailable. Feed and record identities stay in the local cache only.
struct StoreSplitMissingEpisodeReference: Equatable, Sendable {
    let stream: StoreSplitUserStateStream
    let sourceRecordID: String
    let feedURL: String
    let episodeID: String
    let sourceUpdatedAt: Date
    let payloadDigest: String
    /// Changes whenever a newer source revision replaces this queued item.
    let generation: String

    init(stream: StoreSplitUserStateStream, sourceRecordID: String,
         feedURL: String, episodeID: String, sourceUpdatedAt: Date, payloadDigest: String,
         generation: String = "") {
        self.stream = stream
        self.sourceRecordID = sourceRecordID
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sourceUpdatedAt = sourceUpdatedAt
        self.payloadDigest = payloadDigest
        self.generation = generation
    }
}

/// Hash every portable field involved in projection, including metadata which
/// may change without changing the episode identity or timestamp.
enum StoreSplitMissingEpisodeFingerprint {
    private static func digest(_ values: [String]) -> String {
        let encoded = values.map { StableIdentityKey.make($0) }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func text(_ value: String?) -> String { value.map { "v:" + $0 } ?? "nil" }
    private static func date(_ value: Date?) -> String {
        value.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil"
    }
    private static func number(_ value: Double?) -> String { value.map { String($0.bitPattern) } ?? "nil" }
    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func episodeState(_ value: EpisodeStateSync) -> String {
        digest([value.id, value.feedURL, value.episodeID, number(value.playPosition),
                number(value.maxPlayPosition), number(value.duration), flag(value.isPlayed),
                flag(value.isArchived), flag(value.wasSkipped), date(value.completedAt),
                date(value.archivedAt), date(value.firstPlayedAt), date(value.lastPlayedAt),
                date(value.updatedAt), text(value.sourceDeviceID)])
    }

    static func bookmark(_ value: BookmarkSync) -> String {
        digest([value.id, value.feedURL, value.episodeID, number(value.time), text(value.title),
                text(value.note), date(value.createdAt), flag(value.isDeleted), date(value.deletedAt),
                date(value.updatedAt), text(value.sourceDeviceID)])
    }

    static func playlistEntry(_ value: PlaylistEntrySync) -> String {
        digest([value.id, value.playlistID, value.feedURL, value.episodeID, String(value.sortIndex),
                date(value.addedAt), flag(value.isDeleted), date(value.deletedAt), date(value.updatedAt),
                text(value.sourceDeviceID)])
    }

    static func queueEntry(_ value: QueueEntrySync) -> String {
        digest([value.id, value.feedURL, value.episodeID, String(value.sortIndex), date(value.addedAt),
                flag(value.isDeleted), date(value.deletedAt), date(value.updatedAt), text(value.sourceDeviceID)])
    }

    static func history(_ value: ListeningHistorySync) -> String {
        digest([value.id, value.feedURL, value.episodeID, text(value.podcastName), text(value.episodeTitle),
                value.sourceDeviceID, text(value.sourceDeviceName), text(value.deviceModel),
                date(value.startedAt), date(value.endedAt), number(value.startPosition),
                number(value.endPosition), number(value.listenedSeconds), number(value.silenceGapTimeSavedSeconds),
                number(value.playbackRateTimeSavedSeconds), flag(value.endedCleanly),
                flag(value.isLegacyMigrated), date(value.updatedAt)])
    }
}

enum StoreSplitMissingEpisodeLedgerError: Error, Equatable {
    case invalidReference
    case duplicateIdentity
    case conflictingRevision
    case batchTooLarge
    case coordinationUnavailable
    case coordinationBusy
}

/// A bounded, local-only retry ledger. A nonblocking App Group file lock
/// serializes ledger and scheduler-marker mutations across app processes. The
/// caller must acknowledge an item only after the target projection has saved.
enum StoreSplitMissingEpisodeLedger {
    static let maximumBatchSize = 100
    private static let lock = NSLock()
    private static let drainLock = NSLock()
    private static let lockName = "StoreSplitMissingEpisodeRetry.lock"
    private static let drainLockName = "StoreSplitMissingEpisodeRetry.drain.lock"
    private static let markerName = "StoreSplitMissingEpisodeRetry.pending"

    struct PendingStatus: Sendable, Equatable {
        let pending: Bool
        let earliestDue: Date?
    }

    private struct Coordination {
        let directory: URL
        let descriptor: Int32
    }

    /// Held across fetching, projecting and checkpointing a retry page. The
    /// separate ledger lock still permits new references to be enqueued.
    static func beginDrain() throws -> Int32 {
        guard drainLock.try() else { throw StoreSplitMissingEpisodeLedgerError.coordinationBusy }
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
        ) else {
            drainLock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable
        }
        let descriptor = open(directory.appendingPathComponent(drainLockName).path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            drainLock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            drainLock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationBusy
        }
        return descriptor
    }

    static func endDrain(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        drainLock.unlock()
    }

    private static func beginCoordination() throws -> Coordination {
        guard lock.try() else { throw StoreSplitMissingEpisodeLedgerError.coordinationBusy }
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
        ) else {
            lock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable
        }
        let descriptor = open(directory.appendingPathComponent(lockName).path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            lock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            lock.unlock()
            throw StoreSplitMissingEpisodeLedgerError.coordinationBusy
        }
        return Coordination(directory: directory, descriptor: descriptor)
    }

    private static func endCoordination(_ coordination: Coordination) {
        flock(coordination.descriptor, LOCK_UN)
        close(coordination.descriptor)
        lock.unlock()
    }

    private static func writeMarker(due: Date, directory: URL) throws {
        let url = directory.appendingPathComponent(markerName)
        try Data(String(due.timeIntervalSince1970).utf8).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // The atomic write renames a temporary file. Flush the directory entry
        // before the cache transaction can commit, so a crash cannot leave a
        // durable queue row without its scheduler marker.
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw StoreSplitMissingEpisodeLedgerError.coordinationUnavailable }
    }

    private static func refreshMarker(context: ModelContext, directory: URL) throws {
        var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(
            sortBy: [SortDescriptor(\CachedMissingEpisodeReference.nextAttemptAt),
                     SortDescriptor(\CachedMissingEpisodeReference.id)]
        )
        descriptor.fetchLimit = 1
        if let next = try context.fetch(descriptor).first {
            try writeMarker(due: next.nextAttemptAt, directory: directory)
        } else {
            let marker = directory.appendingPathComponent(markerName)
            do { try FileManager.default.removeItem(at: marker) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError { }
        }
    }

    /// Cheap scheduler hint. A damaged or unavailable marker is treated as
    /// pending so an admitted background pass can reconcile it from the cache.
    static func pendingStatus() -> PendingStatus {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
        ) else {
            return PendingStatus(pending: true, earliestDue: nil)
        }
        let descriptor = open(directory.appendingPathComponent(markerName).path, O_RDONLY)
        guard descriptor >= 0 else {
            return errno == ENOENT
                ? PendingStatus(pending: false, earliestDue: nil)
                : PendingStatus(pending: true, earliestDue: nil)
        }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 65)
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count > 0, count <= 64,
              let value = String(bytes: bytes.prefix(Int(count)), encoding: .utf8),
              let seconds = Double(value), seconds.isFinite else {
            return PendingStatus(pending: true, earliestDue: nil)
        }
        return PendingStatus(pending: true, earliestDue: Date(timeIntervalSince1970: seconds))
    }

    /// Repairs a false-positive marker after an interrupted enqueue. Run only
    /// after the cache has been opened in an admitted maintenance window.
    static func reconcilePendingStatus(cacheContainer: ModelContainer) throws {
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        try refreshMarker(context: ModelContext(cacheContainer), directory: coordination.directory)
    }

    static func contentProjectionPendingCount(cacheContainer: ModelContainer) throws -> Int {
        let context = ModelContext(cacheContainer)
        return try context.fetchCount(FetchDescriptor<CachedMissingEpisodeReference>(
            predicate: #Predicate { $0.contentProjectionPending }
        ))
    }

    private static let episodeStreams: Set<StoreSplitUserStateStream> = [
        .episodeState, .playlistEntries, .queueEntries, .bookmarks, .listeningHistory
    ]

    private static func key(stream: StoreSplitUserStateStream, sourceRecordID: String) -> String {
        let value = StableIdentityKey.make("missing-episode-v1", stream.rawValue, sourceRecordID)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Commits the entire bounded batch or none of it. Repeating an unchanged
    /// batch does not rewrite rows; a newer revision makes the item due again.
    static func enqueue(_ references: [StoreSplitMissingEpisodeReference],
                        cacheContainer: ModelContainer) throws {
        guard references.count <= maximumBatchSize else { throw StoreSplitMissingEpisodeLedgerError.batchTooLarge }
        guard !references.isEmpty else { return }
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        // This precedes the cache save. A crash can leave extra work scheduled,
        // but cannot leave a saved reference invisible to the scheduler.
        try writeMarker(due: .distantPast, directory: coordination.directory)
        let context = ModelContext(cacheContainer)
        context.autosaveEnabled = false
        do {
            for reference in references {
                guard episodeStreams.contains(reference.stream),
                      !reference.sourceRecordID.isEmpty,
                      !reference.feedURL.isEmpty,
                      !reference.episodeID.isEmpty, !reference.payloadDigest.isEmpty else {
                    throw StoreSplitMissingEpisodeLedgerError.invalidReference
                }
                let id = key(stream: reference.stream, sourceRecordID: reference.sourceRecordID)
                var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 2
                let rows = try context.fetch(descriptor)
                guard rows.count <= 1 else { throw StoreSplitMissingEpisodeLedgerError.duplicateIdentity }
                if let row = rows.first {
                    if reference.sourceUpdatedAt < row.sourceUpdatedAt { continue }
                    let samePayload = row.feedURL == reference.feedURL && row.episodeID == reference.episodeID
                        && row.payloadDigest == reference.payloadDigest
                    if reference.sourceUpdatedAt == row.sourceUpdatedAt {
                        guard samePayload else { throw StoreSplitMissingEpisodeLedgerError.conflictingRevision }
                        continue
                    }
                    row.feedURL = reference.feedURL
                    row.episodeID = reference.episodeID
                    row.sourceUpdatedAt = reference.sourceUpdatedAt
                    row.payloadDigest = reference.payloadDigest
                    row.generation = UUID().uuidString
                    row.nextAttemptAt = .distantPast
                    row.attemptCount = 0
                } else {
                    context.insert(CachedMissingEpisodeReference(
                        id: id, streamRawValue: reference.stream.rawValue,
                        sourceRecordID: reference.sourceRecordID, feedURL: reference.feedURL,
                        episodeID: reference.episodeID, sourceUpdatedAt: reference.sourceUpdatedAt,
                        payloadDigest: reference.payloadDigest,
                        generation: UUID().uuidString
                    ))
                }
            }
            if context.hasChanges { try context.save() }
            try refreshMarker(context: context, directory: coordination.directory)
        } catch {
            context.rollback()
            // The source cursor remains uncommitted on failure. Restore the
            // best known retry deadline when the existing queue is readable.
            try? refreshMarker(context: context, directory: coordination.directory)
            throw error
        }
    }

    /// Returns at most one page. Postponing unavailable items moves them behind
    /// other due references, so a permanently missing episode cannot starve the
    /// rest of the queue.
    static func duePage(cacheContainer: ModelContainer, limit: Int = 40,
                        now: Date = .now) throws -> [StoreSplitMissingEpisodeReference] {
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        let context = ModelContext(cacheContainer)
        var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(
            predicate: #Predicate { $0.nextAttemptAt <= now },
            sortBy: [SortDescriptor(\CachedMissingEpisodeReference.nextAttemptAt),
                     SortDescriptor(\CachedMissingEpisodeReference.id)]
        )
        descriptor.fetchLimit = max(1, min(limit, maximumBatchSize))
        return try context.fetch(descriptor).map { row in
            guard let stream = StoreSplitUserStateStream(rawValue: row.streamRawValue),
                  episodeStreams.contains(stream), !row.sourceRecordID.isEmpty,
                  !row.feedURL.isEmpty, !row.episodeID.isEmpty, !row.generation.isEmpty,
                  !row.payloadDigest.isEmpty,
                  row.id == key(stream: stream, sourceRecordID: row.sourceRecordID) else {
                throw StoreSplitMissingEpisodeLedgerError.invalidReference
            }
            return StoreSplitMissingEpisodeReference(
                stream: stream, sourceRecordID: row.sourceRecordID, feedURL: row.feedURL,
                episodeID: row.episodeID, sourceUpdatedAt: row.sourceUpdatedAt,
                payloadDigest: row.payloadDigest,
                generation: row.generation
            )
        }
    }

    /// Called only after the target store confirms its durable save. A newer
    /// enqueue changes the generation and therefore cannot be acknowledged by
    /// an older in-flight projection.
    @discardableResult
    static func acknowledge(_ reference: StoreSplitMissingEpisodeReference,
                            cacheContainer: ModelContainer) throws -> Bool {
        try mutate(reference, cacheContainer: cacheContainer) { row, context in
            context.delete(row)
        }
    }

    @discardableResult
    static func postpone(_ reference: StoreSplitMissingEpisodeReference,
                         cacheContainer: ModelContainer, until date: Date) throws -> Bool {
        try mutate(reference, cacheContainer: cacheContainer) { row, _ in
            if row.nextAttemptAt != date { row.nextAttemptAt = date }
        }
    }

    /// Clears only revisions which the ordinary importer has already saved.
    /// A concurrently queued newer revision remains pending.
    static func acknowledgeProjected(_ references: [StoreSplitMissingEpisodeReference],
                                     cacheContainer: ModelContainer) throws {
        guard references.count <= maximumBatchSize else { throw StoreSplitMissingEpisodeLedgerError.batchTooLarge }
        guard !references.isEmpty else { return }
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        let context = ModelContext(cacheContainer)
        context.autosaveEnabled = false
        let expected = Dictionary(grouping: references) {
            key(stream: $0.stream, sourceRecordID: $0.sourceRecordID)
        }
        let ids = Array(expected.keys)
        var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        descriptor.fetchLimit = ids.count * 2 + 1
        do {
            let rows = try context.fetch(descriptor)
            var seen = Set<String>()
            for row in rows {
                guard seen.insert(row.id).inserted else { throw StoreSplitMissingEpisodeLedgerError.duplicateIdentity }
                guard let candidates = expected[row.id], candidates.count == 1,
                      let reference = candidates.first else { continue }
                guard row.streamRawValue == reference.stream.rawValue,
                      row.sourceRecordID == reference.sourceRecordID,
                      row.feedURL == reference.feedURL, row.episodeID == reference.episodeID,
                      row.sourceUpdatedAt == reference.sourceUpdatedAt,
                      row.payloadDigest == reference.payloadDigest else { continue }
                context.delete(row)
            }
            if context.hasChanges { try context.save() }
            try refreshMarker(context: context, directory: coordination.directory)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Completes one worker page in one local transaction after the target
    /// transaction has saved. Stale generations are left for the next pass.
    static func finishPage(
        projected: [StoreSplitMissingEpisodeReference],
        postponed: [StoreSplitMissingEpisodeReference],
        superseded: [(old: StoreSplitMissingEpisodeReference, new: StoreSplitMissingEpisodeReference)],
        contentPending: [StoreSplitMissingEpisodeReference] = [],
        now: Date,
        cacheContainer: ModelContainer
    ) throws -> (acknowledged: Int, postponed: Int) {
        let all = projected + postponed + superseded.map(\.old)
        guard all.count <= maximumBatchSize else { throw StoreSplitMissingEpisodeLedgerError.batchTooLarge }
        guard !all.isEmpty else { return (0, 0) }
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        let context = ModelContext(cacheContainer)
        context.autosaveEnabled = false
        var acknowledged = 0
        var deferred = 0
        do {
            for reference in all {
                let id = key(stream: reference.stream, sourceRecordID: reference.sourceRecordID)
                var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 2
                let rows = try context.fetch(descriptor)
                guard rows.count <= 1 else { throw StoreSplitMissingEpisodeLedgerError.duplicateIdentity }
                guard let row = rows.first, row.generation == reference.generation,
                      row.sourceUpdatedAt == reference.sourceUpdatedAt,
                      row.feedURL == reference.feedURL, row.episodeID == reference.episodeID,
                      row.payloadDigest == reference.payloadDigest,
                      row.streamRawValue == reference.stream.rawValue,
                      row.sourceRecordID == reference.sourceRecordID else { continue }
                if projected.contains(reference) {
                    context.delete(row)
                    acknowledged += 1
                } else if let replacement = superseded.first(where: { $0.old == reference })?.new {
                    guard replacement.stream == reference.stream,
                          replacement.sourceRecordID == reference.sourceRecordID,
                          replacement.sourceUpdatedAt > reference.sourceUpdatedAt,
                          !replacement.feedURL.isEmpty, !replacement.episodeID.isEmpty,
                          !replacement.payloadDigest.isEmpty else {
                        throw StoreSplitMissingEpisodeLedgerError.invalidReference
                    }
                    row.feedURL = replacement.feedURL
                    row.episodeID = replacement.episodeID
                    row.sourceUpdatedAt = replacement.sourceUpdatedAt
                    row.payloadDigest = replacement.payloadDigest
                    row.generation = UUID().uuidString
                    row.nextAttemptAt = .distantPast
                    row.attemptCount = 0
                    deferred += 1
                } else {
                    // Persist backoff with each row, capped at one day. A new
                    // source revision resets it to due immediately.
                    let exponent = min(max(row.attemptCount, 0), 7)
                    let delay = min(24.0 * 60 * 60, 15.0 * 60 * pow(2.0, Double(exponent)))
                    row.nextAttemptAt = now.addingTimeInterval(delay)
                    row.attemptCount = min(max(row.attemptCount, 0) + 1, 8)
                    if contentPending.contains(reference) { row.contentProjectionPending = true }
                    deferred += 1
                }
            }
            if context.hasChanges { try context.save() }
            try refreshMarker(context: context, directory: coordination.directory)
            return (acknowledged, deferred)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func mutate(_ reference: StoreSplitMissingEpisodeReference,
                               cacheContainer: ModelContainer,
                               action: (CachedMissingEpisodeReference, ModelContext) -> Void) throws -> Bool {
        let coordination = try beginCoordination()
        defer { endCoordination(coordination) }
        let context = ModelContext(cacheContainer)
        context.autosaveEnabled = false
        let id = key(stream: reference.stream, sourceRecordID: reference.sourceRecordID)
        var descriptor = FetchDescriptor<CachedMissingEpisodeReference>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        do {
            let rows = try context.fetch(descriptor)
            guard rows.count <= 1 else { throw StoreSplitMissingEpisodeLedgerError.duplicateIdentity }
            guard let row = rows.first, row.generation == reference.generation,
                  row.sourceUpdatedAt == reference.sourceUpdatedAt,
                  row.feedURL == reference.feedURL, row.episodeID == reference.episodeID,
                  row.payloadDigest == reference.payloadDigest,
                  row.streamRawValue == reference.stream.rawValue,
                  row.sourceRecordID == reference.sourceRecordID else { return false }
            action(row, context)
            if context.hasChanges { try context.save() }
            try refreshMarker(context: context, directory: coordination.directory)
            return true
        } catch {
            context.rollback()
            throw error
        }
    }
}
