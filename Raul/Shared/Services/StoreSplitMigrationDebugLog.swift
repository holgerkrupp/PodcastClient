#if DEBUG
import Foundation
import UserNotifications

/// One recorded step of the store-split backfill.
struct StoreSplitMigrationLogEntry: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var event: String
    var details: String?
}

/// A DEBUG-only trace of when the migration runs, which phases finish, and why a
/// run stopped.
///
/// Entries live in the App Group defaults rather than in memory so the
/// `BGProcessingTask` — which runs in its own launch of the process, often while
/// nobody is watching — leaves a record the app can show afterwards. This is the
/// only way to tell "the overnight pass never fired" apart from "it fired and
/// found nothing to do".
enum StoreSplitMigrationDebugLog {
    private static let storageKey = "storeSplit.debugMigrationLog"
    private static let maximumEntryCount = 300
    private static let notificationIdentifierPrefix = "storeSplitMigrationDebug."
    private static let lock = NSLock()

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static func record(_ event: String, details: String? = nil) {
        let entry = StoreSplitMigrationLogEntry(
            date: Date(),
            event: event,
            details: details
        )
        // The background task and the foreground app can both append, so the
        // read-modify-write is serialized to keep entries from being dropped.
        lock.lock()
        defer { lock.unlock() }
        var stored = decodedEntries()
        stored.append(entry)
        if stored.count > maximumEntryCount {
            stored.removeFirst(stored.count - maximumEntryCount)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Newest first, for direct display in a list.
    static var entries: [StoreSplitMigrationLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return decodedEntries().reversed()
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private static func decodedEntries() -> [StoreSplitMigrationLogEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(
                  [StoreSplitMigrationLogEntry].self,
                  from: data
              ) else {
            return []
        }
        return stored
    }

    // MARK: - Notifications

    /// Whether a notification identifier belongs to this log, so the foreground
    /// presentation handler can show these without changing how the app presents
    /// its real notifications.
    static func isDebugNotification(_ identifier: String) -> Bool {
        identifier.hasPrefix(notificationIdentifierPrefix)
    }

    /// Asks for notification permission once, so a phase finishing overnight is
    /// visible on the Lock Screen the next morning. Denied permission only costs
    /// the banner — the log itself still records everything.
    static func requestAuthorizationIfNeeded() {
        Task {
            await NotificationManager().requestAuthorizationIfUndetermined()
        }
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: notificationIdentifierPrefix + UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Records one slice. Slices are frequent, so these are collapsed into a
    /// single rolling entry per phase rather than appended, keeping the log
    /// readable while still showing that work is progressing.
    static func recordSlice(
        phase: String,
        processed: Int,
        status: String,
        footprint: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        var stored = decodedEntries()
        let event = "slice: \(phase)"
        let details = "processed \(processed), \(status)"
            + (footprint.map { ", \($0)" } ?? "")
        if let index = stored.lastIndex(where: { $0.event == event }),
           index == stored.count - 1 {
            stored[index] = StoreSplitMigrationLogEntry(
                id: stored[index].id,
                date: Date(),
                event: event,
                details: details
            )
        } else {
            stored.append(StoreSplitMigrationLogEntry(
                date: Date(),
                event: event,
                details: details
            ))
        }
        if stored.count > maximumEntryCount {
            stored.removeFirst(stored.count - maximumEntryCount)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Records a finished phase and surfaces it as a passive banner.
    static func recordPhaseFinished(_ phase: String, progress: String?) {
        let details = progress ?? "no progress summary"
        record("phase finished: \(phase)", details: details)
        notify(
            title: "Migration phase finished",
            body: progress.map { "\(phase) — \($0)" } ?? phase
        )
    }
}
#endif
