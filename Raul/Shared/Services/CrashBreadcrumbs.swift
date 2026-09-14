import Foundation

final class CrashBreadcrumbs: @unchecked Sendable {
    static let shared = CrashBreadcrumbs()

    private let defaults: UserDefaults
    private let key = "de.holgerkrupp.raulpodcast.crash_breadcrumbs"
    private let maxEntries = 80
    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter
    /// Persistence runs here, never under `lock`. `UserDefaults.set` posts
    /// `NSUserDefaultsDidChangeNotification` synchronously on the calling
    /// thread, and SwiftUI observes it: its handler takes the global update
    /// lock. Writing while holding `lock` therefore inverted the lock order
    /// against the main thread (which holds the update lock while running a
    /// view action that records a breadcrumb) and deadlocked the app until the
    /// scene-update watchdog killed it.
    private let persistQueue = DispatchQueue(
        label: "de.holgerkrupp.raulpodcast.crash_breadcrumbs.persist",
        qos: .utility
    )
    /// The authoritative in-memory copy. `defaults` is only the durable mirror,
    /// so a flush that lands late never loses an entry.
    private var cachedEvents: [String]?
    private var isFlushScheduled = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
    }

    func record(_ event: String, details: String? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        let detailPart = details.map { " | \($0)" } ?? ""
        let entry = "\(timestamp) | \(event)\(detailPart)"

        lock.lock()
        var events = cachedEvents ?? defaults.stringArray(forKey: key) ?? []
        events.append(entry)
        if events.count > maxEntries {
            events.removeFirst(events.count - maxEntries)
        }
        cachedEvents = events
        lock.unlock()

        flush()
    }

    func recent(_ limit: Int = 12) -> [String] {
        lock.lock()
        let events = cachedEvents ?? defaults.stringArray(forKey: key) ?? []
        lock.unlock()

        return Array(events.suffix(max(0, limit)))
    }

    func recentSummary(limit: Int = 12) -> String {
        recent(limit).joined(separator: " || ")
    }

    func clear() {
        lock.lock()
        cachedEvents = []
        lock.unlock()

        flush()
    }

    /// Mirrors the current buffer to `defaults`.
    ///
    /// Each flush writes the whole snapshot, so at most one needs to be in
    /// flight: entries recorded while one is pending are picked up by it, and an
    /// entry recorded after the snapshot was taken re-arms a new flush.
    private func flush() {
        lock.lock()
        guard isFlushScheduled == false else {
            lock.unlock()
            return
        }
        isFlushScheduled = true
        lock.unlock()

        persistQueue.async { [self] in
            lock.lock()
            isFlushScheduled = false
            let snapshot = cachedEvents ?? []
            lock.unlock()

            defaults.set(snapshot, forKey: key)
        }
    }
}
