import Darwin
import CryptoKit
import Foundation
import SwiftData

/// Durable, device-local retry of portable writes that could not be committed.
/// Files have unique names, so acknowledging one attempt cannot erase a newer
/// write. The lock is held only for bounded file operations, never across an
/// await or a SwiftData transaction.
actor StoreSplitPortableWriteOutbox {
    enum Operation: Codable, Sendable {
        case episodeState(StoreSplitEpisodeStateSnapshot, Date)
        case bookmarkUpsert(StoreSplitBookmarkSnapshot, Date)
        /// Publish only after the durable legacy library no longer contains
        /// the bookmark. A failed or interrupted local delete leaves it intact.
        case bookmarkDeletionAfterLocalCommit(StoreSplitBookmarkSnapshot, Date)
        case listeningHistory(StoreSplitListeningHistorySnapshot)
    }

    struct DrainResult: Sendable {
        var attempted = 0
        var succeeded = 0
        var failed = 0
        var hasPending = false
        var failureOperationKinds: [String] = []
        var failureCategories: [String] = []
    }

    struct QueueDiagnostics: Sendable {
        let count: Int
        let capacity: Int
        let oldestAge: TimeInterval?
    }

    enum OutboxError: Error {
        case storageUnavailable
        case busy
        case full
        case invalidEntry
        case localDeletionPending
    }

    private struct Entry: Codable {
        let id: UUID
        let operation: Operation
        var attempts: Int
        var nextAttemptAt: Date
    }

    static let shared = StoreSplitPortableWriteOutbox()
    private static let capacity = 512
    private static let pressureThreshold = 448
    private static let maximumBatch = 32
    private static let maximumEntryBytes = 256 * 1024
    private let directoryOverride: URL?

    init(directoryURL: URL? = nil) {
        directoryOverride = directoryURL
    }

    /// Bounded launch check recovers an enqueue even if the process died after
    /// the atomic file write and before it could schedule background work.
    /// A crash during replacement can temporarily leave 513 files.
    nonisolated static func hasPendingOnDisk() -> Bool {
        earliestDueOnDisk() != nil
    }

    /// Nil means no queued work; inaccessible or malformed state fails closed
    /// with an immediate date. Due times are in filenames, so this bounded scan
    /// does not read or decode user payloads.
    nonisolated static func earliestDueOnDisk(directoryURL: URL? = nil) -> Date? {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            guard let group = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
            ) else { return .distantPast }
            directory = group.appendingPathComponent("Library/Application Support/PortableWriteOutbox", isDirectory: true)
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: directory.path)
        } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                return nil
            }
            return .distantPast
        }
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { return .distantPast }
        var earliest: Date?
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            count += 1
            guard count <= capacity + 1 else { return .distantPast }
            let prefix = url.lastPathComponent.prefix(20)
            guard prefix.count == 20, let millis = Int64(prefix) else { return .distantPast }
            let due = Date(timeIntervalSince1970: Double(millis) / 1_000)
            earliest = min(earliest ?? due, due)
        }
        return enumerationFailed ? .distantPast : earliest
    }

    private func directory() throws -> URL {
        if let directoryOverride { return directoryOverride }
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ModelContainerManager.appGroupID
        ) else { throw OutboxError.storageUnavailable }
        return group.appendingPathComponent("Library/Application Support/PortableWriteOutbox", isDirectory: true)
    }

    private func prepareDirectory() throws -> URL {
        let directory = try directory()
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
#else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#endif
        return directory
    }

    private func withFileLock<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = try prepareDirectory()
        let lockURL = directory.appendingPathComponent(".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OutboxError.storageUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw OutboxError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try body(directory)
    }

    private func entryURLs(in directory: URL) throws -> [URL] {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw OutboxError.storageUnavailable }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            urls.append(url)
            // One extra file may survive a crash during a durable replacement.
            guard urls.count <= Self.capacity + 1 else { throw OutboxError.full }
        }
        if enumerationFailed { throw OutboxError.storageUnavailable }
        return urls
    }

    /// Returns only after the retry record has been atomically written.
    func enqueue(_ operation: Operation, now: Date = .now) async throws {
        var committed = false
        for attempt in 0..<20 {
            do {
                try enqueueOnce(operation, now: now)
                committed = true
                break
            } catch OutboxError.busy where attempt < 19 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard committed else { throw OutboxError.busy }
        if let count = try? queueCount(), count >= Self.pressureThreshold {
            CrashBreadcrumbs.shared.record(
                "store_split_portable_outbox_pressure",
                details: "queue=\(count)/\(Self.capacity)"
            )
        }
#if canImport(UIKit)
        if directoryOverride == nil {
            Task { @MainActor in
                AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded()
            }
        }
#endif
    }

    private func enqueueOnce(_ operation: Operation, now: Date) throws {
        try withFileLock { directory in
            let prior = try entryURLs(in: directory)
            let older: [URL]
            if let (key, timestamp) = episodeCoalescingKey(operation) {
                older = prior.filter { url in
                    let parts = url.lastPathComponent.split(separator: "-")
                    return parts.count >= 4 && parts[1] == Substring(key)
                        && (Int64(parts[2]).map { $0 < timestamp } ?? false)
                }
            } else {
                older = []
            }
            // Never remove the old payload before the replacement is durable.
            // If a crash leaves both files, drain can recover the extra entry.
            guard prior.count < Self.capacity || (prior.count == Self.capacity && !older.isEmpty)
            else { throw OutboxError.full }
            let entry = Entry(id: UUID(), operation: operation, attempts: 0, nextAttemptAt: now)
            _ = try writeDurably(entry, in: directory)
            // Playback can produce repeated failures for the same episode.
            // Retire only strictly older queued position snapshots after the
            // newer file is durable. Other operation kinds stay independent.
            for url in older {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func episodeCoalescingKey(_ operation: Operation) -> (String, Int64)? {
        guard case let .episodeState(snapshot, date) = operation else { return nil }
        let digest = SHA256.hash(data: Data(snapshot.identity.key.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let timestamp = Int64(max(0, date.timeIntervalSince1970 * 1_000))
        return (key, timestamp)
    }

    private func writeDurably(_ entry: Entry, in directory: URL) throws -> URL {
        let data = try JSONEncoder().encode(entry)
        guard data.count <= Self.maximumEntryBytes else { throw OutboxError.invalidEntry }
        let millis = Int64(max(0, entry.nextAttemptAt.timeIntervalSince1970 * 1_000))
        let (key, timestamp) = episodeCoalescingKey(entry.operation) ?? ("other", 0)
        let name = String(format: "%020lld-%@-%020lld-%@.json", millis, key, timestamp, entry.id.uuidString)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw OutboxError.storageUnavailable }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw OutboxError.storageUnavailable }
        return url
    }

    func hasPending() throws -> Bool {
        try withFileLock { try !entryURLs(in: $0).isEmpty }
    }

    func queueCount() throws -> Int {
        try withFileLock { try entryURLs(in: $0).count }
    }

    func queueDiagnostics(now: Date = .now) throws -> QueueDiagnostics {
        try withFileLock { directory in
            let urls = try entryURLs(in: directory)
            let oldestOperation = urls.compactMap { url -> Date? in
                guard let data = try? Data(contentsOf: url),
                      data.count <= Self.maximumEntryBytes,
                      let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
                return Self.operationDate(entry.operation)
            }.min()
            return QueueDiagnostics(
                count: urls.count, capacity: Self.capacity,
                oldestAge: oldestOperation.map { max(0, now.timeIntervalSince($0)) }
            )
        }
    }

    private static func operationDate(_ operation: Operation) -> Date {
        switch operation {
        case let .episodeState(_, date), let .bookmarkUpsert(_, date),
             let .bookmarkDeletionAfterLocalCommit(_, date): date
        case let .listeningHistory(snapshot): snapshot.endedAt
        }
    }

    /// Caller supplies an admitted maintenance window and stops it on export,
    /// suspension or expiration. Each invocation attempts at most 32 rows.
    func drain(
        userStateContainer: ModelContainer, legacyContainer: ModelContainer? = nil,
        limit: Int = 32, now: Date = .now,
        shouldContinue: @escaping @Sendable () -> Bool = { Task.isCancelled == false }
    ) async throws -> DrainResult {
        guard shouldContinue() else { return DrainResult(hasPending: true) }
        // A separate nonblocking lease serializes drainers across processes.
        // Enqueues use a different short lock and remain possible while a
        // writer awaits its transaction. Cancellation releases this lease.
        let directory = try prepareDirectory()
        let drainFD = open(directory.appendingPathComponent(".drain.lock").path,
                           O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard drainFD >= 0 else { throw OutboxError.storageUnavailable }
        defer { close(drainFD) }
        guard flock(drainFD, LOCK_EX | LOCK_NB) == 0 else { throw OutboxError.busy }
        defer { flock(drainFD, LOCK_UN) }
        var invalidEntries = 0
        let due: [(URL, Entry)] = try withFileLock { directory in
            let ordered = try entryURLs(in: directory).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var selected: [(URL, Entry)] = []
            for url in ordered {
                guard selected.count < max(0, min(limit, Self.maximumBatch)) else { break }
                let prefix = url.lastPathComponent.prefix(20)
                guard prefix.count == 20, let dueMillis = Int64(prefix) else {
                    invalidEntries += 1
                    continue
                }
                guard Date(timeIntervalSince1970: Double(dueMillis) / 1_000) <= now else { break }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard let size, size <= Self.maximumEntryBytes else { throw OutboxError.invalidEntry }
                    let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
                    if entry.nextAttemptAt <= now { selected.append((url, entry)) }
                }
                catch {
                    invalidEntries += 1
                    // Preserve the damaged bytes but postpone another attempt,
                    // so a corrupt payload does not wake every background grant.
                    let retryMillis = Int64(max(0, now.addingTimeInterval(6 * 3_600).timeIntervalSince1970 * 1_000))
                    let postponedName = String(format: "%020lld", retryMillis) + String(url.lastPathComponent.dropFirst(20))
                    let postponed = directory.appendingPathComponent(postponedName)
                    if postponed != url { try? FileManager.default.moveItem(at: url, to: postponed) }
                }
            }
            return selected
        }
        var result = DrainResult()
        result.failed = invalidEntries
        if invalidEntries > 0 {
            result.failureOperationKinds = Array(repeating: "unknown", count: min(invalidEntries, 32))
            result.failureCategories = Array(repeating: "outbox_invalid_entry", count: min(invalidEntries, 32))
        }
        for (url, original) in due {
            guard shouldContinue() else { result.hasPending = true; return result }
            result.attempted += 1
            do {
                switch original.operation {
                case let .episodeState(snapshot, date):
                    let io = StoreSplitEpisodeStateWriterIO(save: { context in
                        guard shouldContinue() else { throw CancellationError() }
                        try context.save()
                    })
                    _ = try await StoreSplitEpisodeStateSyncWriter(modelContainer: userStateContainer)
                        .upsert(snapshot, at: date, io: io)
                case let .bookmarkUpsert(snapshot, date):
                    let io = StoreSplitBookmarkWriterIO(save: { context in
                        guard shouldContinue() else { throw CancellationError() }
                        try context.save()
                    })
                    try await StoreSplitBookmarkSyncWriter(modelContainer: userStateContainer)
                        .upsert(snapshot, at: date, io: io)
                case let .bookmarkDeletionAfterLocalCommit(snapshot, date):
                    guard let legacyContainer, let uuid = UUID(uuidString: snapshot.id) else {
                        throw OutboxError.localDeletionPending
                    }
                    let local = ModelContext(legacyContainer)
                    let optionalUUID: UUID? = uuid
                    var descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.uuid == optionalUUID })
                    descriptor.fetchLimit = 1
                    guard try local.fetch(descriptor).isEmpty else { throw OutboxError.localDeletionPending }
                    guard shouldContinue() else { throw CancellationError() }
                    let io = StoreSplitBookmarkWriterIO(save: { context in
                        guard shouldContinue() else { throw CancellationError() }
                        try context.save()
                    })
                    try await StoreSplitBookmarkSyncWriter(modelContainer: userStateContainer)
                        .tombstone(snapshot, at: date, io: io)
                case let .listeningHistory(snapshot):
                    let io = StoreSplitListeningHistoryWriterIO(save: { context in
                        guard shouldContinue() else { throw CancellationError() }
                        try context.save()
                    })
                    try await StoreSplitListeningHistorySyncWriter(modelContainer: userStateContainer)
                        .upsert(snapshot, io: io)
                }
                guard shouldContinue() else { result.hasPending = true; return result }
                try withFileLock { _ in
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                result.succeeded += 1
            } catch {
                result.failed += 1
                result.failureOperationKinds.append(Self.operationKind(original.operation))
                result.failureCategories.append(Self.errorCategory(error))
                guard shouldContinue() else { result.hasPending = true; return result }
                var retry = original
                retry.attempts = min(original.attempts + 1, 10)
                retry.nextAttemptAt = now.addingTimeInterval(min(30 * pow(2, Double(retry.attempts - 1)), 3_600))
                // Rename the existing intent first. A crash before updating its
                // payload keeps the original operation at the later due time.
                // No extra queue slot is needed, even after a replacement crash.
                try? withFileLock { directory in
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    let retryMillis = Int64(max(0, retry.nextAttemptAt.timeIntervalSince1970 * 1_000))
                    let name = String(format: "%020lld", retryMillis) + String(url.lastPathComponent.dropFirst(20))
                    let postponed = directory.appendingPathComponent(name)
                    if postponed != url {
                        try FileManager.default.moveItem(at: url, to: postponed)
                        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
                        guard directoryFD >= 0 else { throw OutboxError.storageUnavailable }
                        defer { close(directoryFD) }
                        guard fsync(directoryFD) == 0 else { throw OutboxError.storageUnavailable }
                    }
                    _ = try writeDurably(retry, in: directory)
                }
            }
        }
        guard shouldContinue() else { result.hasPending = true; return result }
        result.hasPending = try withFileLock { try !entryURLs(in: $0).isEmpty }
        return result
    }

    private static func operationKind(_ operation: Operation) -> String {
        switch operation {
        case .episodeState: "episode_state"
        case .bookmarkUpsert: "bookmark_upsert"
        case .bookmarkDeletionAfterLocalCommit: "bookmark_deletion"
        case .listeningHistory: "listening_history"
        }
    }

    private static func errorCategory(_ error: Error) -> String {
        if let error = error as? OutboxError {
            return switch error {
            case .storageUnavailable: "outbox_storage_unavailable"
            case .busy: "outbox_lock_busy"
            case .full: "outbox_capacity_reached"
            case .invalidEntry: "outbox_invalid_entry"
            case .localDeletionPending: "bookmark_local_delete_unconfirmed"
            }
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain { return "cocoa_\(error.code)" }
        if error.domain == NSPOSIXErrorDomain { return "posix_\(error.code)" }
        return "other_\(error.code)"
    }
}
