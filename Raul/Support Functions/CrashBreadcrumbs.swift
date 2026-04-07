import Foundation

final class CrashBreadcrumbs: @unchecked Sendable {
    static let shared = CrashBreadcrumbs()

    private let defaults: UserDefaults
    private let key = "de.holgerkrupp.raulpodcast.crash_breadcrumbs"
    private let maxEntries = 80
    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter

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
        defer { lock.unlock() }

        var events = defaults.stringArray(forKey: key) ?? []
        events.append(entry)
        if events.count > maxEntries {
            events.removeFirst(events.count - maxEntries)
        }
        defaults.set(events, forKey: key)
    }

    func recent(_ limit: Int = 12) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let events = defaults.stringArray(forKey: key) ?? []
        return Array(events.suffix(max(0, limit)))
    }

    func recentSummary(limit: Int = 12) -> String {
        recent(limit).joined(separator: " || ")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
