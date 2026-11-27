import Foundation
import SQLite3
import os
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// Times the store opens at launch. The event timeline only covers the last five
/// minutes, so the latest result is kept for a report taken any time later.
///
/// Every mark is also written as the "in progress" summary, so a launch that is
/// still on the launch screen (or was killed there) shows which phase it is in.
/// Phase names and durations only: no paths, feed URLs or user data (#518).
struct StoreLaunchTimer {
    static let latestKey = "storeLaunch.latestTimings"
    static let inProgressKey = "storeLaunch.inProgressTimings"
    static let interruptedKey = "storeLaunch.interruptedTimings"
    static let firstUsableShellKey = "storeLaunch.firstUsableShell"
    static let deferredMaintenanceKey = "storeLaunch.deferredMaintenance"
    static let milestonesKey = "storeLaunch.milestones"
    /// Steps after the shell that decide how soon someone can listen (#518):
    /// `store_ready`, `player_restored`, `play_command`, `playback_started`.
    nonisolated(unsafe) private static var recordedMilestones: Set<String> = []
    private static let milestoneLock = NSLock()

    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "UpNext",
        category: "StoreLaunch"
    )

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastMarkAt = ProcessInfo.processInfo.systemUptime
    private var parts: [String] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = StoreLaunchDiagnostics.defaults) {
        self.defaults = defaults
        // An opening that never finished (killed on the launch screen, or a
        // failed attempt) is kept for the next report instead of overwritten.
        if let unfinished = defaults.string(forKey: Self.inProgressKey) {
            defaults.set(unfinished, forKey: Self.interruptedKey)
        }
        defaults.set("started", forKey: Self.inProgressKey)
    }

    /// Call when a step ends. A step's name is reported with its duration.
    mutating func mark(_ step: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let milliseconds = Int((now - lastMarkAt) * 1_000)
        parts.append("\(step)=\(milliseconds)ms")
        lastMarkAt = now
        Self.signposter.emitEvent("StoreLaunchPhase", "\(step, privacy: .public) \(milliseconds)ms")
        defaults.set(parts.joined(separator: " "), forKey: Self.inProgressKey)
    }

    /// Adds a fact (not a duration) to the summary, e.g. `remote_fence=deferred`.
    mutating func note(_ fact: String) {
        parts.append(fact)
        defaults.set(parts.joined(separator: " "), forKey: Self.inProgressKey)
    }

    func finish(libraryLogBytes: Int64, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        let total = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let logMegabytes = libraryLogBytes / (1_024 * 1_024)
        let summary = (parts + ["total=\(total)ms", "library_log_at_start=\(logMegabytes)MB"]).joined(separator: " ")
        defaults.set(summary, forKey: Self.latestKey)
        defaults.removeObject(forKey: Self.inProgressKey)
        self.defaults.removeObject(forKey: Self.inProgressKey)
    }

    /// Records how long after process start the main library became usable
    /// (the launch screen was replaced by the app shell).
    static func recordFirstUsableShell(defaults: UserDefaults = StoreLaunchDiagnostics.defaults) {
        let milliseconds = StoreLaunchDiagnostics.processAgeMilliseconds()
        signposter.emitEvent("FirstUsableShell", "\(milliseconds ?? -1)ms")
        defaults.set(
            milliseconds.map { "\($0)ms after process start" } ?? "recorded (process start unavailable)",
            forKey: firstUsableShellKey
        )
    }

    /// Records the first time this process reached `name`, in milliseconds
    /// after process start. Later calls in the same process are ignored, and a
    /// new process replaces the previous launch's values.
    static func recordMilestone(_ name: String, defaults: UserDefaults = StoreLaunchDiagnostics.defaults) {
        milestoneLock.lock()
        let isFirstMilestone = recordedMilestones.isEmpty
        let inserted = recordedMilestones.insert(name).inserted
        milestoneLock.unlock()
        guard inserted else { return }
        let milliseconds = StoreLaunchDiagnostics.processAgeMilliseconds()
        signposter.emitEvent("LaunchMilestone", "\(name, privacy: .public) \(milliseconds ?? -1)ms")
        var entries = isFirstMilestone
            ? [:]
            : (defaults.dictionary(forKey: milestonesKey) as? [String: String]) ?? [:]
        entries[name] = milliseconds.map { "\($0)ms" } ?? "recorded"
        defaults.set(entries, forKey: milestonesKey)
    }

    /// Records the latest duration and outcome of a post-launch maintenance step
    /// that used to run on the launch critical path.
    static func recordDeferredMaintenance(
        _ step: String,
        milliseconds: Int,
        outcome: String,
        defaults: UserDefaults = StoreLaunchDiagnostics.defaults
    ) {
        var entries = (defaults.dictionary(forKey: deferredMaintenanceKey) as? [String: String]) ?? [:]
        entries[step] = "\(milliseconds)ms \(outcome)"
        defaults.set(entries, forKey: deferredMaintenanceKey)
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

    /// Set only while a store opening is in progress or was interrupted.
    static var inProgressTimings: String? {
        defaults.string(forKey: StoreLaunchTimer.inProgressKey)
    }

    static var interruptedTimings: String {
        defaults.string(forKey: StoreLaunchTimer.interruptedKey) ?? "none recorded"
    }

    static var firstUsableShell: String {
        defaults.string(forKey: StoreLaunchTimer.firstUsableShellKey) ?? "not recorded yet"
    }

    static var launchMilestones: String {
        guard let entries = defaults.dictionary(forKey: StoreLaunchTimer.milestonesKey) as? [String: String],
              entries.isEmpty == false else { return "none recorded" }
        return entries.keys.sorted().map { "\($0)=\(entries[$0] ?? "")" }.joined(separator: ", ")
    }

    static var deferredMaintenance: String {
        guard let entries = defaults.dictionary(forKey: StoreLaunchTimer.deferredMaintenanceKey) as? [String: String],
              entries.isEmpty == false else { return "none recorded" }
        return entries.keys.sorted().map { "\($0)=\(entries[$0] ?? "")" }.joined(separator: ", ")
    }

    /// Historical PodcastCache.sqlite retirement (#394): open backoff,
    /// abandoned migration rows and the legacy copy's temporary checkpoints.
    /// Counts and flags only.
    static var historicalCacheStatus: String {
        "open=\(StoreCacheOpenBackoff.diagnosticSummary); "
            + "migrations=\(StoreCacheMigrationGiveUp.diagnosticSummary()); "
            + "legacy_copy_temporary_checkpoints=\(StoreCutoverState.temporaryCheckpointSummary)"
    }

    /// Milliseconds since this process started, from the kernel's process
    /// record. Nil if the record can't be read.
    static func processAgeMilliseconds() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - started
        guard age >= 0, age < 24 * 60 * 60 else { return nil }
        return Int(age * 1_000)
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
