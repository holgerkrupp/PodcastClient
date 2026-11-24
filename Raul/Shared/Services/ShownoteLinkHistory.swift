import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ShownoteLinkHistoryRetention: Int, CaseIterable, Codable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case off = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .off: "Off"
        }
    }

    var age: TimeInterval? {
        guard self != .off else { return nil }
        return TimeInterval(rawValue) * 24 * 60 * 60
    }
}

struct ShownoteLinkHistoryConfiguration: Sendable, Equatable {
    let isEnabled: Bool
    let retention: ShownoteLinkHistoryRetention
}

struct ShownoteLinkHistorySource: Hashable, Sendable {
    let episodeURL: URL
    let episodeTitle: String

    init(episodeURL: URL, episodeTitle: String) {
        self.episodeURL = episodeURL
        self.episodeTitle = episodeTitle
    }
}

struct ShownoteLinkHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let destination: URL
    let title: String
    let sourceEpisodeURL: URL?
    let sourceEpisodeTitle: String
    var openedAt: Date

    var domain: String {
        destination.host ?? destination.absoluteString
    }

    var safePath: String? {
        let path = destination.path
        return path.isEmpty || path == "/" ? nil : path
    }

    var searchableText: String {
        [title, domain, safePath ?? "", sourceEpisodeTitle]
            .joined(separator: " ")
    }
}

/// Keeps the small shownote history separate from both SwiftData stores and
/// UserState. It is local-only, opt-in, bounded, and safe to call after a link
/// has already been handed to the system.
actor ShownoteLinkHistoryStore {
    static let shared = ShownoteLinkHistoryStore()

    private static let entriesKey = "upNext.shownoteLinkHistory.entries.v1"
    private static let enabledKey = "upNext.shownoteLinkHistory.enabled.v1"
    private static let retentionKey = "upNext.shownoteLinkHistory.retention.v1"
    private static let maximumEntryCount = 500

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
    }

    func configuration() -> ShownoteLinkHistoryConfiguration {
        let retention = storedRetention
        let enabled = defaults.bool(forKey: Self.enabledKey) && retention != .off
        return ShownoteLinkHistoryConfiguration(isEnabled: enabled, retention: retention)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if storedRetention == .off {
                defaults.set(ShownoteLinkHistoryRetention.thirtyDays.rawValue, forKey: Self.retentionKey)
            }
            defaults.set(true, forKey: Self.enabledKey)
        } else {
            defaults.set(false, forKey: Self.enabledKey)
            defaults.set(ShownoteLinkHistoryRetention.off.rawValue, forKey: Self.retentionKey)
            defaults.removeObject(forKey: Self.entriesKey)
        }
    }

    func setRetention(_ retention: ShownoteLinkHistoryRetention) {
        defaults.set(retention.rawValue, forKey: Self.retentionKey)
        defaults.set(retention != .off, forKey: Self.enabledKey)
        if retention == .off {
            defaults.removeObject(forKey: Self.entriesKey)
        }
    }

    func entries() -> [ShownoteLinkHistoryEntry] {
        guard configuration().isEnabled else {
            return []
        }

        let pruned = prune(loadEntries(), at: now())
        save(pruned)
        return pruned.sorted { $0.openedAt > $1.openedAt }
    }

    func record(
        destination: URL,
        title: String?,
        source: ShownoteLinkHistorySource
    ) {
        guard configuration().isEnabled,
              let safeDestination = ShownoteLinkHistoryURLPolicy.sanitize(destination),
              let safeEpisodeURL = ShownoteLinkHistoryURLPolicy.sanitize(source.episodeURL) else {
            return
        }

        let timestamp = now()
        var entries = prune(loadEntries(), at: timestamp)
        let id = Self.entryID(episodeURL: safeEpisodeURL, destination: safeDestination)
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = safeDestination.host ?? safeDestination.absoluteString

        if let index = entries.firstIndex(where: { $0.id == id }) {
            var entry = entries[index]
            entry.openedAt = timestamp
            if let cleanTitle, cleanTitle.isEmpty == false {
                entry = ShownoteLinkHistoryEntry(
                    id: entry.id,
                    destination: entry.destination,
                    title: cleanTitle,
                    sourceEpisodeURL: entry.sourceEpisodeURL,
                    sourceEpisodeTitle: source.episodeTitle,
                    openedAt: timestamp
                )
            } else {
                entry = ShownoteLinkHistoryEntry(
                    id: entry.id,
                    destination: entry.destination,
                    title: entry.title,
                    sourceEpisodeURL: entry.sourceEpisodeURL,
                    sourceEpisodeTitle: source.episodeTitle,
                    openedAt: timestamp
                )
            }
            entries[index] = entry
        } else {
            entries.append(
                ShownoteLinkHistoryEntry(
                    id: id,
                    destination: safeDestination,
                    title: cleanTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                    sourceEpisodeURL: safeEpisodeURL,
                    sourceEpisodeTitle: source.episodeTitle,
                    openedAt: timestamp
                )
            )
        }

        save(prune(entries, at: timestamp))
    }

    func remove(id: String) {
        save(loadEntries().filter { $0.id != id })
    }

    func clear() {
        defaults.removeObject(forKey: Self.entriesKey)
    }

    private var storedRetention: ShownoteLinkHistoryRetention {
        ShownoteLinkHistoryRetention(
            rawValue: defaults.object(forKey: Self.retentionKey) as? Int ?? 0
        ) ?? .off
    }

    private func loadEntries() -> [ShownoteLinkHistoryEntry] {
        guard let data = defaults.data(forKey: Self.entriesKey),
              let entries = try? JSONDecoder().decode([ShownoteLinkHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func save(_ entries: [ShownoteLinkHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }

    private func prune(
        _ entries: [ShownoteLinkHistoryEntry],
        at timestamp: Date
    ) -> [ShownoteLinkHistoryEntry] {
        guard let age = storedRetention.age else { return [] }
        let cutoff = timestamp.addingTimeInterval(-age)
        return entries
            .filter { $0.openedAt >= cutoff }
            .sorted { $0.openedAt > $1.openedAt }
            .prefix(Self.maximumEntryCount)
            .map { $0 }
    }

    private static func entryID(episodeURL: URL, destination: URL) -> String {
        let value = "\(episodeURL.absoluteString)\u{0}\(destination.absoluteString)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ShownoteLinkHistoryURLPolicy {
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "yclid",
        "_ga", "_gl", "vero_id"
    ]

    private static let sensitiveExactParameters: Set<String> = [
        "apikey", "accesskey", "credential", "credentials", "private", "password",
        "passwd", "secret", "signature", "sig", "hmac", "jwt", "session", "expires",
        "expiry", "xamzcredential", "xamzsignature", "xamzsecuritytoken"
    ]

    static func sanitize(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil else {
            return nil
        }

        let items = components.queryItems ?? []
        for item in items where isSensitiveParameter(item.name) {
            return nil
        }

        let filteredItems = items.filter {
            trackingParameters.contains(normalizedParameterName($0.name)) == false
        }
        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return components.url
    }

    private static func isSensitiveParameter(_ name: String) -> Bool {
        let normalized = normalizedParameterName(name)
        return sensitiveExactParameters.contains(normalized)
            || normalized.contains("token")
            || normalized.contains("auth")
            || normalized.contains("secret")
            || normalized.contains("signature")
            || normalized.contains("session")
            || normalized.hasPrefix("xamz")
    }

    private static func normalizedParameterName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

@MainActor
enum ShownoteLinkHistorySystemOpener {
    static func open(_ url: URL, onSuccess: @escaping @MainActor () -> Void) {
#if canImport(UIKit)
        UIApplication.shared.open(url, options: [:]) { accepted in
            guard ShownoteLinkHistoryOpenPolicy.shouldRecord(successfullyOpened: accepted) else { return }
            Task { @MainActor in
                onSuccess()
            }
        }
#elseif canImport(AppKit)
        if ShownoteLinkHistoryOpenPolicy.shouldRecord(successfullyOpened: NSWorkspace.shared.open(url)) {
            onSuccess()
        }
#endif
    }
}

enum ShownoteLinkHistoryOpenPolicy {
    static func shouldRecord(successfullyOpened: Bool) -> Bool {
        successfullyOpened
    }
}
