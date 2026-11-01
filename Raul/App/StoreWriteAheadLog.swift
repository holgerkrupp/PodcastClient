import Foundation
import SQLite3
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the library stores' `-wal` files from staying large.
///
/// SQLite reuses a write-ahead log but never shrinks it on its own, and a long
/// read that overlaps with writes makes it grow. A device reached 831 MB, and the
/// next launch has to deal with whatever is still unmerged before the library
/// opens, so the launch screen sat there for that long.
///
/// This only moves committed pages into the database file, using SQLite's own
/// locking, so it changes no rows. `UserState.sqlite` is left out: CloudKit
/// manages that store and its log has not been a problem.
enum StoreWriteAheadLog {
    enum Outcome: Equatable {
        case belowThreshold
        case trimmed
        /// A reader or writer was in the way. Nothing is lost; the next pass retries.
        case busy
        case failed
    }

    static let trimThresholdBytes: Int64 = 64 * 1_024 * 1_024
    static let foregroundCheckInterval: Duration = .seconds(5 * 60)

    static func sizeInBytes(storeURL: URL) -> Int64 {
        let path = storeURL.path + "-wal"
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The passive pass takes no lock that blocks other connections, however long
    /// it runs. Only once it has merged everything does the truncate run, which is
    /// then quick, with a short timeout so a main-thread save never waits on it.
    static func trim(storeURL: URL, thresholdBytes: Int64 = trimThresholdBytes) -> Outcome {
        guard sizeInBytes(storeURL: storeURL) >= thresholdBytes else { return .belowThreshold }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return .failed
        }
        defer { sqlite3_close(handle) }

        // A new connection attaches to the log on its first read. Until then a
        // checkpoint does nothing and still returns SQLITE_OK.
        guard sqlite3_exec(handle, "SELECT COUNT(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            return .failed
        }

        var logFrames: Int32 = 0
        var mergedFrames: Int32 = 0
        let passive = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, &logFrames, &mergedFrames)
        guard passive == SQLITE_OK || passive == SQLITE_BUSY else { return .failed }
        guard passive == SQLITE_OK, logFrames == mergedFrames else { return .busy }

        sqlite3_busy_timeout(handle, 100)
        switch sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &mergedFrames) {
        case SQLITE_OK: return .trimmed
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        default: return .failed
        }
    }

    /// iOS terminates an app suspended while holding a lock on an App Group file,
    /// so a pass that is under way when the app leaves gets time to finish.
    @MainActor
    static func trimLibraryStores() async {
        let stores = [ModelContainerManager.sharedStoreURL, ModelContainerManager.cacheStoreURL].compactMap { $0 }
#if canImport(UIKit)
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TrimStoreWriteAheadLog") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
#endif
        await Task.detached(priority: .utility) {
            for store in stores {
                let megabytes = sizeInBytes(storeURL: store) / (1_024 * 1_024)
                let outcome = trim(storeURL: store)
                guard outcome != .belowThreshold else { continue }
                CrashBreadcrumbs.shared.record(
                    "store_write_ahead_log_trim",
                    details: "store=\(store.lastPathComponent),megabytes=\(megabytes),outcome=\(outcome)"
                )
            }
        }.value
    }
}
