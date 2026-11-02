import Foundation
import SQLite3
#if canImport(UIKit)
import UIKit
#endif

/// Times the store opens at launch. The event timeline only covers the last five
/// minutes, so the latest result is kept for a report taken any time later.
struct StoreLaunchTimer {
    static let latestKey = "storeLaunch.latestTimings"

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastMarkAt = ProcessInfo.processInfo.systemUptime
    private var parts: [String] = []

    /// Call when a step ends. A step's name is reported with its duration.
    mutating func mark(_ step: String) {
        let now = ProcessInfo.processInfo.systemUptime
        parts.append("\(step)=\(Int((now - lastMarkAt) * 1_000))ms")
        lastMarkAt = now
    }

    func finish(libraryLogBytes: Int64, defaults: UserDefaults = StoreLaunchDiagnostics.defaults) {
        let total = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let logMegabytes = libraryLogBytes / (1_024 * 1_024)
        let summary = (parts + ["total=\(total)ms", "library_log_at_start=\(logMegabytes)MB"]).joined(separator: " ")
        defaults.set(summary, forKey: Self.latestKey)
    }
}

enum StoreLaunchDiagnostics {
    private static let contentsKey = "storeLaunch.libraryContents"
    private static let contentsDateKey = "storeLaunch.libraryContentsDate"
    private static let contentsTimeLimit: TimeInterval = 20
    private static let contentsInterval: TimeInterval = 24 * 60 * 60

    nonisolated static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static var latestTimings: String {
        defaults.string(forKey: StoreLaunchTimer.latestKey) ?? "not recorded yet"
    }

    static var libraryContents: String {
        defaults.string(forKey: contentsKey) ?? "not measured yet"
    }

    /// Reads every page of the library, so it runs only when a support snapshot is
    /// taken, at most daily. iOS terminates an app suspended while holding a lock
    /// on an App Group file, so the time limit stays inside a background assertion.
    @MainActor
    static func refreshLibraryContentsIfDue() async {
        if let last = defaults.object(forKey: contentsDateKey) as? Date,
           Date().timeIntervalSince(last) < contentsInterval { return }
        guard let storeURL = ModelContainerManager.sharedStoreURL else { return }
#if canImport(UIKit)
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MeasureLibraryContents") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
#endif
        let limit = contentsTimeLimit
        let summary = await Task.detached(priority: .utility) {
            describeContents(storeURL: storeURL, timeLimit: limit)
        }.value
        defaults.set(summary, forKey: contentsKey)
        defaults.set(Date(), forKey: contentsDateKey)
    }

    /// Sizes by table and index name only: these are schema names, never user data.
    static func describeContents(storeURL: URL, timeLimit: TimeInterval) -> String {
        var handle: OpaquePointer?
        guard FileManager.default.fileExists(atPath: storeURL.path),
              sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return "unavailable"
        }
        defer { sqlite3_close(handle) }

        let pageSize = integer(handle, "PRAGMA page_size") ?? 0
        let total = (integer(handle, "PRAGMA page_count") ?? 0) * pageSize
        let free = (integer(handle, "PRAGMA freelist_count") ?? 0) * pageSize
        let overview = "total=\(megabytes(total)) free=\(megabytes(free))"

        var deadline = Date().addingTimeInterval(timeLimit).timeIntervalSinceReferenceDate
        return withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(handle, 100_000, { context in
                let deadline = context!.assumingMemoryBound(to: TimeInterval.self).pointee
                return Date().timeIntervalSinceReferenceDate > deadline ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }

            var statement: OpaquePointer?
            let sql = "SELECT name, SUM(pgsize) AS size FROM dbstat GROUP BY name ORDER BY size DESC LIMIT 8"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                return "\(overview); tables unavailable"
            }
            defer { sqlite3_finalize(statement) }

            var tables: [String] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
                tables.append("\(name)=\(megabytes(sqlite3_column_int64(statement, 1)))")
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { return "\(overview); tables not finished in time" }
            return "\(overview); \(tables.joined(separator: " "))"
        }
    }

    private static func integer(_ handle: OpaquePointer, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    private static func megabytes(_ bytes: Int64) -> String {
        "\(bytes / (1_024 * 1_024))MB"
    }
}
